# ============================================================
#  Zero Lag v2.0 - تحسين أداء ويندوز للألعاب بضغطة زر
#  يشتغل على Windows PowerShell 5.1 - بدون تثبيت أي شيء
#  كل تعديل يحفظ القيمة الأصلية قبل التغيير عشان ترجعها بضغطة
# ============================================================

$ErrorActionPreference = 'Continue'
$AppVersion = '3.0'
# رابط التحديثات الافتراضي (مجلد raw في GitHub). تقدر تغيّره من داخل التطبيق: أدوات > رابط التحديث
$DefaultUpdateUrl = 'https://raw.githubusercontent.com/jazzid711-droid/zerolag/main'
$script:SelfPath = $PSCommandPath

# ---------- صلاحيات المسؤول ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs } catch {}
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

trap {
    [Windows.MessageBox]::Show("صار خطأ وقف التطبيق:`n`n$($_.Exception.Message)`n`nسطر: $($_.InvocationInfo.ScriptLineNumber)", 'Zero Lag', 'OK', 'Error') | Out-Null
    break
}

# ---------- أدوات أصلية (CPU / RAM / تفريغ الذاكرة / زوايا النافذة) ----------
$script:NativeOk = $false
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GBNative {
    [StructLayout(LayoutKind.Sequential)] public struct FT { public uint Low; public uint High; }
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FT idle, out FT kernel, out FT user);
    [StructLayout(LayoutKind.Sequential)] public class MEMSTAT {
        public uint dwLength = 64; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokPriv { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TokPriv ns, int len, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    static ulong pIdle, pTotal;
    static ulong U(FT f) { return ((ulong)f.High << 32) | f.Low; }
    public static double Cpu() {
        FT i, k, u; GetSystemTimes(out i, out k, out u);
        ulong idle = U(i), total = U(k) + U(u);
        ulong di = idle - pIdle, dt = total - pTotal; pIdle = idle; pTotal = total;
        if (dt == 0) return 0; double v = 100.0 * (dt - di) / dt; if (v < 0) v = 0; if (v > 100) v = 100; return Math.Round(v);
    }
    public static double[] Mem() { var m = new MEMSTAT(); GlobalMemoryStatusEx(m); return new double[] { m.ullTotalPhys / 1073741824.0, (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0, m.dwMemoryLoad }; }
    static void Enable(string name) { IntPtr t; OpenProcessToken(GetCurrentProcess(), 0x28, out t); TokPriv tp; tp.Count = 1; tp.Attr = 2; LookupPrivilegeValue(null, name, out tp.Luid); AdjustTokenPrivileges(t, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero); }
    public static int PurgeStandby() { Enable("SeProfileSingleProcessPrivilege"); int cmd = 4; return NtSetSystemInformation(80, ref cmd, 4); }
    [DllImport("ntdll.dll")] static extern int NtSetTimerResolution(uint desired, [MarshalAs(UnmanagedType.U1)] bool set, out uint current);
    public static uint SetTimer(bool on) { uint cur; NtSetTimerResolution(5000, on, out cur); return cur; }
    public static void StyleWindow(IntPtr h) { int r = 2; DwmSetWindowAttribute(h, 33, ref r, 4); int d = 1; DwmSetWindowAttribute(h, 20, ref d, 4); }
}
'@
    [void][GBNative]::Cpu()
    $script:NativeOk = $true
} catch {}

# ---------- ملفات النسخ الاحتياطي والسجل ----------
$AppDir     = Join-Path $env:LOCALAPPDATA 'ZeroLag'
$OldAppDir  = Join-Path $env:LOCALAPPDATA 'GhaziBoost'
if ((Test-Path $OldAppDir) -and -not (Test-Path $AppDir)) { try { Move-Item -LiteralPath $OldAppDir -Destination $AppDir -Force } catch {} }
$BackupFile = Join-Path $AppDir 'backup.json'
$LogFile    = Join-Path $AppDir 'log.txt'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }

$script:Backup = @{}
if (Test-Path $BackupFile) {
    try {
        $j = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $script:Backup[$p.Name] = $p.Value }
    } catch {}
}
$script:NeedRestart = $false
$GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Save-Backup { $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupFile -Encoding UTF8 }
function Write-Log($msg) { try { Add-Content -Path $LogFile -Value "$(Get-Date -Format s)  $msg" -Encoding UTF8 } catch {} }

# ---------- الريجستري ----------
function Get-RegValue($Path, $Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Save-Original($Path, $Name) {
    $key = "reg|$Path|$Name"
    if ($script:Backup.ContainsKey($key)) { return }
    $exists = $false; $val = $null; $kind = 'DWord'
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.GetValueNames() -contains $Name) {
            $exists = $true
            $val  = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $kind = $item.GetValueKind($Name).ToString()
        }
    } catch {}
    $script:Backup[$key] = [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $exists; Value = $val; Kind = $kind }
    Save-Backup
}

function Write-RegRaw($Path, $Name, $Value, $Type) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($Type -eq 'Binary') { $Value = [byte[]]$Value }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') { Save-Original $Path $Name; Write-RegRaw $Path $Name $Value $Type }

function Restore-Reg($r) {
    $key = "reg|$($r.P)|$($r.N)"
    if ($script:Backup.ContainsKey($key)) {
        $b = $script:Backup[$key]
        if ($b.Exists) { Write-RegRaw $r.P $r.N $b.Value $b.Kind }
        else { Remove-ItemProperty -LiteralPath $r.P -Name $r.N -ErrorAction SilentlyContinue }
        $script:Backup.Remove($key); Save-Backup
    }
    elseif ($null -ne $r.D) { $type = if ($r.T) { $r.T } else { 'DWord' }; Write-RegRaw $r.P $r.N $r.D $type }
    else { Remove-ItemProperty -LiteralPath $r.P -Name $r.N -ErrorAction SilentlyContinue }
}

function Test-RegList($list) {
    foreach ($r in $list) {
        $v = Get-RegValue $r.P $r.N
        if ($null -eq $v) { return $false }
        if ("$v" -ne "$($r.V)") { return $false }
    }
    return $true
}

# ---------- الخدمات ----------
function Set-Svc($Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    $key = "svc|$Name"
    if (-not $script:Backup.ContainsKey($key)) { $script:Backup[$key] = [pscustomobject]@{ Start = $s.StartType.ToString() }; Save-Backup }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $Name -StartupType Disabled
}

function Restore-Svc($Name, $Default) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    $key = "svc|$Name"; $start = $Default
    if ($script:Backup.ContainsKey($key)) { $start = $script:Backup[$key].Start; $script:Backup.Remove($key); Save-Backup }
    if ($start -notin @('Automatic', 'Manual', 'Disabled')) { $start = 'Automatic' }
    Set-Service -Name $Name -StartupType $start
    if ($start -ne 'Disabled') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
}

# ---------- خطة الطاقة ----------
function Get-ActiveSchemeGuid {
    $g = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme'
    if ($g) { return [string]$g }
    $o = powercfg /getactivescheme | Out-String
    if ($o -match $GuidRx) { return $Matches[0] }
    return $null
}

function Get-PowerIndex($sub, $set) {
    $g = Get-ActiveSchemeGuid
    if (-not $g) { return $null }
    $v = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$g\$sub\$set" 'ACSettingIndex'
    if ($null -eq $v) { $v = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$sub\$set\DefaultPowerSchemeValues\$g" 'ACSettingIndex' }
    return $v
}

function Set-PowerSetting($p) {
    $key = "pwr|$($p.K)"
    if (-not $script:Backup.ContainsKey($key)) { $script:Backup[$key] = (Get-PowerIndex $p.S $p.K); Save-Backup }
    powercfg -setacvalueindex scheme_current $p.S $p.K $p.V | Out-Null
    powercfg -setdcvalueindex scheme_current $p.S $p.K $p.V | Out-Null
    powercfg -setactive scheme_current | Out-Null
}

function Restore-PowerSetting($p) {
    $key = "pwr|$($p.K)"; $v = $p.D
    if ($script:Backup.ContainsKey($key)) {
        if ($null -ne $script:Backup[$key]) { $v = $script:Backup[$key] }
        $script:Backup.Remove($key); Save-Backup
    }
    powercfg -setacvalueindex scheme_current $p.S $p.K $v | Out-Null
    powercfg -setdcvalueindex scheme_current $p.S $p.K $v | Out-Null
    powercfg -setactive scheme_current | Out-Null
}

# ---------- الشبكة ----------
$script:AdCache = $null
function Get-UpAdapters {
    if ($null -eq $script:AdCache) { $script:AdCache = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }
    return $script:AdCache
}

function Test-AdapterProp($kw, $val) {
    foreach ($a in Get-UpAdapters) {
        $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
        if ($p -and "$($p.RegistryValue)" -ne "$val") { return $false }
    }
    return $true
}

function Get-NetIfKeys {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        ($p.DhcpIPAddress -and $p.DhcpIPAddress -ne '0.0.0.0') -or ($p.IPAddress -and (@($p.IPAddress) | Where-Object { $_ -and $_ -ne '0.0.0.0' }))
    } | ForEach-Object { "$base\$($_.PSChildName)" }
}

# ============================================================
#  قائمة التعديلات
#  Risk: safe = آمن | medium = جرّبه | warn = تنبيه
#  Rec  = ينطبق مع زر "حسّن الحين"
# ============================================================
$MM   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$GCS  = 'HKCU:\System\GameConfigStore'
$CDM  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$SUBP = '54533251-82be-4824-96c1-47b60b740d00'
$IFEO = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:RamKB = 0
try { $script:RamKB = [int64][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB) } catch {}

$Tweaks = @(
    # ================= الأداء والمعالج =================
    @{ Id = 'powerplan'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'خطة طاقة Ultimate Performance'
       Desc  = 'المعالج يشتغل على أعلى أداء طول الوقت بدون أي توفير طاقة.'
       Check = {
           $g = $script:Backup['ultimateGuid']; $active = Get-ActiveSchemeGuid
           if ($g -and $active -eq $g) { return $true }
           $o = powercfg /getactivescheme | Out-String
           return ($o -match 'Ultimate|e9a42b02|الفائق|النهائي')
       }
       Apply = {
           $cur = Get-ActiveSchemeGuid
           if (-not $script:Backup.ContainsKey('powerplan')) { $script:Backup['powerplan'] = $cur; Save-Backup }
           $g = $script:Backup['ultimateGuid']; $list = powercfg /list
           if (-not $g -or (($list | Out-String) -notmatch $g)) {
               $g = $null
               foreach ($line in $list) { if ($line -match 'Ultimate|e9a42b02|الفائق|النهائي' -and $line -match $GuidRx) { $g = $Matches[0]; break } }
               if (-not $g) { $out = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-String; if ($out -match $GuidRx) { $g = $Matches[0] } }
               if ($g) { $script:Backup['ultimateGuid'] = $g; Save-Backup }
           }
           if ($g) { powercfg -setactive $g | Out-Null }
       }
       Revert = {
           $prev = $script:Backup['powerplan']
           if (-not $prev) { $prev = '381b4222-f694-41f0-9685-ff5bb260df2e' }
           powercfg -setactive $prev | Out-Null
           $script:Backup.Remove('powerplan'); Save-Backup
       }
    }
    @{ Id = 'coreparking'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Core Parking'
       Desc  = 'كل أنوية المعالج تبقى صاحية، فما يصير تأخير وقت ما تصحى النواة. هذا يقلل التقطيع المفاجئ.'
       Pwr   = @( @{ S = $SUBP; K = '0cc5b647-c1df-4637-891a-dec35c318583'; V = 100; D = 10 } )
    }
    @{ Id = 'usbsuspend'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف USB Selective Suspend'
       Desc  = 'ويندوز ما يقدر ينوّم منافذ USB، فالماوس والكيبورد والسماعة يبقون جاهزين بدون أي تأخير.'
       Pwr   = @( @{ S = '2a737441-1930-4402-8d77-b2bebba308a3'; K = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; V = 0; D = 1 } )
    }
    @{ Id = 'aspm'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف توفير طاقة PCIe'
       Desc  = 'منفذ كرت الشاشة يبقى على كامل سرعته. هذا يقلل التأخير والتقطيع.'
       Pwr   = @( @{ S = '501a4d13-42af-4429-9fd1-a8218c268e20'; K = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; V = 0; D = 1 } )
    }
    @{ Id = 'throttle'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Power Throttling'
       Desc  = 'ويندوز ما يقدر يخنق أداء البرامج اللي يظنها غير مهمة أو اللي بالخلفية.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; N = 'PowerThrottlingOff'; V = 1 } )
    }
    @{ Id = 'priosep'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'أولوية المعالج للبرنامج المفتوح (26 hex)'
       Desc  = 'اللعبة المفتوحة قدامك تاخذ وقت معالج أكثر من البرامج اللي بالخلفية.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; N = 'Win32PrioritySeparation'; V = 0x26; D = 2 } )
    }
    @{ Id = 'sysresp'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'تخصيص المعالج للألعاب (SystemResponsiveness)'
       Desc  = 'يقلل حصة المعالج المحجوزة لمهام الخلفية، ويلغي تقييد الشبكة (NetworkThrottlingIndex).'
       Reg   = @(
           @{ P = $MM; N = 'SystemResponsiveness';   V = 0;  D = 20 }
           @{ P = $MM; N = 'NetworkThrottlingIndex'; V = -1; D = 10 }
       )
    }
    @{ Id = 'timerres'; Cat = 'perf'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'دقة المؤقت العالية (Global Timer Resolution)'
       Desc  = 'في Windows 11 يخلي دقة المؤقت العالية اللي تطلبها اللعبة تنطبق على كل النظام. ممكن يحسّن ثبات الفريمات.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; N = 'GlobalTimerResolutionRequests'; V = 1 } )
    }
    @{ Id = 'dyntick'; Cat = 'perf'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'تعطيل Dynamic Tick'
       Desc  = 'يثبّت مؤقت النظام. ممكن يحسّن ثبات الفريمات، بس يزيد استهلاك الكهرباء شوي.'
       Check = { (bcdedit /enum '{current}' | Out-String) -match 'disabledynamictick\s+Yes' }
       Apply = { bcdedit /set disabledynamictick yes | Out-Null }
       Revert = { bcdedit /deletevalue disabledynamictick | Out-Null }
    }
    @{ Id = 'memcomp'; Cat = 'perf'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف ضغط الذاكرة (Memory Compression)'
       Desc  = 'يوفّر شغل على المعالج. يناسب الأجهزة اللي فيها 16 جيقا رام أو أكثر.'
       Check = { try { -not (Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { $false } }
       Apply = { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue }
       Revert = { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue }
    }
    @{ Id = 'hvci'; Cat = 'perf'; Rec = $false; Risk = 'warn'; Restart = $true
       Title = 'إيقاف Core Isolation / Memory Integrity'
       Desc  = 'يرفع الأداء بالألعاب بشكل واضح على بعض الأجهزة، بس يقلل حماية النظام.'
       Warn  = 'هذا يطفي ميزة حماية في ويندوز اسمها Memory Integrity. الأداء يتحسن، بس جهازك يصير أقل حماية من البرامج الخبيثة. تبي تكمل؟'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; N = 'Enabled'; V = 0 } )
    }

    @{ Id = 'procmin'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'أقل سرعة للمعالج 100%'
       Desc  = 'المعالج ما ينزل سرعته أبداً، فما يصير تأخير وقت ما يرجع يسرّع.'
       Pwr   = @( @{ S = $SUBP; K = '893dee8e-2bef-41e0-89c6-b55d0929964c'; V = 100; D = 5 } )
    }
    @{ Id = 'boostmode'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'Turbo Boost بوضع Aggressive'
       Desc  = 'المعالج يرفع التيربو بأسرع وقت وبأعلى تردد ممكن.'
       Pwr   = @( @{ S = $SUBP; K = 'be337238-0d82-4146-a960-4f3749d470c7'; V = 2; D = 1 } )
    }
    @{ Id = 'epp'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'تفضيل الأداء على توفير الطاقة (EPP)'
       Desc  = 'معالجات إنتل الحديثة تختار الأداء دايماً بدل ما توفر طاقة.'
       Pwr   = @( @{ S = $SUBP; K = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; V = 0; D = 50 } )
    }
    @{ Id = 'diskidle'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'ما يطفي الهارديسك أبداً'
       Desc  = 'الأقراص تبقى شغالة دايماً، فاللعبة ما تعلّق وهي تنتظر القرص يصحى.'
       Pwr   = @( @{ S = '0012ee47-9041-4b5d-9b77-535fba8b1442'; K = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; V = 0; D = 1200 } )
    }
    @{ Id = 'nosleep'; Cat = 'perf'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف السكون التلقائي (Sleep)'
       Desc  = 'الجهاز ما ينام لحاله وأنت تحمّل لعبة أو تحديث. بس إذا تركته بيظل شغال.'
       Pwr   = @( @{ S = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; K = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; V = 0; D = 1800 } )
    }
    @{ Id = 'idledisable'; Cat = 'perf'; Rec = $false; Risk = 'warn'
       Title = 'إيقاف حالات خمول المعالج (Idle)'
       Desc  = 'المعالج ما يرتاح أبداً، فيقل التأخير لأقل شيء ممكن. بس حرارته وكهرباه ترتفع واجد.'
       Warn  = 'هذا يخلي المعالج يشتغل 100% طول الوقت حتى وأنت ما تسوي شيء. حرارته بترتفع وبيستهلك كهرباء أكثر. تبي تكمل؟'
       Pwr   = @( @{ S = $SUBP; K = '5d76a2ca-e8c0-402f-a133-2158492d58ad'; V = 1; D = 0 } )
    }
    @{ Id = 'fth'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Fault Tolerant Heap'
       Desc  = 'ويندوز يبطّئ البرامج اللي طاحت قبل عشان "يحميها". هذا يمنعه يبطّئ ألعابك.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\FTH'; N = 'Enabled'; V = 0; D = 1 } )
    }
    @{ Id = 'lastaccess'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تسجيل آخر وصول للملفات'
       Desc  = 'ويندوز ما يكتب تاريخ كل مرة تفتح فيها ملف، وهذا يقلل الكتابة على القرص وتحميل الألعاب يصير أسرع.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; N = 'NtfsDisableLastAccessUpdate'; V = 0x80000001; D = 0x80000002 } )
    }
    @{ Id = 'dot83'; Cat = 'perf'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف الأسماء القصيرة 8.3'
       Desc  = 'ويندوز ما يسوي اسم قديم ثاني لكل ملف، فالتعامل مع المجلدات الكبيرة يصير أسرع.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; N = 'NtfsDisable8dot3NameCreation'; V = 1; D = 2 } )
    }
    @{ Id = 'ntfsmem'; Cat = 'perf'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'ذاكرة أكبر لنظام الملفات'
       Desc  = 'يعطي نظام الملفات رام أكثر للكاش، فقراءة الملفات الكثيرة تصير أسرع. يناسب الأجهزة اللي فيها 16 جيقا أو أكثر.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; N = 'NtfsMemoryUsage'; V = 2 } )
    }
    @{ Id = 'mmcss'; Cat = 'perf'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'جدولة الوسائط بدون تأخير (MMCSS)'
       Desc  = 'خدمة جدولة الألعاب والصوت تبقى نشطة دايماً بدل ما تتأخر، والمعالجة تصير أثبت.'
       Reg   = @(
           @{ P = $MM; N = 'NoLazyMode'; V = 1 }
           @{ P = $MM; N = 'AlwaysOn';   V = 1 }
       )
    }

    # ================= الألعاب =================
    @{ Id = 'gamestask'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'أولوية الألعاب في جدولة ويندوز'
       Desc  = 'يضبط GPU Priority على 8 وPriority على 6 وScheduling على High للألعاب.'
       Reg   = @(
           @{ P = "$MM\Tasks\Games"; N = 'GPU Priority';        V = 8;      D = 8 }
           @{ P = "$MM\Tasks\Games"; N = 'Priority';            V = 6;      D = 2 }
           @{ P = "$MM\Tasks\Games"; N = 'Scheduling Category'; V = 'High'; D = 'Medium'; T = 'String' }
           @{ P = "$MM\Tasks\Games"; N = 'SFIO Priority';       V = 'High'; D = 'Normal'; T = 'String' }
       )
    }
    @{ Id = 'fortnite'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'فورتنايت بأولوية High تلقائياً'
       Desc  = 'كل ما تشغّل فورتنايت تاخذ أولوية High بنفسها، بدون ما تدخل Task Manager.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FortniteClient-Win64-Shipping.exe\PerfOptions'; N = 'CpuPriorityClass'; V = 3 } )
    }
    @{ Id = 'hags'; Cat = 'games'; Rec = $true; Risk = 'safe'; Restart = $true
       Title = 'Hardware-Accelerated GPU Scheduling'
       Desc  = 'كرت الشاشة يدير ذاكرته بنفسه، وهذا يقلل التأخير. ولازم يكون شغال عشان Frame Generation يشتغل في كروت RTX 40.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; N = 'HwSchMode'; V = 2 } )
    }
    @{ Id = 'windowedopt'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'تحسين الألعاب بوضع النافذة (Flip Model)'
       Desc  = 'الألعاب اللي بوضع Borderless تصير بنفس سلاسة وقلة تأخير الشاشة الكاملة (Windows 11).'
       Check = { (Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings') -match 'SwapEffectUpgradeEnable=1' }
       Apply = {
           $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $cur = [string](Get-RegValue $p 'DirectXUserGlobalSettings')
           $new = (($cur -replace 'SwapEffectUpgradeEnable=\d;?', '').Trim()) + 'SwapEffectUpgradeEnable=1;'
           Set-Reg $p 'DirectXUserGlobalSettings' $new 'String'
       }
       Revert = { Restore-Reg @{ P = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; N = 'DirectXUserGlobalSettings' } }
    }
    @{ Id = 'gamedvr'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Game DVR والتسجيل بالخلفية'
       Desc  = 'يوقف تسجيل Xbox اللي يشتغل بالخلفية وياكل من الفريمات.'
       Reg   = @(
           @{ P = $GCS; N = 'GameDVR_Enabled'; V = 0; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled'; V = 0; D = 1 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; N = 'AllowGameDVR'; V = 0 }
       )
    }
    @{ Id = 'gamemode'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'تشغيل Game Mode'
       Desc  = 'وقت اللعب ويندوز يعطي اللعبة الأولوية ويوقف التحديثات والإشعارات.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'AutoGameModeEnabled'; V = 1; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'AllowAutoGameMode';   V = 1; D = 1 }
       )
    }
    @{ Id = 'mouse'; Cat = 'input'; Rec = $true; Risk = 'safe'; Restart = $true
       Title = 'إيقاف تسريع الماوس'
       Desc  = 'حركة الماوس تصير 1:1 وثابتة، وهذا يساعدك بالتصويب.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseSpeed';      V = '0'; D = '1';  T = 'String' }
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold1'; V = '0'; D = '6';  T = 'String' }
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold2'; V = '0'; D = '10'; T = 'String' }
       )
    }
    @{ Id = 'stickykeys'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف اختصار Sticky Keys'
       Desc  = 'ما تطلع لك نافذة Sticky Keys وتطلّعك من اللعبة إذا ضغطت Shift كثير.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Accessibility\StickyKeys';        N = 'Flags'; V = '506'; D = '510'; T = 'String' }
           @{ P = 'HKCU:\Control Panel\Accessibility\ToggleKeys';        N = 'Flags'; V = '58';  D = '62';  T = 'String' }
           @{ P = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; N = 'Flags'; V = '122'; D = '126'; T = 'String' }
       )
    }
    @{ Id = 'gamebar'; Cat = 'games'; Rec = $false; Risk = 'safe'
       Title = 'إيقاف Xbox Game Bar (Win + G)'
       Desc  = 'يوقف شريط Xbox اللي يطلع فوق اللعبة. شغّله بس إذا ما تستخدمه.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'UseNexusForGameBarEnabled'; V = 0; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\GameBar'; N = 'ShowStartupPanel'; V = 0; D = 1 }
       )
    }
    @{ Id = 'mpo'; Cat = 'games'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف Multiplane Overlay (MPO)'
       Desc  = 'يحل مشاكل الوميض والتقطيع اللي تصير مع كروت NVIDIA. شغّله بس إذا عندك هالمشكلة.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; N = 'OverlayTestMode'; V = 5 } )
    }
    @{ Id = 'fso'; Cat = 'games'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف Fullscreen Optimizations'
       Desc  = 'يفيد بعض الألعاب القديمة وألعاب DX11. مع DX12 ممكن ما يفرق، فجرّبه وقارن.'
       Reg   = @(
           @{ P = $GCS; N = 'GameDVR_FSEBehaviorMode';               V = 2; D = 0 }
           @{ P = $GCS; N = 'GameDVR_HonorUserFSEBehaviorMode';      V = 1; D = 0 }
           @{ P = $GCS; N = 'GameDVR_DXGIHonorFSEWindowsCompatible'; V = 1; D = 0 }
       )
    }
    @{ Id = 'inputqueue'; Cat = 'input'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'تصغير طابور الماوس والكيبورد'
       Desc  = 'ويندوز يعالج ضغطاتك بشكل أسرع. التأثير بسيط وتحسه أكثر مع ماوسات الـ Polling Rate العالي.'
       Reg   = @(
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; N = 'MouseDataQueueSize';    V = 20; D = 100 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; N = 'KeyboardDataQueueSize'; V = 20; D = 100 }
       )
    }

    @{ Id = 'vrr'; Cat = 'games'; Rec = $true; Risk = 'safe'
       Title = 'تحسينات Variable Refresh Rate'
       Desc  = 'الألعاب اللي ما تدعم G-Sync أو FreeSync بنفسها تستفيد منه، فالصورة تصير أنعم بدون تمزق (Windows 11).'
       Check = { (Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings') -match 'VRROptimizeEnable=1' }
       Apply = {
           $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $cur = [string](Get-RegValue $p 'DirectXUserGlobalSettings')
           $new = (($cur -replace 'VRROptimizeEnable=\d;?', '').Trim()) + 'VRROptimizeEnable=1;'
           Set-Reg $p 'DirectXUserGlobalSettings' $new 'String'
       }
       Revert = {
           $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
           $cur = [string](Get-RegValue $p 'DirectXUserGlobalSettings')
           Write-RegRaw $p 'DirectXUserGlobalSettings' ($cur -replace 'VRROptimizeEnable=\d;?', '') 'String'
       }
    }
    @{ Id = 'tdr'; Cat = 'games'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'مهلة أطول لكرت الشاشة (TDR Delay)'
       Desc  = 'يمنع ويندوز يعيد تشغيل تعريف كرت الشاشة وقت الضغط العالي. يفيد إذا اللعبة تطفي فجأة مع رسالة إن التعريف توقف.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; N = 'TdrDelay'; V = 10 } )
    }
    @{ Id = 'xboxsvc'; Cat = 'games'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف خدمات Xbox'
       Desc  = 'يوقف خدمات Xbox اللي بالخلفية. لا تشغّله إذا تلعب من Game Pass أو تطبيق Xbox.'
       Svc   = @(
           @{ N = 'XblAuthManager'; D = 'Manual' }
           @{ N = 'XblGameSave';    D = 'Manual' }
           @{ N = 'XboxNetApiSvc';  D = 'Manual' }
           @{ N = 'XboxGipSvc';     D = 'Manual' }
       )
    }

    # ================= الماوس والكيبورد =================
    @{ Id = 'kbdrate'; Cat = 'input'; Rec = $true; Risk = 'safe'; Restart = $true
       Title = 'أسرع تكرار للكيبورد'
       Desc  = 'لما تمسك زر يبدأ يتكرر فوراً وبأعلى سرعة، فالحركة بالألعاب تصير أسرع.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Keyboard'; N = 'KeyboardDelay'; V = '0';  D = '1';  T = 'String' }
           @{ P = 'HKCU:\Control Panel\Keyboard'; N = 'KeyboardSpeed'; V = '31'; D = '31'; T = 'String' }
       )
    }
    @{ Id = 'hover'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'استجابة فورية لمؤشر الماوس'
       Desc  = 'يقلل وقت الانتظار لما توقف الماوس فوق شيء، فالقوائم والتلميحات تطلع على طول.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseHoverTime'; V = '10'; D = '400'; T = 'String' } )
    }
    @{ Id = 'foreground'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'تبديل أسرع بين النوافذ (Alt + Tab)'
       Desc  = 'لما تطلع من اللعبة وترجع لها، ويندوز يعطيها التركيز على طول بدون تأخير.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Desktop'; N = 'ForegroundLockTimeout'; V = 0; D = 200000 } )
    }
    @{ Id = 'inputthread'; Cat = 'input'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'أولوية عالية لتعريف الماوس والكيبورد'
       Desc  = 'ويندوز يعالج إشارات الماوس والكيبورد قبل أي شيء ثاني.'
       Reg   = @(
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; N = 'ThreadPriority'; V = 31 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; N = 'ThreadPriority'; V = 31 }
       )
    }
    @{ Id = 'csrss'; Cat = 'input'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'أولوية عالية لخدمة الإدخال (CSRSS)'
       Desc  = 'خدمة CSRSS هي اللي توصل حركة الماوس والكيبورد للعبة. هذا التعديل يرفع أولويتها عشان تقل التقطعات.'
       Reg   = @(
           @{ P = "$IFEO\csrss.exe\PerfOptions"; N = 'CpuPriorityClass'; V = 4 }
           @{ P = "$IFEO\csrss.exe\PerfOptions"; N = 'IoPriority';       V = 3 }
       )
    }

    @{ Id = 'mousecurve'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'منحنى ماوس 1:1 مثالي (MarkC Fix)'
       Desc  = 'يضبط منحنى حركة الماوس عشان يكون خطي 100% بدون أي تسريع مخفي، فالتصويب يصير أدق.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'SmoothMouseXCurve'; T = 'Binary'
              V = [byte[]](0,0,0,0,0,0,0,0, 0xC0,0xCC,0x0C,0,0,0,0,0, 0x80,0x99,0x19,0,0,0,0,0, 0x40,0x66,0x26,0,0,0,0,0, 0x00,0x33,0x33,0,0,0,0,0) }
           @{ P = 'HKCU:\Control Panel\Mouse'; N = 'SmoothMouseYCurve'; T = 'Binary'
              V = [byte[]](0,0,0,0,0,0,0,0, 0,0,0x38,0,0,0,0,0, 0,0,0x70,0,0,0,0,0, 0,0,0xA8,0,0,0,0,0, 0,0,0xE0,0,0,0,0,0) }
       )
    }
    @{ Id = 'mousesens'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'حساسية ويندوز للماوس على 6/11'
       Desc  = 'هذي القيمة اللي تعطي كل حركة في الماوس نفس الحركة بالضبط على الشاشة، بدون ما ويندوز يتخطى بكسلات. تحكم بالسرعة من الـ DPI في الماوس نفسه.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Mouse'; N = 'MouseSensitivity'; V = '10'; D = '10'; T = 'String' } )
    }
    @{ Id = 'latsens'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'تعليم الألعاب إنها حساسة للتأخير'
       Desc  = 'ويندوز يتعامل مع الألعاب كمهام لازم تنفذ فوراً (Latency Sensitive).'
       Reg   = @(
           @{ P = "$MM\Tasks\Games"; N = 'Latency Sensitive'; V = 'True'; T = 'String' }
           @{ P = "$MM\Tasks\Games"; N = 'Background Only';   V = 'False'; D = 'False'; T = 'String' }
       )
    }
    @{ Id = 'usbpower'; Cat = 'input'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف توفير الطاقة لأجهزة USB'
       Desc  = 'ويندوز ما ينوّم الماوس والكيبورد والسماعة أبداً، فما يصير تأخير أول حركة بعد ما توقف.'
       Check = {
           $keys = @(Get-UsbParamKeys); if ($keys.Count -eq 0) { return $false }
           $found = 0
           foreach ($k in $keys) { $v = Get-RegValue $k 'EnhancedPowerManagementEnabled'; if ($null -ne $v) { if ($v -ne 0) { return $false }; $found++ } }
           return ($found -gt 0)
       }
       Apply = {
           foreach ($k in Get-UsbParamKeys) {
               foreach ($n in 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled') { try { Set-Reg $k $n 0 } catch {} }
           }
       }
       Revert = {
           foreach ($k in Get-UsbParamKeys) {
               foreach ($n in 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled') { try { Restore-Reg @{ P = $k; N = $n } } catch {} }
           }
       }
    }
    @{ Id = 'rawthrottle'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تقييد الماوس بالخلفية'
       Desc  = 'Windows 11 يخفف إشارات الماوس للنوافذ اللي بالخلفية. هذا يوقفه عشان ما يصير تقطيع إذا عندك برنامج ثاني مفتوح.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Mouse'; N = 'RawMouseThrottleEnabled'; V = 0 } )
    }
    @{ Id = 'textpred'; Cat = 'input'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف اقتراحات الكتابة للكيبورد'
       Desc  = 'يوقف الاقتراحات والتصحيح التلقائي اللي تشتغل بالخلفية مع كل ضغطة زر.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Input\Settings'; N = 'EnableHwkbTextPrediction'; V = 0; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Input\Settings'; N = 'EnableHwkbAutocorrection'; V = 0; D = 1 }
       )
    }
    @{ Id = 'langhotkey'; Cat = 'input'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف تبديل اللغة بـ Alt + Shift'
       Desc  = 'ما تتغير اللغة بالغلط من عربي لإنجليزي وأنت تلعب. وتقدر تبدّل اللغة بـ Win + Space.'
       Reg   = @(
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Hotkey';          V = '3'; D = '1'; T = 'String' }
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Language Hotkey'; V = '3'; D = '1'; T = 'String' }
           @{ P = 'HKCU:\Keyboard Layout\Toggle'; N = 'Layout Hotkey';   V = '3'; D = '2'; T = 'String' }
       )
    }

    # ================= الشبكة =================
    @{ Id = 'adapterpm'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف توفير الطاقة لكرت الشبكة'
       Desc  = 'ويندوز ما يقدر يطفي كرت الشبكة أو يخفف طاقته، وهذا يمنع قفزات البنق المفاجئة.'
       Check = {
           $a = Get-UpAdapters; if ($a.Count -eq 0) { return $false }
           foreach ($x in $a) { $pm = Get-NetAdapterPowerManagement -Name $x.Name -ErrorAction SilentlyContinue; if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { return $false } }
           return $true
       }
       Apply  = { foreach ($x in Get-UpAdapters) { Disable-NetAdapterPowerManagement -Name $x.Name -NoRestart -ErrorAction SilentlyContinue } }
       Revert = { foreach ($x in Get-UpAdapters) { Enable-NetAdapterPowerManagement -Name $x.Name -NoRestart -ErrorAction SilentlyContinue } }
    }
    @{ Id = 'eee'; Cat = 'net'; Rec = $true; Risk = 'safe'; Restart = $true
       Title = 'إيقاف Energy Efficient Ethernet'
       Desc  = 'يوقف ميزة توفير الطاقة في كيبل الإيثرنت اللي ممكن تسبب تأخير بسيط في الحزم.'
       Check  = { (Test-AdapterProp '*EEE' 0) -and (Test-AdapterProp 'EnableGreenEthernet' 0) }
       Apply  = { foreach ($x in Get-UpAdapters) { foreach ($k in '*EEE', 'EnableGreenEthernet') { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword $k -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } } }
       Revert = { foreach ($x in Get-UpAdapters) { foreach ($k in '*EEE', 'EnableGreenEthernet') { Reset-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword $k -NoRestart -ErrorAction SilentlyContinue } } }
    }
    @{ Id = 'delivery'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف مشاركة التحديثات (Delivery Optimization)'
       Desc  = 'ويندوز ما يرفع تحديثات لأجهزة ثانية عن طريق نتّك وأنت تلعب.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DODownloadMode'; V = 0 } )
    }
    @{ Id = 'qos'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'إلغاء حجز النطاق (QoS Reserved Bandwidth)'
       Desc  = 'ويندوز ما يحجز جزء من سرعة النت لخدماته.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'; N = 'NonBestEffortLimit'; V = 0 } )
    }
    @{ Id = 'intmod'; Cat = 'net'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف Interrupt Moderation'
       Desc  = 'كرت الشبكة يعالج كل حزمة فوراً بدل ما يجمعها. البنق يقل شوي، والمعالج يشتغل أكثر بشكل بسيط.'
       Check  = { $a = Get-UpAdapters; if ($a.Count -eq 0) { return $false }; Test-AdapterProp '*InterruptModeration' 0 }
       Apply  = { foreach ($x in Get-UpAdapters) { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword '*InterruptModeration' -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } }
       Revert = { foreach ($x in Get-UpAdapters) { Reset-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword '*InterruptModeration' -NoRestart -ErrorAction SilentlyContinue } }
    }
    @{ Id = 'nagle'; Cat = 'net'; Rec = $false; Risk = 'medium'
       Title = 'تعطيل Nagle (TCPNoDelay)'
       Desc  = 'يرسل حزم الشبكة فوراً بدل ما يجمعها. إذا صار تأخير بفتح المواقع رجّعه.'
       Check = {
           $keys = @(Get-NetIfKeys); if ($keys.Count -eq 0) { return $false }
           foreach ($k in $keys) { if ((Get-RegValue $k 'TcpAckFrequency') -eq 1 -and (Get-RegValue $k 'TCPNoDelay') -eq 1) { return $true } }
           return $false
       }
       Apply = { foreach ($k in Get-NetIfKeys) { Set-Reg $k 'TcpAckFrequency' 1; Set-Reg $k 'TCPNoDelay' 1; Set-Reg $k 'TcpDelAckTicks' 0 } }
       Revert = { foreach ($k in Get-NetIfKeys) { foreach ($n in 'TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks') { Restore-Reg @{ P = $k; N = $n } } } }
    }

    @{ Id = 'dnsneg'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'ما يحفظ نتائج DNS الفاشلة'
       Desc  = 'إذا موقع أو سيرفر ما رد مرة، ويندوز ما يحفظ إنه فاشل، فيرجع يشتغل على طول.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'; N = 'NegativeCacheTime'; V = 0 } )
    }
    @{ Id = 'hostprio'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'ترتيب أسرع لحل أسماء السيرفرات'
       Desc  = 'ويندوز يدوّر على عناوين السيرفرات بالترتيب الأسرع، فالاتصال بسيرفرات اللعبة يصير أسرع.'
       Reg   = @(
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'; N = 'LocalPriority';  V = 4; D = 499 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'; N = 'HostsPriority';  V = 5; D = 500 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'; N = 'DnsPriority';    V = 6; D = 2000 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'; N = 'NetbtPriority';  V = 7; D = 2001 }
       )
    }
    @{ Id = 'maxport'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'منافذ اتصال أكثر وتحرير أسرع'
       Desc  = 'يزيد عدد المنافذ المتاحة، ويحرر المنافذ المقفلة أسرع. يفيد مع الألعاب والتحميلات اللي تفتح اتصالات كثيرة.'
       Reg   = @(
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; N = 'MaxUserPort';       V = 65534 }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; N = 'TcpTimedWaitDelay'; V = 30 }
       )
    }
    @{ Id = 'ttl'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'ضبط TTL على 64'
       Desc  = 'قيمة TTL قياسية ومستقرة للحزم اللي تطلع من جهازك.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; N = 'DefaultTTL'; V = 64 } )
    }
    @{ Id = 'smbthrottle'; Cat = 'net'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تقييد سرعة الشبكة المحلية'
       Desc  = 'نقل الملفات بين أجهزة البيت يكون بكامل السرعة.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'; N = 'DisableBandwidthThrottling'; V = 1 } )
    }
    @{ Id = 'ecn'; Cat = 'net'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف ECN'
       Desc  = 'بعض الراوترات ما تتعامل صح مع ميزة ECN، فإيقافها ممكن يقلل التذبذب بالبنق.'
       Check  = { "$((Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue).EcnCapability)" -eq 'Disabled' }
       Apply  = { netsh int tcp set global ecncapability=disabled | Out-Null }
       Revert = { netsh int tcp set global ecncapability=default | Out-Null }
    }
    @{ Id = 'timestamps'; Cat = 'net'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف TCP Timestamps'
       Desc  = 'يصغّر حجم كل حزمة شوي، وهذا ممكن يقلل التأخير بشكل بسيط.'
       Check  = { "$((Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue).Timestamps)" -eq 'Disabled' }
       Apply  = { netsh int tcp set global timestamps=disabled | Out-Null }
       Revert = { netsh int tcp set global timestamps=default | Out-Null }
    }
    @{ Id = 'teredo'; Cat = 'net'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف Teredo'
       Desc  = 'يوقف نفق IPv6 القديم اللي يشتغل بالخلفية. لا تشغّله إذا تستخدم شات Xbox Party.'
       Check  = { "$((Get-NetTeredoConfiguration -ErrorAction SilentlyContinue).Type)" -eq 'Disabled' }
       Apply  = { Set-NetTeredoConfiguration -Type Disabled -ErrorAction SilentlyContinue }
       Revert = { Set-NetTeredoConfiguration -Type Default -ErrorAction SilentlyContinue }
    }
    @{ Id = 'lso'; Cat = 'net'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف Large Send Offload'
       Desc  = 'كرت الشبكة يرسل الحزم فوراً بدل ما يجمعها. ممكن يقلل التأخير بالألعاب.'
       Check  = { $a = Get-UpAdapters; if ($a.Count -eq 0) { return $false }; (Test-AdapterProp '*LsoV2IPv4' 0) -and (Test-AdapterProp '*LsoV2IPv6' 0) }
       Apply  = { foreach ($x in Get-UpAdapters) { foreach ($k in '*LsoV2IPv4', '*LsoV2IPv6') { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword $k -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } } }
       Revert = { foreach ($x in Get-UpAdapters) { foreach ($k in '*LsoV2IPv4', '*LsoV2IPv6') { Reset-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword $k -NoRestart -ErrorAction SilentlyContinue } } }
    }
    @{ Id = 'flowctl'; Cat = 'net'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف Flow Control'
       Desc  = 'كرت الشبكة ما يوقف الإرسال مؤقتاً لما الراوتر يطلب. ممكن يقلل قفزات البنق.'
       Check  = { $a = Get-UpAdapters; if ($a.Count -eq 0) { return $false }; Test-AdapterProp '*FlowControl' 0 }
       Apply  = { foreach ($x in Get-UpAdapters) { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword '*FlowControl' -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } }
       Revert = { foreach ($x in Get-UpAdapters) { Reset-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword '*FlowControl' -NoRestart -ErrorAction SilentlyContinue } }
    }

    # ================= النظام =================
    @{ Id = 'hibernate'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف السبات (Hibernate)'
       Desc  = 'يفضّي من الـ C مساحة بحجم الرام، ويوقف Fast Startup اللي يسبب مشاكل أحياناً.'
       Check = { (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0 }
       Apply = { powercfg -h off | Out-Null }
       Revert = { powercfg -h on | Out-Null }
    }
    @{ Id = 'visual'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'تقليل الحركات والشفافية'
       Desc  = 'يطفي الشفافية وحركات شريط المهام ويسرّع القوائم، فويندوز يصير أخف وأسرع.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'EnableTransparency'; V = 0; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';  N = 'TaskbarAnimations';  V = 0; D = 1 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\DWM'; N = 'EnableAeroPeek'; V = 0; D = 1 }
           @{ P = 'HKCU:\Control Panel\Desktop'; N = 'MenuShowDelay'; V = '0'; D = '400'; T = 'String' }
       )
    }
    @{ Id = 'startdelay'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إلغاء تأخير برامج بدء التشغيل'
       Desc  = 'ويندوز يأخر تشغيل البرامج بعد الإقلاع. هذا التعديل يلغي التأخير فالجهاز يجهز أسرع.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; N = 'StartupDelayInMSec'; V = 0 } )
    }
    @{ Id = 'bgapps'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تطبيقات الخلفية'
       Desc  = 'تطبيقات المتجر ما تقدر تشتغل بالخلفية وتاخذ من الرام والمعالج.'
       Reg   = @(
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; N = 'GlobalUserDisabled'; V = 1; D = 0 }
           @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'BackgroundAppGlobalToggle'; V = 0; D = 1 }
       )
    }
    @{ Id = 'ads'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف الاقتراحات والإعلانات'
       Desc  = 'يوقف الإعلانات والنصائح وتثبيت التطبيقات المقترحة بدون إذنك.'
       Reg   = @(
           @{ P = $CDM; N = 'SubscribedContent-338389Enabled'; V = 0; D = 1 }
           @{ P = $CDM; N = 'SubscribedContent-310093Enabled'; V = 0; D = 1 }
           @{ P = $CDM; N = 'SubscribedContent-338388Enabled'; V = 0; D = 1 }
           @{ P = $CDM; N = 'SystemPaneSuggestionsEnabled';    V = 0; D = 1 }
           @{ P = $CDM; N = 'SilentInstalledAppsEnabled';      V = 0; D = 1 }
           @{ P = $CDM; N = 'SoftLandingEnabled';              V = 0; D = 1 }
       )
    }
    @{ Id = 'widgets'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Widgets والأخبار'
       Desc  = 'يوقف لوحة الأخبار والطقس اللي تشتغل بالخلفية وتاكل رام.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; N = 'AllowNewsAndInterests'; V = 0 } )
    }
    @{ Id = 'diagtrack'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف خدمة التتبع (Telemetry)'
       Desc  = 'يوقف خدمة DiagTrack اللي ترسل بيانات استخدامك لمايكروسوفت بالخلفية.'
       Svc   = @( @{ N = 'DiagTrack'; D = 'Automatic' } )
    }
    @{ Id = 'edge'; Cat = 'sys'; Rec = $false; Risk = 'safe'
       Title = 'منع Edge يشتغل بالخلفية'
       Desc  = 'يوقف Startup Boost وتشغيل Edge بالخلفية. بيطلع لك في Edge إنه "مُدار من مؤسسة" وهذا طبيعي.'
       Reg   = @(
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'StartupBoostEnabled';   V = 0 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'BackgroundModeEnabled'; V = 0 }
       )
    }
    @{ Id = 'sysmain'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف SysMain (Superfetch)'
       Desc  = 'يقلل نشاط القرص والرام بالخلفية. مع SSD الفرق بسيط، والبرامج ممكن تفتح أبطأ شوي.'
       Svc   = @( @{ N = 'SysMain'; D = 'Automatic' } )
    }
    @{ Id = 'wsearch'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف فهرسة البحث (Windows Search)'
       Desc  = 'يوقف فهرسة الملفات اللي تشتغل بالخلفية. البحث في قائمة ابدأ يظل شغال بس أبطأ.'
       Svc   = @( @{ N = 'WSearch'; D = 'Automatic' } )
    }
    @{ Id = 'pagingexec'; Cat = 'sys'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إبقاء النظام في الرام (DisablePagingExecutive)'
       Desc  = 'ملفات النظام الأساسية تبقى في الرام بدل ما تنتقل للقرص، فالاستجابة تصير أسرع. يناسب الأجهزة اللي فيها 16 جيقا رام أو أكثر.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; N = 'DisablePagingExecutive'; V = 1; D = 0 } )
    }
    @{ Id = 'svchost'; Cat = 'sys'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'تقليل عدد عمليات svchost'
       Desc  = 'يجمع خدمات ويندوز في عمليات أقل، فالنظام يصير أخف ويستهلك موارد أقل.'
       Check = { $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB'; ($script:RamKB -gt 0 -and $null -ne $v -and [int64]$v -ge $script:RamKB) }
       Apply = { if ($script:RamKB -gt 0) { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int]$script:RamKB) } }
       Revert = { Restore-Reg @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control'; N = 'SvcHostSplitThresholdInKB'; D = 3670016 } }
    }
    @{ Id = 'fastclose'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'قفل أسرع للبرامج المعلّقة وللجهاز'
       Desc  = 'البرامج اللي تعلّق تنقفل أسرع، والجهاز يطفي أسرع. انتبه: لو طفيت الجهاز وفيه ملف ما حفظته، بيتقفل بدون ما يسألك.'
       Reg   = @(
           @{ P = 'HKCU:\Control Panel\Desktop'; N = 'AutoEndTasks';         V = '1';    D = '0';     T = 'String' }
           @{ P = 'HKCU:\Control Panel\Desktop'; N = 'HungAppTimeout';       V = '1000'; D = '5000';  T = 'String' }
           @{ P = 'HKCU:\Control Panel\Desktop'; N = 'WaitToKillAppTimeout'; V = '2000'; D = '20000'; T = 'String' }
           @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control'; N = 'WaitToKillServiceTimeout'; V = '2000'; D = '5000'; T = 'String' }
       )
    }
    @{ Id = 'telemetrypol'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'أقل مستوى للبيانات التشخيصية'
       Desc  = 'ويندوز يرسل لمايكروسوفت أقل قدر ممكن من بياناتك.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0 } )
    }
    @{ Id = 'dmwap'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف خدمة رسائل التتبع (dmwappush)'
       Desc  = 'خدمة تساعد بإرسال بيانات التتبع، وما لها فايدة لك.'
       Svc   = @( @{ N = 'dmwappushservice'; D = 'Manual' } )
    }
    @{ Id = 'activity'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف سجل النشاطات'
       Desc  = 'ويندوز ما يسجل كل البرامج والملفات اللي تفتحها.'
       Reg   = @(
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'EnableActivityFeed';    V = 0 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0 }
           @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities';  V = 0 }
       )
    }
    @{ Id = 'adid'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف معرّف الإعلانات'
       Desc  = 'التطبيقات ما تقدر تتبعك عشان تعرض لك إعلانات.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = 0; D = 1 } )
    }
    @{ Id = 'tailored'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف التجارب المخصصة'
       Desc  = 'مايكروسوفت ما تستخدم بياناتك عشان تعرض لك نصائح وعروض.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0; D = 1 } )
    }
    @{ Id = 'feedback'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف طلبات التقييم'
       Desc  = 'ما يطلع لك ويندوز يسألك عن رأيك وأنت مشغول.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = 0 } )
    }
    @{ Id = 'copilot'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Windows Copilot'
       Desc  = 'يوقف مساعد Copilot المدمج في ويندوز ويوفر موارده.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1 } )
    }
    @{ Id = 'recall'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Recall'
       Desc  = 'يوقف ميزة Recall اللي تاخذ لقطات لشاشتك بشكل مستمر وتستهلك القرص والمعالج.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1 } )
    }
    @{ Id = 'bingsearch'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف بحث Bing في قائمة ابدأ'
       Desc  = 'البحث في قائمة ابدأ يدوّر في جهازك بس، فيصير أسرع وما يرسل اللي تكتبه للنت.'
       Reg   = @( @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1 } )
    }
    @{ Id = 'cortana'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Cortana'
       Desc  = 'يوقف المساعد الصوتي القديم Cortana.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'AllowCortana'; V = 0 } )
    }
    @{ Id = 'lockads'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف الإعلانات في شاشة القفل'
       Desc  = 'ما تطلع نصائح وإعلانات على شاشة القفل.'
       Reg   = @(
           @{ P = $CDM; N = 'RotatingLockScreenOverlayEnabled'; V = 0; D = 1 }
           @{ P = $CDM; N = 'SubscribedContent-338387Enabled';  V = 0; D = 1 }
       )
    }
    @{ Id = 'faststartup'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف Fast Startup'
       Desc  = 'كل مرة تطفي الجهاز يقفل ويندوز قفلة كاملة، فالتعريفات تبدأ نظيفة ويقل التعليق.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; N = 'HiberbootEnabled'; V = 0; D = 1 } )
    }
    @{ Id = 'wer'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تقارير الأعطال'
       Desc  = 'ويندوز ما يجمع تقارير أعطال ويرسلها بالخلفية بعد ما يطيح أي برنامج.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; V = 1; D = 0 } )
       Svc   = @( @{ N = 'WerSvc'; D = 'Manual' } )
    }
    @{ Id = 'remoteassist'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف المساعدة عن بعد'
       Desc  = 'ما أحد يقدر يطلب يتحكم بجهازك عن بعد. هذا أأمن لجهازك.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N = 'fAllowToGetHelp'; V = 0; D = 1 } )
    }
    @{ Id = 'remotereg'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف الريجستري عن بعد'
       Desc  = 'ما أحد يقدر يعدّل الريجستري حقك من جهاز ثاني. هذا أأمن لجهازك.'
       Svc   = @( @{ N = 'RemoteRegistry'; D = 'Disabled' } )
    }
    @{ Id = 'mapsbroker'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف خدمة تحديث الخرائط'
       Desc  = 'خدمة تحمّل خرائط ويندوز بالخلفية، وما تحتاجها.'
       Svc   = @( @{ N = 'MapsBroker'; D = 'Automatic' } )
    }
    @{ Id = 'fax'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف خدمة الفاكس'
       Desc  = 'خدمة قديمة ما لها أي استخدام عندك.'
       Svc   = @( @{ N = 'Fax'; D = 'Manual' } )
    }
    @{ Id = 'retaildemo'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف وضع العرض في المحلات'
       Desc  = 'خدمة مخصصة لأجهزة العرض في المعارض، وما تحتاجها.'
       Svc   = @( @{ N = 'RetailDemo'; D = 'Manual' } )
    }
    @{ Id = 'wmpnet'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف مشاركة Windows Media Player'
       Desc  = 'يوقف مشاركة الوسائط بالشبكة، وهي خدمة قديمة.'
       Svc   = @( @{ N = 'WMPNetworkSvc'; D = 'Manual' } )
    }
    @{ Id = 'wisvc'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف خدمة Windows Insider'
       Desc  = 'هذي الخدمة لنسخ ويندوز التجريبية، وما تحتاجها.'
       Svc   = @( @{ N = 'wisvc'; D = 'Manual' } )
    }
    @{ Id = 'geoloc'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف خدمة الموقع'
       Desc  = 'يوقف تحديد الموقع، وتطبيقات مثل الطقس والخرائط ما بتعرف وين أنت.'
       Svc   = @( @{ N = 'lfsvc'; D = 'Manual' } )
    }
    @{ Id = 'spooler'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف خدمة الطابعة'
       Desc  = 'شغّله بس إذا ما عندك طابعة. وإذا بغيت تطبع بعدين رجّعه.'
       Svc   = @( @{ N = 'Spooler'; D = 'Automatic' } )
    }
    @{ Id = 'pcasvc'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف مساعد توافق البرامج'
       Desc  = 'خدمة تراقب كل برنامج تشغله عشان تقترح إعدادات توافق. يفيد إيقافها، بس البرامج القديمة ممكن ما تشتغل صح.'
       Svc   = @( @{ N = 'PcaSvc'; D = 'Automatic' } )
    }
    @{ Id = 'ndu'; Cat = 'sys'; Rec = $false; Risk = 'medium'; Restart = $true
       Title = 'إيقاف مراقبة استهلاك الشبكة (NDU)'
       Desc  = 'خدمة تحسب استهلاك النت لكل برنامج، ومعروف إنها تاكل رام مع الوقت. بعد إيقافها ما بتشوف استهلاك النت في الإعدادات.'
       Reg   = @( @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Services\Ndu'; N = 'Start'; V = 4; D = 2 } )
    }
    @{ Id = 'minanimate'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف حركة تصغير وتكبير النوافذ'
       Desc  = 'النوافذ تفتح وتتصغر على طول بدون حركة، فالنظام يحس أسرع.'
       Reg   = @( @{ P = 'HKCU:\Control Panel\Desktop\WindowMetrics'; N = 'MinAnimate'; V = '0'; D = '1'; T = 'String' } )
    }
    @{ Id = 'startrecs'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف التوصيات في قائمة ابدأ'
       Desc  = 'قائمة ابدأ ما تعرض لك توصيات وإعلانات.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_IrisRecommendations'; V = 0; D = 1 } )
    }
    @{ Id = 'trackprogs'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف تتبع البرامج اللي تفتحها'
       Desc  = 'ويندوز ما يسجل البرامج اللي تشغلها عشان يرتّب القوائم.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_TrackProgs'; V = 0; D = 1 } )
    }
    @{ Id = 'syncads'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'إيقاف إعلانات OneDrive في المجلدات'
       Desc  = 'ما تطلع لك إعلانات OneDrive داخل مستكشف الملفات.'
       Reg   = @( @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowSyncProviderNotifications'; V = 0; D = 1 } )
    }
    @{ Id = 'wudrivers'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'منع ويندوز يغيّر تعريف كرت الشاشة'
       Desc  = 'تحديثات ويندوز ما تستبدل تعريف NVIDIA اللي ثبّته بنفسك بنسخة أقدم.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'ExcludeWUDriversInQualityUpdate'; V = 1 } )
    }
    @{ Id = 'noautoreboot'; Cat = 'sys'; Rec = $true; Risk = 'safe'
       Title = 'منع إعادة التشغيل المفاجئة للتحديثات'
       Desc  = 'ويندوز ما يعيد تشغيل الجهاز لحاله وأنت فاتح جهازك، فما تنقطع عليك قيم.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoRebootWithLoggedOnUsers'; V = 1 } )
    }
    @{ Id = 'storeupdate'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف تحديث تطبيقات المتجر تلقائياً'
       Desc  = 'المتجر ما يحمّل تحديثات بالخلفية وأنت تلعب. بس لازم تحدّث تطبيقاتك بنفسك.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'AutoDownload'; V = 2 } )
    }
    @{ Id = 'maint'; Cat = 'sys'; Rec = $false; Risk = 'medium'
       Title = 'إيقاف الصيانة التلقائية'
       Desc  = 'ويندوز ما يشغّل مهام الصيانة الثقيلة بالخلفية وقت ما يشوف الجهاز فاضي.'
       Reg   = @( @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; N = 'MaintenanceDisabled'; V = 1 } )
    }
)

$script:TweakMap = @{}
foreach ($t in $Tweaks) { $script:TweakMap[$t.Id] = $t }

function Test-Tweak($t) {
    try {
        if ($t.Check) { return [bool](& $t.Check) }
        if ($t.Reg)   { return (Test-RegList $t.Reg) }
        if ($t.Pwr)   { foreach ($p in $t.Pwr) { if ("$(Get-PowerIndex $p.S $p.K)" -ne "$($p.V)") { return $false } }; return $true }
        if ($t.Svc) {
            $found = 0
            foreach ($s in $t.Svc) {
                $svc = Get-Service -Name $s.N -ErrorAction SilentlyContinue
                if (-not $svc) { continue }
                $found++
                if ($svc.StartType.ToString() -ne 'Disabled') { return $false }
            }
            return ($found -gt 0)
        }
    } catch {}
    return $false
}

function Invoke-Apply($t) {
    try {
        if ($t.Reg) { foreach ($r in $t.Reg) { $type = if ($r.T) { $r.T } else { 'DWord' }; Set-Reg $r.P $r.N $r.V $type } }
        if ($t.Pwr) { foreach ($p in $t.Pwr) { Set-PowerSetting $p } }
        if ($t.Svc) { foreach ($s in $t.Svc) { Set-Svc $s.N } }
        if ($t.Apply) { & $t.Apply }
        if ($t.Restart) { $script:NeedRestart = $true }
        Write-Log "APPLY  $($t.Id)"
    } catch { Write-Log "ERROR apply $($t.Id): $($_.Exception.Message)" }
}

function Invoke-Revert($t) {
    try {
        if ($t.Reg) { foreach ($r in $t.Reg) { Restore-Reg $r } }
        if ($t.Pwr) { foreach ($p in $t.Pwr) { Restore-PowerSetting $p } }
        if ($t.Svc) { foreach ($s in $t.Svc) { Restore-Svc $s.N $s.D } }
        if ($t.Revert) { & $t.Revert }
        if ($t.Restart) { $script:NeedRestart = $true }
        Write-Log "REVERT $($t.Id)"
    } catch { Write-Log "ERROR revert $($t.Id): $($_.Exception.Message)" }
}

# ---------- برامج بدء التشغيل ----------
$SA = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
function Get-StartupItems {
    $list = New-Object System.Collections.ArrayList
    $srcs = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKCU:\$SA\Run"; Scope = 'هذا المستخدم' }
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKLM:\$SA\Run"; Scope = 'كل المستخدمين' }
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKLM:\$SA\Run32"; Scope = 'كل المستخدمين' }
    )
    foreach ($s in $srcs) {
        try { $k = Get-Item -LiteralPath $s.Run -ErrorAction Stop } catch { continue }
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            [void]$list.Add(@{ Name = $n; Show = $n; Cmd = [string]$k.GetValue($n); Appr = $s.Appr; Scope = $s.Scope })
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup');       Appr = "HKCU:\$SA\StartupFolder"; Scope = 'مجلد بدء التشغيل' }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM:\$SA\StartupFolder"; Scope = 'مجلد بدء التشغيل' }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not (Test-Path $f.Dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            [void]$list.Add(@{ Name = $file.Name; Show = [IO.Path]::GetFileNameWithoutExtension($file.Name); Cmd = $file.FullName; Appr = $f.Appr; Scope = $f.Scope })
        }
    }
    return $list
}

function Test-StartupEnabled($it) {
    $b = Get-RegValue $it.Appr $it.Name
    if ($null -eq $b) { return $true }
    $arr = [byte[]]$b
    if ($arr.Length -eq 0) { return $true }
    return (($arr[0] -band 1) -eq 0)
}

function Set-StartupEnabled($it, $on) {
    if (-not (Test-Path -LiteralPath $it.Appr)) { New-Item -Path $it.Appr -Force | Out-Null }
    if ($on) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
    else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
    New-ItemProperty -LiteralPath $it.Appr -Name $it.Name -Value $bytes -PropertyType Binary -Force | Out-Null
    Write-Log "STARTUP $($it.Name) = $on"
}

# ============================================================
#  الواجهة
# ============================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zero Lag" Width="1140" Height="740" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0F0318" FlowDirection="RightToLeft" FontFamily="Segoe UI"
        Foreground="#FBEFFF" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#FFD23F" Offset="0"/>
      <GradientStop Color="#FF2E88" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="RingGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#00E5FF" Offset="0"/>
      <GradientStop Color="#B44CFF" Offset="0.5"/>
      <GradientStop Color="#FF2E88" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="SunGrad" StartPoint="0.5,0" EndPoint="0.5,1">
      <GradientStop Color="#FFE45C" Offset="0"/>
      <GradientStop Color="#FF9A3D" Offset="0.5"/>
      <GradientStop Color="#FF2E88" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="SunMask" StartPoint="0.5,0" EndPoint="0.5,1">
      <GradientStop Color="#FF000000" Offset="0"/>
      <GradientStop Color="#FF000000" Offset="0.56"/>
      <GradientStop Color="#00000000" Offset="0.56"/>
      <GradientStop Color="#00000000" Offset="0.59"/>
      <GradientStop Color="#FF000000" Offset="0.59"/>
      <GradientStop Color="#FF000000" Offset="0.66"/>
      <GradientStop Color="#00000000" Offset="0.66"/>
      <GradientStop Color="#00000000" Offset="0.71"/>
      <GradientStop Color="#FF000000" Offset="0.71"/>
      <GradientStop Color="#FF000000" Offset="0.77"/>
      <GradientStop Color="#00000000" Offset="0.77"/>
      <GradientStop Color="#00000000" Offset="0.83"/>
      <GradientStop Color="#FF000000" Offset="0.83"/>
      <GradientStop Color="#FF000000" Offset="0.88"/>
      <GradientStop Color="#00000000" Offset="0.88"/>
      <GradientStop Color="#00000000" Offset="0.95"/>
      <GradientStop Color="#FF000000" Offset="0.95"/>
      <GradientStop Color="#FF000000" Offset="1"/>
    </LinearGradientBrush>
    <FontFamily x:Key="BrandFont">Bahnschrift, Segoe UI</FontFamily>
    <FontFamily x:Key="IconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="#3A1A55" Margin="1"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#170826"/>
      <Setter Property="BorderBrush" Value="#2A1240"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="20,16"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="#66FF2E88"/>
          <Setter Property="Background" Value="#1C0B2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FlowDirection" Value="LeftToRight"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid x:Name="Root" Width="46" Height="26" Background="Transparent">
              <Border CornerRadius="13">
                <Border.Background><SolidColorBrush x:Name="TrackBrush" Color="#2E1445"/></Border.Background>
              </Border>
              <Ellipse Width="20" Height="20" HorizontalAlignment="Left" Margin="3,0,0,0">
                <Ellipse.Fill><SolidColorBrush x:Name="KnobBrush" Color="#A88BC4"/></Ellipse.Fill>
                <Ellipse.RenderTransform><TranslateTransform x:Name="KnobT" X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="KnobT" Storyboard.TargetProperty="X" To="20" Duration="0:0:0.2">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <ColorAnimation Storyboard.TargetName="TrackBrush" Storyboard.TargetProperty="Color" To="#FF2E88" Duration="0:0:0.2"/>
                      <ColorAnimation Storyboard.TargetName="KnobBrush" Storyboard.TargetProperty="Color" To="#FFFFFF" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="KnobT" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.2">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <ColorAnimation Storyboard.TargetName="TrackBrush" Storyboard.TargetProperty="Color" To="#2E1445" Duration="0:0:0.2"/>
                      <ColorAnimation Storyboard.TargetName="KnobBrush" Storyboard.TargetProperty="Color" To="#A88BC4" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Root" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#B79CD6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="14,11">
                <ContentPresenter HorizontalAlignment="Left"/>
              </Border>
              <Border x:Name="Hover" Background="#FFFFFF" Opacity="0" CornerRadius="10" IsHitTestVisible="False"/>
              <Border Width="3" Height="18" CornerRadius="2" HorizontalAlignment="Left" Background="{TemplateBinding BorderBrush}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="0.04"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ActBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#FBEFFF"/>
      <Setter Property="Background" Value="#241034"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="G" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform x:Name="S" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Border Background="{TemplateBinding Background}" CornerRadius="9" Padding="16,9">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="Hover" Background="#FFFFFF" Opacity="0" CornerRadius="9" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="0.07"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="0.96" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="0.96" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="G" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CapBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="#B79CD6"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#241034"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource CapBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E5484D"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BigBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#2A0A3A"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="G" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform x:Name="S" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Ellipse x:Name="Glow" Fill="#FF2E88" Opacity="0.3" Margin="-8">
                <Ellipse.Effect><BlurEffect Radius="42"/></Ellipse.Effect>
              </Ellipse>
              <Ellipse Fill="{StaticResource SunGrad}" OpacityMask="{StaticResource SunMask}"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,30,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="Loaded">
                <BeginStoryboard>
                  <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                    <DoubleAnimation Storyboard.TargetName="Glow" Storyboard.TargetProperty="Opacity" From="0.22" To="0.6" Duration="0:0:2">
                      <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1.05" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1.05" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="G" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="RootBorder">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="244"/>
        <ColumnDefinition/>
      </Grid.ColumnDefinitions>

      <!-- الشريط الجانبي -->
      <Border Grid.Column="0" Background="#0C0214" BorderBrush="#1E0A2E" BorderThickness="0,0,1,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,22,22,26">
            <Border Width="42" Height="42" CornerRadius="12" Background="#1C0B2E" BorderBrush="#3A1A55" BorderThickness="1">
              <Ellipse Width="26" Height="26" Fill="{StaticResource SunGrad}" OpacityMask="{StaticResource SunMask}"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="ZERO LAG" FontFamily="{StaticResource BrandFont}" FontSize="19" FontWeight="Bold" FontStyle="Italic" Foreground="{StaticResource AccentGrad}" FlowDirection="LeftToRight" HorizontalAlignment="Left"/>
              <TextBlock x:Name="VersionText" Foreground="#7A5E96" FontSize="11"/>
            </StackPanel>
          </StackPanel>
          <Border DockPanel.Dock="Bottom" Margin="14,0,14,16" Padding="14,12" CornerRadius="12" Background="#170826" BorderBrush="#2A1240" BorderThickness="1">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="7" Height="7" Fill="#00E5FF" VerticalAlignment="Center"/>
                <TextBlock Text="الحماية مفعّلة" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock Text="كل تعديل ينحفظ أصله وتقدر ترجعه بضغطة" Foreground="#8E72AA" FontSize="11" TextWrapping="Wrap" Margin="0,5,0,0"/>
            </StackPanel>
          </Border>
          <StackPanel x:Name="NavPanel" Margin="12,0"/>
        </DockPanel>
      </Border>

      <!-- المحتوى -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="44"/>
          <RowDefinition/>
          <RowDefinition Height="34"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="6,5,6,0">
          <Button x:Name="MinBtn" Style="{StaticResource CapBtn}" Content="&#xE921;"/>
          <Button x:Name="MaxBtn" Style="{StaticResource CapBtn}" Content="&#xE922;"/>
          <Button x:Name="CloseBtn" Style="{StaticResource CloseBtn}" Content="&#xE8BB;"/>
        </StackPanel>

        <Grid x:Name="ContentHost" Grid.Row="1" Margin="34,0,26,0">
          <ScrollViewer x:Name="HomePage" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="0,0,10,16">
              <TextBlock Text="الرئيسية" FontSize="28" FontWeight="Bold" FontStyle="Italic"/>
              <TextBlock Text="اضغط الزر وخل الباقي علينا." Foreground="#A88BC4" Margin="0,4,0,20"/>

              <!-- البطاقة الرئيسية: غروب ريترو -->
              <Border x:Name="Hero" CornerRadius="18" BorderBrush="#3A1A55" BorderThickness="1">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#10031C" Offset="0"/>
                    <GradientStop Color="#2A0A40" Offset="0.72"/>
                    <GradientStop Color="#55104F" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition/>
                    <RowDefinition Height="78"/>
                  </Grid.RowDefinitions>
                  <Canvas x:Name="StarCanvas" IsHitTestVisible="False" ClipToBounds="True"/>
                  <Grid Margin="26,18,26,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition/>
                    </Grid.ColumnDefinitions>
                    <Grid Width="236" Height="236" FlowDirection="LeftToRight" VerticalAlignment="Bottom" Margin="0,0,0,10">
                      <Ellipse Stroke="#2E1445" StrokeThickness="8" Margin="5"/>
                      <Path x:Name="RingPath" Stroke="{StaticResource RingGrad}" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                        <Path.Effect><DropShadowEffect Color="#FF2E88" BlurRadius="16" ShadowDepth="0" Opacity="0.8"/></Path.Effect>
                      </Path>
                      <Button x:Name="OptimizeBtn" Style="{StaticResource BigBtn}" Width="180" Height="180">
                        <StackPanel FlowDirection="RightToLeft">
                          <Path Data="M 58,8 L 22,56 L 46,56 L 40,92 L 78,42 L 54,42 L 62,8 Z" Fill="#2A0A3A" Stretch="Uniform" Height="30" HorizontalAlignment="Center"/>
                          <TextBlock x:Name="OptimizeLabel" Text="حسّن الحين" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,6,0,0"/>
                        </StackPanel>
                      </Button>
                    </Grid>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="30,0,0,10">
                      <TextBlock Text="SYSTEM BOOST" FontFamily="{StaticResource BrandFont}" FontStyle="Italic" FontSize="12" Foreground="#00E5FF" FlowDirection="LeftToRight" HorizontalAlignment="Left"/>
                      <TextBlock x:Name="HeroTitle" Text="جاهز للتحسين" FontSize="22" FontWeight="Bold" Margin="0,4,0,0"/>
                      <TextBlock TextWrapping="Wrap" Foreground="#C9B2E0" Margin="0,8,0,14" LineHeight="21" Text="يطبّق كل التعديلات الآمنة والموصى بها مرة وحدة. التعديلات الحساسة ما تنطبق إلا إذا شغلتها بنفسك من صفحتها."/>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock x:Name="PctText" Text="0%" FontFamily="{StaticResource BrandFont}" FontStyle="Italic" FontSize="46" FontWeight="Bold" Foreground="{StaticResource AccentGrad}" VerticalAlignment="Bottom"/>
                        <TextBlock x:Name="ScoreText" Foreground="#C9B2E0" FontSize="13" Margin="12,0,0,11" VerticalAlignment="Bottom"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                        <CheckBox x:Name="RestoreChk" Style="{StaticResource Switch}" IsChecked="True" VerticalAlignment="Center"/>
                        <TextBlock Text="أنشئ نقطة استعادة قبل التحسين" Foreground="#D2BFE6" Margin="12,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                    </StackPanel>
                  </Grid>
                  <Grid Grid.Row="1" Background="#160426" ClipToBounds="True">
                    <Canvas x:Name="FloorCanvas" ClipToBounds="True">
                      <Canvas.OpacityMask>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                          <GradientStop Color="#40000000" Offset="0"/>
                          <GradientStop Color="#FF000000" Offset="1"/>
                        </LinearGradientBrush>
                      </Canvas.OpacityMask>
                    </Canvas>
                    <Border Height="2" VerticalAlignment="Top" Background="#FF2E88">
                      <Border.Effect><DropShadowEffect Color="#FF2E88" BlurRadius="16" ShadowDepth="0" Opacity="1"/></Border.Effect>
                    </Border>
                  </Grid>
                </Grid>
              </Border>

              <!-- التثبيت -->
              <Border x:Name="InstallBanner" CornerRadius="14" Padding="20,16" Margin="0,14,0,0" BorderBrush="#66FF2E88" BorderThickness="1" Background="#1C0B2E" Visibility="Collapsed">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="خلّه تطبيق دايم على سطح المكتب" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Text="يسوي له أيقونة على سطح المكتب وفي قائمة ابدأ، ويفتح مباشرة بدون نافذة سوداء." Foreground="#A88BC4" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <Button x:Name="InstallBtn" Grid.Column="1" Style="{StaticResource ActBtn}" Content="ثبّت الحين" Background="{StaticResource AccentGrad}" Foreground="#2A0A3A" Margin="16,0,0,0" VerticalAlignment="Center"/>
                </Grid>
              </Border>

              <!-- التحديث -->
              <Border x:Name="UpdateBanner" CornerRadius="14" Padding="20,16" Margin="0,14,0,0" BorderBrush="#00E5FF" BorderThickness="1" Background="#0A1E2E" Visibility="Collapsed">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock x:Name="UpdateText" Text="فيه تحديث جديد" FontSize="15" FontWeight="SemiBold" Foreground="#00E5FF"/>
                    <TextBlock x:Name="UpdateNotes" Foreground="#C9B2E0" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <Button x:Name="UpdateBtn" Grid.Column="1" Style="{StaticResource ActBtn}" Content="حدّث الحين" Background="#00E5FF" Foreground="#06121A" Margin="16,0,0,0" VerticalAlignment="Center"/>
                </Grid>
              </Border>

              <!-- مراقبة الجهاز -->
              <TextBlock Text="جهازك الحين" FontSize="17" FontWeight="SemiBold" Margin="2,24,0,12"/>
              <UniformGrid Columns="2">
                <Border Style="{StaticResource Card}" Margin="0,0,6,12">
                  <StackPanel>
                    <TextBlock Text="المعالج" Foreground="#A88BC4" FontSize="12"/>
                    <TextBlock x:Name="CpuName" FontWeight="SemiBold" FontSize="14" Margin="0,6,0,12" TextTrimming="CharacterEllipsis" FlowDirection="LeftToRight" HorizontalAlignment="Left"/>
                    <Grid x:Name="CpuBarHost" Height="6">
                      <Border Background="#2E1445" CornerRadius="3"/>
                      <Border x:Name="CpuBarFill" Width="0" HorizontalAlignment="Left" CornerRadius="3" Background="{StaticResource AccentGrad}"/>
                    </Grid>
                    <TextBlock x:Name="CpuUse" Text="الاستهلاك: --" Foreground="#A88BC4" FontSize="12" Margin="0,8,0,0"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="6,0,0,12">
                  <StackPanel>
                    <TextBlock Text="الرام" Foreground="#A88BC4" FontSize="12"/>
                    <TextBlock x:Name="RamName" FontWeight="SemiBold" FontSize="14" Margin="0,6,0,12"/>
                    <Grid x:Name="RamBarHost" Height="6">
                      <Border Background="#2E1445" CornerRadius="3"/>
                      <Border x:Name="RamBarFill" Width="0" HorizontalAlignment="Left" CornerRadius="3" Background="#00E5FF"/>
                    </Grid>
                    <TextBlock x:Name="RamUse" Text="المستخدم: --" Foreground="#A88BC4" FontSize="12" Margin="0,8,0,0"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,6,0">
                  <StackPanel>
                    <TextBlock Text="كرت الشاشة" Foreground="#A88BC4" FontSize="12"/>
                    <TextBlock x:Name="GpuName" FontWeight="SemiBold" FontSize="14" Margin="0,6,0,0" TextTrimming="CharacterEllipsis" FlowDirection="LeftToRight" HorizontalAlignment="Left"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="6,0,0,0">
                  <StackPanel>
                    <TextBlock Text="خطة الطاقة" Foreground="#A88BC4" FontSize="12"/>
                    <TextBlock x:Name="PlanName" FontWeight="SemiBold" FontSize="14" Margin="0,6,0,0"/>
                  </StackPanel>
                </Border>
              </UniformGrid>

              <TextBlock Text="أدوات سريعة" FontSize="17" FontWeight="SemiBold" Margin="2,24,0,12"/>
              <WrapPanel x:Name="QuickPanel"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <!-- شريط الحالة -->
        <Grid Grid.Row="2" Margin="34,0,26,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Path x:Name="Spinner" Width="13" Height="13" Stretch="Uniform" Stroke="#FF2E88" StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Data="M 7,1 A 6,6 0 1 1 1,7" RenderTransformOrigin="0.5,0.5" Visibility="Collapsed" Margin="0,0,10,0">
              <Path.RenderTransform><RotateTransform Angle="0"/></Path.RenderTransform>
            </Path>
            <TextBlock x:Name="StatusText" Foreground="#8E72AA" FontSize="12" Text="جاهز"/>
          </StackPanel>
        </Grid>

        <!-- التنبيه المنزلق -->
        <Border x:Name="Toast" Grid.RowSpan="3" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,46"
                Padding="18,12" CornerRadius="12" Background="#1E0B30" BorderBrush="#3A1A55" BorderThickness="1" Opacity="0" IsHitTestVisible="False">
          <Border.RenderTransform><TranslateTransform Y="16"/></Border.RenderTransform>
          <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="6" Opacity="0.55" Color="#000000"/></Border.Effect>
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="ToastDot" Width="8" Height="8" Fill="#00E5FF" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock x:Name="ToastText" FontSize="13"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- نافذة الحوار -->
      <Grid x:Name="DialogLayer" Grid.ColumnSpan="2" Visibility="Collapsed" Background="#C8070210">
        <Border x:Name="DialogCard" Width="470" HorizontalAlignment="Center" VerticalAlignment="Center" Background="#170826"
                BorderBrush="#3A1A55" BorderThickness="1" CornerRadius="18" Padding="28,24" RenderTransformOrigin="0.5,0.5">
          <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
          <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="10" Opacity="0.6" Color="#000000"/></Border.Effect>
          <StackPanel>
            <TextBlock x:Name="DialogTitle" FontSize="19" FontWeight="SemiBold"/>
            <TextBlock x:Name="DialogBody" TextWrapping="Wrap" Foreground="#D2BFE6" Margin="0,12,0,18" LineHeight="22"/>
            <ContentControl x:Name="DialogExtra" Margin="0,0,0,18"/>
            <StackPanel x:Name="DialogButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'RootBorder','Hero','UpdateBanner','UpdateText','UpdateNotes','UpdateBtn','StarCanvas','FloorCanvas','NavPanel','ContentHost','HomePage','OptimizeBtn','OptimizeLabel','HeroTitle','PctText','ScoreText','RingPath',
               'RestoreChk','InstallBanner','InstallBtn','CpuName','CpuBarHost','CpuBarFill','CpuUse','RamName','RamBarHost','RamBarFill',
               'RamUse','GpuName','PlanName','QuickPanel','Spinner','StatusText','Toast','ToastDot','ToastText','DialogLayer','DialogCard',
               'DialogTitle','DialogBody','DialogExtra','DialogButtons','VersionText','MinBtn','MaxBtn','CloseBtn') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

$BC = New-Object Windows.Media.BrushConverter
function Brush($hex) { $BC.ConvertFromString($hex) }
$AccentGrad = $window.FindResource('AccentGrad')
function T($l, $t, $r, $b) { New-Object Windows.Thickness($l, $t, $r, $b) }

function Update-UI { $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) }
function Set-Status($msg) { $StatusText.Text = $msg; Update-UI }

function New-Anim($to, $ms, $from = $null) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $from) { $a.From = [double]$from }
    $a.To = [double]$to
    $a.Duration = New-Object Windows.Duration([TimeSpan]::FromMilliseconds($ms))
    $e = New-Object Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $a.EasingFunction = $e
    return $a
}

# ---------- مؤشر الانشغال ----------
$script:BusyCount = 0
function Set-Busy($on) {
    if ($on) { $script:BusyCount++ } else { $script:BusyCount = [math]::Max(0, $script:BusyCount - 1) }
    $rot = $Spinner.RenderTransform
    if ($script:BusyCount -gt 0) {
        $Spinner.Visibility = 'Visible'
        $a = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(800))))
        $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $a)
    } else {
        $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
        $Spinner.Visibility = 'Collapsed'
    }
}

# ---------- التنبيه المنزلق ----------
$script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(3000)
$script:ToastTimer.Add_Tick({
    $script:ToastTimer.Stop()
    $Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0 240))
    $Toast.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim 16 240))
})
function Show-Toast($msg, $kind = 'ok') {
    $ToastText.Text = $msg
    $ToastDot.Fill = switch ($kind) { 'warn' { Brush '#FF9A3D' } 'err' { Brush '#FF4D6D' } default { Brush '#00E5FF' } }
    $Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1 220))
    $Toast.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim 0 280 16))
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
    $StatusText.Text = $msg
}

# ---------- نافذة الحوار داخل التطبيق ----------
function Show-Dialog($title, $body, [string[]]$buttons = @('حسناً'), [int]$primary = 0, [bool]$danger = $false, $extra = $null) {
    $DialogTitle.Text = $title; $DialogBody.Text = $body
    $DialogExtra.Content = $extra
    $DialogExtra.Visibility = if ($extra) { 'Visible' } else { 'Collapsed' }
    $DialogButtons.Children.Clear()
    $script:DialogResult = $null
    $script:DialogFrame = New-Object Windows.Threading.DispatcherFrame
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('ActBtn'); $b.Content = $buttons[$i]; $b.Tag = $buttons[$i]
        $b.MinWidth = 96; $b.Margin = T 0 0 10 0
        if ($i -eq $primary) {
            if ($danger) { $b.Background = Brush '#E5484D'; $b.Foreground = Brush '#FFFFFF' }
            else { $b.Background = $AccentGrad; $b.Foreground = Brush '#2A0A3A' }
        }
        $b.Add_Click({ $script:DialogResult = [string]$this.Tag; $script:DialogFrame.Continue = $false })
        [void]$DialogButtons.Children.Add($b)
    }
    $DialogLayer.Visibility = 'Visible'
    $DialogLayer.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1 180 0))
    $sc = $DialogCard.RenderTransform
    $sc.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim 1 240 0.93))
    $sc.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim 1 240 0.93))
    [Windows.Threading.Dispatcher]::PushFrame($script:DialogFrame)
    $DialogExtra.Content = $null
    $DialogLayer.Visibility = 'Collapsed'
    return $script:DialogResult
}
function Ask-YesNo($text, [bool]$danger = $false, $title = 'تأكيد') { return ((Show-Dialog $title $text @('نعم', 'لا') 0 $danger) -eq 'نعم') }

# ---------- مهام بالخلفية (عشان الواجهة ما تعلق) ----------
$script:Jobs = New-Object System.Collections.ArrayList
$script:JobTimer = New-Object Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:JobTimer.Add_Tick({
    foreach ($j in @($script:Jobs)) {
        if ($j.Handle.IsCompleted) {
            $res = @(); $err = $null
            try { $res = @($j.PS.EndInvoke($j.Handle)) } catch { $err = $_.Exception.Message }
            $j.PS.Dispose(); [void]$script:Jobs.Remove($j); Set-Busy $false
            try { & $j.Done $res $err } catch { Show-Toast "خطأ: $($_.Exception.Message)" 'err' }
        }
    }
    if ($script:Jobs.Count -eq 0) { $script:JobTimer.Stop() }
})
function Start-Bg($Script, $Done) {
    $ps = [powershell]::Create(); [void]$ps.AddScript($Script)
    $h = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PS = $ps; Handle = $h; Done = $Done })
    Set-Busy $true; $script:JobTimer.Start()
}

$RestoreScript = {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Zero Lag' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        'ok'
    } catch { $_.Exception.Message }
}

$PingScript = {
    foreach ($h in @('8.8.8.8', '1.1.1.1')) {
        try {
            $r = Test-Connection -ComputerName $h -Count 10 -ErrorAction Stop
            $m = $r | Measure-Object ResponseTime -Average -Minimum -Maximum
            [pscustomobject]@{ H = $h; Ok = $true; Avg = [math]::Round($m.Average); Min = $m.Minimum; Max = $m.Maximum }
        } catch { [pscustomobject]@{ H = $h; Ok = $false } }
    }
}

$CleanScript = {
    function SizeOf($p) { [double]((Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) }
    $paths = @($env:TEMP, "$env:WINDIR\Temp", "$env:LOCALAPPDATA\CrashDumps", "$env:WINDIR\SoftwareDistribution\Download")
    $before = 0; $after = 0
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $isWU = $p -like '*SoftwareDistribution*'
        if ($isWU) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }
        $before += SizeOf $p
        Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after += SizeOf $p
        if ($isWU) { Start-Service wuauserv -ErrorAction SilentlyContinue }
    }
    [math]::Round(($before - $after) / 1MB)
}

# ---------- الأدوات ----------
function Test-Ping {
    Set-Status 'جاري اختبار البنق...'
    Start-Bg $PingScript {
        param($r, $e)
        $lines = @()
        foreach ($x in $r) {
            if ($x.Ok) {
                $jit = $x.Max - $x.Min
                $q = if ($x.Avg -le 40) { 'ممتاز' } elseif ($x.Avg -le 70) { 'جيد' } else { 'مرتفع' }
                $lines += "$($x.H)`n   المتوسط $($x.Avg) ms ($q)   |   أقل $($x.Min)   أعلى $($x.Max)   |   التذبذب $jit ms"
            } else { $lines += "$($x.H)`n   ما رد" }
        }
        Set-Status 'جاهز'
        [void](Show-Dialog 'نتيجة البنق' ($lines -join "`n`n"))
    }
}

function Clear-TempFiles {
    Set-Status 'جاري تنظيف الملفات المؤقتة...'
    Start-Bg $CleanScript { param($r, $e) $mb = if ($r.Count) { $r[0] } else { 0 }; Show-Toast "تم التنظيف وفضّيت $mb ميقا" }
}

function Clear-Dns { ipconfig /flushdns | Out-Null; Show-Toast 'تم مسح كاش DNS' }

function Clear-Ram {
    if (-not $script:NativeOk) { Show-Toast 'هالميزة مو متاحة على جهازك' 'warn'; return }
    $rc = [GBNative]::PurgeStandby()
    if ($rc -eq 0) { Show-Toast 'تم تفريغ ذاكرة الـ Standby' } else { Show-Toast "ما قدرت أفرّغ الرام (رمز $rc)" 'warn' }
}

function New-RestorePointUI {
    Set-Status 'جاري إنشاء نقطة استعادة...'
    Start-Bg $RestoreScript { param($r, $e) if ($r.Count -and $r[0] -eq 'ok') { Show-Toast 'تم إنشاء نقطة الاستعادة' } else { Show-Toast "ما انحفظت نقطة الاستعادة: $($r[0])$e" 'warn' } }
}

function Revert-All {
    if (-not (Ask-YesNo 'هذا يرجّع كل التعديلات المفعّلة لقيمها الأصلية أو لإعدادات ويندوز الافتراضية. متأكد؟' $true)) { return }
    Set-Busy $true
    foreach ($t in $Tweaks) { if (Test-Tweak $t) { Set-Status "إرجاع: $($t.Title)"; Invoke-Revert $t } }
    Set-Busy $false
    Refresh-All
    Show-Toast 'تم إرجاع كل شيء. يفضّل تسوي ريستارت'
}

function Restart-PC { if (Ask-YesNo 'تبي تعيد تشغيل الجهاز الحين؟ احفظ شغلك قبل.') { Restart-Computer -Force } }

# ---------- الأيقونة والتثبيت ----------
function New-IconBitmap([int]$size) {
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $full = New-Object Windows.Rect(0, 0, $size, $size)
    $dc.PushClip((New-Object Windows.Media.RectangleGeometry($full, ($size * 0.24), ($size * 0.24))))
    $bg = Brush '#1A0629'
    $dc.DrawRectangle($bg, $null, $full)
    $sun = New-Object Windows.Media.LinearGradientBrush
    $sun.StartPoint = New-Object Windows.Point(0.5, 0); $sun.EndPoint = New-Object Windows.Point(0.5, 1)
    $sun.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromRgb(0xFF, 0xE4, 0x5C), 0)))
    $sun.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromRgb(0xFF, 0x9A, 0x3D), 0.5)))
    $sun.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromRgb(0xFF, 0x2E, 0x88), 1)))
    $r = $size * 0.31
    $dc.DrawEllipse($sun, $null, (New-Object Windows.Point(($size / 2), ($size * 0.47))), $r, $r)
    for ($k = 0; $k -lt 4; $k++) {
        $y = $size * (0.50 + $k * 0.065); $hgt = $size * (0.014 + $k * 0.008)
        $dc.DrawRectangle($bg, $null, (New-Object Windows.Rect(0, $y, $size, $hgt)))
    }
    $dc.DrawRectangle((Brush '#160426'), $null, (New-Object Windows.Rect(0, ($size * 0.76), $size, ($size * 0.24))))
    $pen = New-Object Windows.Media.Pen((Brush '#FF2E88'), [math]::Max(1, $size / 64))
    $hy = $size * 0.76
    $dc.DrawLine($pen, (New-Object Windows.Point(0, $hy)), (New-Object Windows.Point($size, $hy)))
    foreach ($f in 0.84, 0.94) { $dc.DrawLine($pen, (New-Object Windows.Point(0, ($size * $f))), (New-Object Windows.Point($size, ($size * $f)))) }
    foreach ($dx in -0.9, -0.45, 0, 0.45, 0.9) { $dc.DrawLine($pen, (New-Object Windows.Point(($size / 2), $hy)), (New-Object Windows.Point(($size / 2 + $dx * $size), $size))) }
    $dc.Pop(); $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($size, $size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    return $bmp
}

function Get-PngBytes($bmp) {
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $b = $ms.ToArray(); $ms.Dispose(); return ,$b
}

function Save-AppIcon($path) {
    $imgs = foreach ($s in 256, 64, 48, 32, 16) { @{ S = $s; B = (Get-PngBytes (New-IconBitmap $s)) } }
    $fs = [IO.File]::Create($path); $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$imgs.Count)
    $offset = 6 + 16 * $imgs.Count
    foreach ($i in $imgs) {
        $w = if ($i.S -ge 256) { 0 } else { $i.S }
        $bw.Write([byte]$w); $bw.Write([byte]$w); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$i.B.Length); $bw.Write([uint32]$offset)
        $offset += $i.B.Length
    }
    foreach ($i in $imgs) { $bw.Write([byte[]]$i.B) }
    $bw.Close()
}

$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Zero Lag.lnk'
$StartLnk   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Zero Lag.lnk'
function Test-Installed { Test-Path -LiteralPath $DesktopLnk }

function Install-App {
    try {
        $dest = Join-Path $AppDir 'app'
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        $target = Join-Path $dest 'ZeroLag.ps1'
        if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
        Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
        $ico = Join-Path $dest 'ZeroLag.ico'; Save-AppIcon $ico
        $vbs = Join-Path $dest 'launch.vbs'
        $vbsText = 'Set sh = CreateObject("Shell.Application")' + "`r`n" +
                   'sh.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""' + $target + '""", "", "runas", 0' + "`r`n"
        Set-Content -LiteralPath $vbs -Value $vbsText -Encoding Unicode
        $ws = New-Object -ComObject WScript.Shell
        foreach ($lnk in @($DesktopLnk, $StartLnk)) {
            $s = $ws.CreateShortcut($lnk)
            $s.TargetPath = "$env:WINDIR\System32\wscript.exe"
            $s.Arguments = "`"$vbs`""
            $s.IconLocation = "$ico,0"
            $s.WorkingDirectory = $dest
            $s.Description = 'Zero Lag - تحسين الأداء'
            $s.Save()
        }
        foreach ($old in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Ghazi Boost.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Ghazi Boost.lnk'))) {
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'INSTALLED'
        $InstallBanner.Visibility = 'Collapsed'
        Show-Toast 'تم التثبيت، الأيقونة صارت على سطح المكتب وفي قائمة ابدأ'
    } catch { Show-Toast "ما قدرت أثبّت: $($_.Exception.Message)" 'err' }
}

# ---------- بناء الكروت ----------
$script:Switches = @{}

function New-Badge($text, $fg, $bg) {
    $b = New-Object Windows.Controls.Border
    $b.Background = Brush $bg; $b.CornerRadius = New-Object Windows.CornerRadius(6)
    $b.Padding = T 8 2 8 3; $b.Margin = T 8 0 0 0; $b.VerticalAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $text; $tb.FontSize = 11; $tb.Foreground = Brush $fg
    $b.Child = $tb
    return $b
}

function New-Card { $b = New-Object Windows.Controls.Border; $b.Style = $window.FindResource('Card'); return $b }

function New-TwoCol {
    $g = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = New-Object Windows.GridLength(1, 'Star')
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    return $g
}

function New-CardBody($title, $desc, $badges, $descLtr = $false) {
    $sp = New-Object Windows.Controls.StackPanel
    $row = New-Object Windows.Controls.WrapPanel
    $tt = New-Object Windows.Controls.TextBlock
    $tt.Text = $title; $tt.FontSize = 15; $tt.FontWeight = 'SemiBold'; $tt.VerticalAlignment = 'Center'
    [void]$row.Children.Add($tt)
    foreach ($b in $badges) { [void]$row.Children.Add($b) }
    [void]$sp.Children.Add($row)
    if ($desc) {
        $d = New-Object Windows.Controls.TextBlock
        $d.Text = $desc; $d.TextWrapping = 'Wrap'; $d.Foreground = Brush '#A88BC4'; $d.FontSize = 12.5; $d.Margin = T 0 6 0 0
        if ($descLtr) { $d.FlowDirection = 'LeftToRight'; $d.HorizontalAlignment = 'Left'; $d.TextTrimming = 'CharacterEllipsis'; $d.TextWrapping = 'NoWrap' }
        [void]$sp.Children.Add($d)
    }
    return $sp
}

function New-Switch($tag) {
    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = $window.FindResource('Switch'); $sw.Tag = $tag
    $sw.VerticalAlignment = 'Center'; $sw.Margin = T 18 0 0 0
    [Windows.Controls.Grid]::SetColumn($sw, 1)
    return $sw
}

function New-TweakCard($t) {
    $border = New-Card; $grid = New-TwoCol
    $badges = @()
    switch ($t.Risk) {
        'safe'   { $badges += New-Badge 'آمن'  '#00E5FF' '#062A33' }
        'medium' { $badges += New-Badge 'جرّبه' '#FF9A3D' '#33190A' }
        'warn'   { $badges += New-Badge 'تنبيه' '#FF4D6D' '#3A0F1C' }
    }
    if ($t.Rec)     { $badges += New-Badge 'موصى به' '#FFD23F' '#33280A' }
    if ($t.Restart) { $badges += New-Badge 'يحتاج ريستارت' '#A88BC4' '#2A1240' }
    [void]$grid.Children.Add((New-CardBody $t.Title $t.Desc $badges))
    $sw = New-Switch $t.Id
    $sw.Add_Click({ Invoke-Toggle $this })
    [void]$grid.Children.Add($sw)
    $script:Switches[$t.Id] = $sw
    $border.Child = $grid
    return $border
}

function New-ActionButton($text, $action, $primary = $false, $data = $null) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $window.FindResource('ActBtn'); $btn.Content = $text
    $btn.Tag = @{ A = $action; D = $data }
    if ($primary) { $btn.Background = $AccentGrad; $btn.Foreground = Brush '#2A0A3A' }
    $btn.Add_Click({
        $tg = $this.Tag; $this.IsEnabled = $false
        try { & $tg.A $tg.D } catch { Show-Toast "خطأ: $($_.Exception.Message)" 'err' }
        $this.IsEnabled = $true
    })
    return $btn
}

function New-ActionCard($title, $desc, $btnText, $action, $primary = $false) {
    $border = New-Card; $grid = New-TwoCol
    [void]$grid.Children.Add((New-CardBody $title $desc @()))
    $btn = New-ActionButton $btnText $action $primary
    $btn.Margin = T 18 0 0 0; $btn.VerticalAlignment = 'Center'; $btn.MinWidth = 92
    [Windows.Controls.Grid]::SetColumn($btn, 1)
    [void]$grid.Children.Add($btn)
    $border.Child = $grid
    return $border
}

# ---------- التبديل والتحديث ----------
function Invoke-Toggle($sw) {
    $t = $script:TweakMap[[string]$sw.Tag]
    $want = [bool]$sw.IsChecked
    if ($want -and $t.Warn) { if (-not (Ask-YesNo $t.Warn $true 'تنبيه')) { $sw.IsChecked = $false; return } }
    $sw.IsEnabled = $false; Set-Busy $true
    if ($want) { Set-Status "جاري تطبيق: $($t.Title)..."; Invoke-Apply $t } else { Set-Status "جاري الإرجاع: $($t.Title)..."; Invoke-Revert $t }
    $script:AdCache = $null
    $ok = Test-Tweak $t
    $sw.IsChecked = $ok; $sw.IsEnabled = $true; Set-Busy $false
    Update-Score
    if ($t.Id -eq 'powerplan' -or $t.Pwr) { Update-Plan }
    if ($want -and -not $ok) { Show-Toast "ما انطبق: $($t.Title) (ممكن جهازك ما يدعمه)" 'warn'; return }
    $msg = if ($want) { "تم تفعيل: $($t.Title)" } else { "تم الإرجاع: $($t.Title)" }
    if ($t.Restart) { Show-Toast "$msg، ويحتاج ريستارت" 'warn' } else { Show-Toast $msg }
}

function Refresh-All {
    Set-Busy $true; Set-Status 'جاري فحص الجهاز...'
    $script:AdCache = $null
    foreach ($t in $Tweaks) { $script:Switches[$t.Id].IsChecked = Test-Tweak $t; Update-UI }
    Update-Score; Update-Plan
    Set-Busy $false; Set-Status 'جاهز'
}

# ---------- حلقة النسبة ----------
$script:RingCur = 0.0; $script:RingTarget = 0.0
function Set-RingGeometry([double]$f) {
    $c = 118.0; $r = 108.0
    if ($f -le 0.002) { $RingPath.Data = $null; return }
    if ($f -ge 0.999) { $RingPath.Data = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($c, $c)), $r, $r); return }
    $a = $f * 2 * [math]::PI
    $fig = New-Object Windows.Media.PathFigure
    $fig.StartPoint = New-Object Windows.Point($c, ($c - $r)); $fig.IsClosed = $false
    $end = New-Object Windows.Point(($c + $r * [math]::Sin($a)), ($c - $r * [math]::Cos($a)))
    $fig.Segments.Add((New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0.0, ($f -gt 0.5), [Windows.Media.SweepDirection]::Clockwise, $true)))
    $geo = New-Object Windows.Media.PathGeometry; $geo.Figures.Add($fig)
    $RingPath.Data = $geo
}
$script:RingTimer = New-Object Windows.Threading.DispatcherTimer
$script:RingTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:RingTimer.Add_Tick({
    $d = $script:RingTarget - $script:RingCur
    if ([math]::Abs($d) -lt 0.002) { $script:RingCur = $script:RingTarget; $script:RingTimer.Stop() }
    else { $script:RingCur += $d * 0.12 }
    Set-RingGeometry $script:RingCur
    $PctText.Text = "$([math]::Round($script:RingCur * 100))%"
})

function Update-Score {
    $on = @($Tweaks | Where-Object { $script:Switches[$_.Id].IsChecked }).Count
    $all = $Tweaks.Count
    $ScoreText.Text = "$on من $all تحسين مفعّل"
    $script:RingTarget = $on / $all; $script:RingTimer.Start()
    $recLeft = @($Tweaks | Where-Object { $_.Rec -and -not $script:Switches[$_.Id].IsChecked }).Count
    if ($recLeft -eq 0) { $OptimizeLabel.Text = 'محسّن ✓'; $HeroTitle.Text = 'جهازك محسّن' }
    else { $OptimizeLabel.Text = 'حسّن الحين'; $HeroTitle.Text = "باقي $recLeft تحسين موصى به" }
}

function Update-Plan {
    $PlanName.Text = if (Test-Tweak $script:TweakMap['powerplan']) { 'Ultimate Performance ✓' } else { 'خطة عادية' }
}

# ---------- التحسين بضغطة ----------
function Start-Optimize {
    $pending = @($Tweaks | Where-Object { $_.Rec -and -not $script:Switches[$_.Id].IsChecked })
    if ($pending.Count -eq 0) { Show-Toast 'كل التعديلات الموصى بها مفعّلة من قبل ✓'; return }
    $OptimizeBtn.IsEnabled = $false
    if ($RestoreChk.IsChecked) {
        Set-Status 'جاري إنشاء نقطة استعادة... (ممكن تاخذ دقيقة)'
        Start-Bg $RestoreScript {
            param($r, $e)
            if (-not ($r.Count -and $r[0] -eq 'ok')) { Show-Toast 'ما انحفظت نقطة الاستعادة، بنكمل التحسين' 'warn' }
            Invoke-Optimize
        }
    } else { Invoke-Optimize }
}

function Invoke-Optimize {
    Set-Busy $true
    $n = 0; $restart = $false
    foreach ($t in ($Tweaks | Where-Object { $_.Rec })) {
        $script:AdCache = $null
        if (-not (Test-Tweak $t)) {
            Set-Status "جاري تطبيق: $($t.Title)..."
            Invoke-Apply $t; $n++
            if ($t.Restart) { $restart = $true }
        }
    }
    Set-Busy $false
    Refresh-All
    $OptimizeBtn.IsEnabled = $true
    if ($restart) {
        if (Ask-YesNo "تم تطبيق $n تحسين.`n`nبعضها يحتاج إعادة تشغيل عشان يشتغل. تعيد التشغيل الحين؟" $false 'تم التحسين ⚡') { Restart-Computer -Force }
    } else { Show-Toast "تم تطبيق $n تحسين ⚡" }
}

# ---------- التحديثات ----------
$SettingsFile = Join-Path $AppDir 'settings.json'
$script:Settings = @{ UpdateUrl = '' }
if (Test-Path $SettingsFile) {
    try { $sj = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($sj.UpdateUrl) { $script:Settings.UpdateUrl = [string]$sj.UpdateUrl } } catch {}
}
function Save-Settings { [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 }
$script:PendingUpdate = $null

function Get-UpdateBase {
    $u = $script:Settings.UpdateUrl
    if (-not $u) { $u = $DefaultUpdateUrl }
    if ($u -and $u -match '^https://[^\s''"`$;]+$') { return $u.TrimEnd('/') }
    return $null
}

function Check-Update([bool]$silent = $false) {
    $base = Get-UpdateBase
    if (-not $base) { if (-not $silent) { Show-Toast 'حط رابط التحديث أول من صفحة أدوات' 'warn' }; return }
    $script:UpdSilent = $silent
    if (-not $silent) { Set-Status 'جاري البحث عن تحديث...' }
    $sb = [scriptblock]::Create("[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { Invoke-RestMethod -Uri ('$base/version.json?t=' + [DateTime]::Now.Ticks) -UseBasicParsing -TimeoutSec 15 } catch { 'ERR:' + `$_.Exception.Message }")
    Start-Bg $sb {
        param($r, $e)
        $x = if ($r.Count) { $r[0] } else { $null }
        if (-not $x -or ($x -is [string] -and $x.StartsWith('ERR:'))) {
            if (-not $script:UpdSilent) { Show-Toast 'ما قدرت أوصل لسيرفر التحديث' 'err' }
            Set-Status 'جاهز'; return
        }
        $newer = $false
        try { $newer = ([version]([string]$x.version)) -gt ([version]$AppVersion) } catch {}
        if ($newer) {
            $script:PendingUpdate = $x
            $UpdateText.Text = "نسخة جديدة v$($x.version) جاهزة"
            $UpdateNotes.Text = if ($x.notes) { [string]$x.notes } else { 'تحسينات وإصلاحات جديدة.' }
            $UpdateBanner.Visibility = 'Visible'
            $UpdateBanner.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1 400 0))
            Show-Toast "فيه تحديث جديد v$($x.version) ⚡"
        } elseif (-not $script:UpdSilent) { Show-Toast "عندك آخر نسخة (v$AppVersion) ✓" }
        Set-Status 'جاهز'
    }
}

function Install-Update {
    $base = Get-UpdateBase; $u = $script:PendingUpdate
    if (-not $base -or -not $u) { return }
    $file = if ($u.file) { [string]$u.file } else { 'ZeroLag.ps1' }
    if ($file -notmatch '^[\w\-.]+\.ps1$') { Show-Toast 'ملف التحديث غير صالح' 'err'; return }
    $tmp = Join-Path $env:TEMP 'ZeroLag_update.ps1'
    $tmpQ = $tmp -replace "'", "''"
    Set-Status 'جاري تحميل التحديث...'
    $UpdateBtn.IsEnabled = $false
    $sb = [scriptblock]::Create("[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri ('$base/$file' + '?t=' + [DateTime]::Now.Ticks) -OutFile '$tmpQ' -UseBasicParsing -TimeoutSec 90; 'ok' } catch { 'ERR:' + `$_.Exception.Message }")
    Start-Bg $sb {
        param($r, $e)
        $UpdateBtn.IsEnabled = $true
        $tmp = Join-Path $env:TEMP 'ZeroLag_update.ps1'
        if ("$($r[0])" -ne 'ok' -or -not (Test-Path $tmp)) { Show-Toast 'ما قدرت أحمّل التحديث، جرّب بعدين' 'err'; Set-Status 'جاهز'; return }
        $tok = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$errs)
        $txt = Get-Content $tmp -Raw -Encoding UTF8
        if (($errs -and $errs.Count -gt 0) -or $txt -notmatch 'Zero Lag' -or $txt -notmatch '\$AppVersion') {
            Show-Toast 'ملف التحديث فيه مشكلة، ما ركّبته' 'err'; Set-Status 'جاهز'; return
        }
        $targets = @($script:SelfPath)
        $inst = Join-Path $AppDir 'app\ZeroLag.ps1'
        if ((Test-Path $inst) -and ($inst -ne $script:SelfPath)) { $targets += $inst }
        foreach ($t in $targets) {
            try { Copy-Item -LiteralPath $tmp -Destination $t -Force; Unblock-File -LiteralPath $t -ErrorAction SilentlyContinue } catch {}
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "UPDATED to $($script:PendingUpdate.version)"
        [void](Show-Dialog 'تم التحديث ⚡' "انحدّث Zero Lag لنسخة v$($script:PendingUpdate.version). التطبيق بيفتح من جديد الحين.")
        $script:AskedRestart = $true
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:SelfPath)`""
        $window.Close()
    }
}

function Set-UpdateUrl {
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = if ($script:Settings.UpdateUrl) { $script:Settings.UpdateUrl } else { $DefaultUpdateUrl }
    $tb.Background = Brush '#120420'; $tb.Foreground = Brush '#FBEFFF'; $tb.BorderBrush = Brush '#3A1A55'
    $tb.CaretBrush = Brush '#FF2E88'; $tb.Padding = T 8 6 8 6; $tb.FlowDirection = 'LeftToRight'; $tb.FontFamily = 'Consolas'
    $r = Show-Dialog 'رابط التحديث' 'حط رابط مجلد التحديثات (رابط raw من GitHub). التطبيق بيدوّر فيه على ملف version.json.' @('حفظ', 'إلغاء') 0 $false $tb
    if ($r -ne 'حفظ') { return }
    $u = $tb.Text.Trim()
    if ($u -and $u -notmatch '^https://[^\s''"`$;]+$') { Show-Toast 'الرابط لازم يبدأ بـ https:// وما يكون فيه مسافات' 'err'; return }
    $script:Settings.UpdateUrl = $u; Save-Settings
    Show-Toast 'انحفظ رابط التحديث'
    if ($u) { Check-Update $false }
}

# ---------- أدوات إضافية ----------
function Clear-ShaderCache {
    if (-not (Ask-YesNo 'هذا يحذف كاش الشيدر لكرت الشاشة وDirectX. يفيد إذا صار تقطيع بعد تحديث التعريف. أول مرة تفتح فيها اللعبة بعده بتاخذ وقت أطول شوي لين يتبنى الكاش من جديد. تكمل؟')) { return }
    Set-Status 'جاري تنظيف كاش الشيدر...'
    Start-Bg {
        $paths = @("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache")
        $sum = 0
        foreach ($p in $paths) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $sum += [double]((Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        [math]::Round($sum / 1MB)
    } { param($r, $e) Show-Toast "تم تنظيف كاش الشيدر ($($r[0]) ميقا)"; Set-Status 'جاهز' }
}

function Reset-Network {
    if (-not (Ask-YesNo 'هذا يعيد تشغيل كرت الشبكة ويمسح كاش DNS. النت بيفصل ثواني ويرجع. تكمل؟')) { return }
    Set-Status 'جاري إعادة تشغيل الشبكة...'
    Start-Bg {
        ipconfig /flushdns | Out-Null
        foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
        'ok'
    } { param($r, $e) $script:AdCache = $null; Show-Toast 'رجعت الشبكة تشتغل'; Set-Status 'جاهز' }
}

function Get-UsbParamKeys {
    if ($null -ne $script:UsbKeysCache) { return $script:UsbKeysCache }
    $list = @()
    foreach ($dev in Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue) {
        foreach ($inst in Get-ChildItem -LiteralPath $dev.PSPath -ErrorAction SilentlyContinue) {
            $k = "Registry::$($inst.Name)\Device Parameters"
            if (Test-Path -LiteralPath $k) { $list += $k }
        }
    }
    $script:UsbKeysCache = $list
    return $list
}
$script:UsbKeysCache = $null

# ---------- بوست الألعاب ----------
$GamesFile = Join-Path $AppDir 'games.json'
$GpuPref = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$GamePresets = @(
    @{ N = 'Fortnite';          E = 'FortniteClient-Win64-Shipping.exe' }
    @{ N = 'Valorant';          E = 'VALORANT-Win64-Shipping.exe' }
    @{ N = 'Counter-Strike 2';  E = 'cs2.exe' }
    @{ N = 'Call of Duty';      E = 'cod.exe' }
    @{ N = 'Apex Legends';      E = 'r5apex.exe' }
    @{ N = 'PUBG';              E = 'TslGame.exe' }
    @{ N = 'Rocket League';     E = 'RocketLeague.exe' }
    @{ N = 'GTA V';             E = 'GTA5.exe' }
    @{ N = 'EA Sports FC';      E = 'FC25.exe' }
    @{ N = 'Overwatch 2';       E = 'Overwatch.exe' }
    @{ N = 'League of Legends'; E = 'League of Legends.exe' }
    @{ N = 'Roblox';            E = 'RobloxPlayerBeta.exe' }
)
$script:Games = New-Object System.Collections.ArrayList
if (Test-Path $GamesFile) {
    try { $loaded = Get-Content $GamesFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($g in $loaded) { if ($g.Exe) { [void]$script:Games.Add(@{ Name = $g.Name; Exe = $g.Exe; Path = $g.Path }) } } } catch {}
}
function Save-Games { ConvertTo-Json -InputObject @($script:Games | ForEach-Object { [pscustomobject]$_ }) -Depth 3 | Set-Content -Path $GamesFile -Encoding UTF8 }

function Test-GameBoosted($g) { (Get-RegValue "$IFEO\$($g.Exe)\PerfOptions" 'CpuPriorityClass') -eq 3 }

function Set-GameBoost($g, $on) {
    $k = "$IFEO\$($g.Exe)\PerfOptions"
    $base = [IO.Path]::GetFileNameWithoutExtension($g.Exe)
    if ($on) {
        Write-RegRaw $k 'CpuPriorityClass' 3 'DWord'
        if ($g.Path) { Write-RegRaw $GpuPref $g.Path 'GpuPreference=2;' 'String' }
        foreach ($p in Get-Process -Name $base -ErrorAction SilentlyContinue) { try { $p.PriorityClass = 'High' } catch {} }
    } else {
        Remove-ItemProperty -LiteralPath $k -Name 'CpuPriorityClass' -ErrorAction SilentlyContinue
        if ($g.Path) { Remove-ItemProperty -LiteralPath $GpuPref -Name $g.Path -ErrorAction SilentlyContinue }
        foreach ($p in Get-Process -Name $base -ErrorAction SilentlyContinue) { try { $p.PriorityClass = 'Normal' } catch {} }
    }
    Write-Log "GAME $($g.Exe) = $on"
}

function Add-Game($name, $exe, $path) {
    if (-not $path) {
        $run = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
        if ($run) { $path = $run.Path }
    }
    $old = $script:Games | Where-Object { $_.Exe -ieq $exe } | Select-Object -First 1
    if ($old) {
        if ($path -and -not $old.Path) { $old.Path = $path; Save-Games; Set-GameBoost $old $true; Build-Games; Show-Toast "$name موجودة، وأضفت لها أولوية كرت الشاشة" }
        else { Show-Toast "$name موجودة بالقائمة من قبل" 'warn' }
        return
    }
    $g = @{ Name = $name; Exe = $exe; Path = $path }
    [void]$script:Games.Add($g); Save-Games
    Set-GameBoost $g $true
    Build-Games
    Show-Toast "انضافت $name وصارت بأولوية High ⚡"
}

function Remove-Game($g) {
    if (-not (Ask-YesNo "تبي تشيل $($g.Name) من القائمة وترجّع أولويتها عادية؟")) { return }
    Set-GameBoost $g $false
    [void]$script:Games.Remove($g); Save-Games; Build-Games
    Show-Toast "انشالت $($g.Name)"
}

function Add-FromFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'ملف تشغيل اللعبة (*.exe)|*.exe'
    $dlg.Title = 'اختر ملف تشغيل اللعبة'
    if ($dlg.ShowDialog($window)) {
        $p = $dlg.FileName
        Add-Game ([IO.Path]::GetFileNameWithoutExtension($p)) ([IO.Path]::GetFileName($p)) $p
    }
}

function Add-FromRunning {
    $skip = @('explorer', 'ApplicationFrameHost', 'TextInputHost', 'SystemSettings', 'powershell', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost')
    $procs = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -and $_.Id -ne $PID -and $_.ProcessName -notin $skip } | Sort-Object ProcessName -Unique)
    if ($procs.Count -eq 0) { Show-Toast 'ما فيه برامج مفتوحة. شغّل اللعبة أول' 'warn'; return }
    $lb = New-Object Windows.Controls.ListBox
    $lb.Background = Brush '#120420'; $lb.Foreground = Brush '#FBEFFF'; $lb.BorderBrush = Brush '#3A1A55'
    $lb.MaxHeight = 280; $lb.FlowDirection = 'LeftToRight'
    foreach ($p in $procs) {
        $it = New-Object Windows.Controls.ListBoxItem
        $t = if ($p.MainWindowTitle) { $p.MainWindowTitle } else { $p.ProcessName }
        $it.Content = "$t   ($($p.ProcessName).exe)"; $it.Tag = $p.Path; $it.Padding = T 10 7 10 7
        [void]$lb.Items.Add($it)
    }
    $r = Show-Dialog 'اختر اللعبة' 'شغّل اللعبة أول، وبعدها اخترها من هالقائمة. كذا نضمن إننا ناخذ ملف اللعبة الصح، مو ملف اللانشر.' @('أضف', 'إلغاء') 0 $false $lb
    if ($r -eq 'أضف' -and $lb.SelectedItem) {
        $path = [string]$lb.SelectedItem.Tag
        Add-Game ([IO.Path]::GetFileNameWithoutExtension($path)) ([IO.Path]::GetFileName($path)) $path
    }
}

$script:GamesStack = $null
function Build-Games {
    $st = $script:GamesStack; if (-not $st) { return }
    $st.Children.Clear()
    if ($script:Games.Count -eq 0) {
        $e = New-Object Windows.Controls.TextBlock
        $e.Text = 'ما أضفت ألعاب للحين. اختر من الألعاب الجاهزة فوق، أو أضف لعبتك.'
        $e.Foreground = Brush '#A88BC4'; $e.Margin = T 2 4 0 10
        [void]$st.Children.Add($e); return
    }
    foreach ($g in $script:Games) {
        $border = New-Card; $grid = New-TwoCol
        $badges = @()
        if (Test-GameBoosted $g) { $badges += New-Badge 'أولوية High' '#00E5FF' '#062A33' }
        if ($g.Path) { $badges += New-Badge 'كرت الشاشة: أداء عالي' '#FFD23F' '#33280A' }
        $desc = if ($g.Path) { $g.Path } else { $g.Exe }
        [void]$grid.Children.Add((New-CardBody $g.Name $desc $badges $true))
        $right = New-Object Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
        $del = New-ActionButton 'شيل' { param($x) Remove-Game $x } $false $g
        $del.Margin = T 18 0 0 0
        [void]$right.Children.Add($del)
        $sw = New-Switch $g
        $sw.IsChecked = Test-GameBoosted $g
        $sw.Add_Click({ $x = $this.Tag; $on = [bool]$this.IsChecked; Set-GameBoost $x $on; Build-Games; if ($on) { Show-Toast "$($x.Name): أولوية High" } else { Show-Toast "$($x.Name): أولوية عادية" } })
        [void]$right.Children.Add($sw)
        [Windows.Controls.Grid]::SetColumn($right, 1)
        [void]$grid.Children.Add($right)
        $border.Child = $grid
        [void]$st.Children.Add($border)
    }
}

# ---------- وضع اللعب ----------
$BoostStopScript = {
    foreach ($s in @('wuauserv', 'BITS', 'WSearch', 'SysMain', 'DoSvc', 'DiagTrack', 'MapsBroker', 'WerSvc')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 150
            if ((Get-Service -Name $s).Status -ne 'Running') { $s }
        }
    }
}
$script:BoostOn = $script:Backup.ContainsKey('boostStopped')
if ($script:BoostOn -and $script:NativeOk) { try { [void][GBNative]::SetTimer($true) } catch {} }
$script:BoostBtn = $null; $script:BoostState = $null

function Update-BoostUI {
    if (-not $script:BoostBtn) { return }
    if ($script:BoostOn) {
        $script:BoostBtn.Content = 'أوقف وضع اللعب'; $script:BoostBtn.Background = Brush '#E5484D'; $script:BoostBtn.Foreground = Brush '#FFFFFF'
        $script:BoostState.Text = '● شغال: خدمات الخلفية موقوفة والألعاب بأولوية High'; $script:BoostState.Foreground = Brush '#00E5FF'
    } else {
        $script:BoostBtn.Content = 'شغّل وضع اللعب'; $script:BoostBtn.Background = $AccentGrad; $script:BoostBtn.Foreground = Brush '#2A0A3A'
        $script:BoostState.Text = '○ طافي'; $script:BoostState.Foreground = Brush '#A88BC4'
    }
}

function Toggle-GameBoost {
    if (-not $script:BoostOn) {
        Set-Status 'جاري تشغيل وضع اللعب...'
        Start-Bg $BoostStopScript {
            param($r, $e)
            $names = @($r | ForEach-Object { [string]$_ })
            $script:Backup['boostStopped'] = $names; Save-Backup
            if ($script:NativeOk) { try { [void][GBNative]::PurgeStandby() } catch {}; try { [void][GBNative]::SetTimer($true) } catch {} }
            ipconfig /flushdns | Out-Null
            foreach ($g in $script:Games) {
                if (Test-GameBoosted $g) { foreach ($p in Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($g.Exe)) -ErrorAction SilentlyContinue) { try { $p.PriorityClass = 'High' } catch {} } }
            }
            $script:BoostOn = $true; Update-BoostUI
            Write-Log "BOOST ON: $($names -join ',')"
            Show-Toast "وضع اللعب شغال ⚡ أوقفت $($names.Count) خدمة وفرّغت الرام"
        }
    } else {
        $names = @($script:Backup['boostStopped'] | Where-Object { $_ })
        Set-Status 'جاري إيقاف وضع اللعب...'
        $sb = [scriptblock]::Create("foreach (`$s in @('" + ($names -join "','") + "')) { if (`$s) { Start-Service -Name `$s -ErrorAction SilentlyContinue } }")
        Start-Bg $sb {
            param($r, $e)
            $script:Backup.Remove('boostStopped'); Save-Backup
            if ($script:NativeOk) { try { [void][GBNative]::SetTimer($false) } catch {} }
            $script:BoostOn = $false; Update-BoostUI
            Write-Log 'BOOST OFF'
            Show-Toast 'وضع اللعب طافي، ورجعت خدمات ويندوز تشتغل'
        }
    }
}

function Build-BoostPage($st) {
    # بطاقة وضع اللعب
    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = New-Object Windows.CornerRadius(16); $border.Padding = T 22 18 22 18; $border.Margin = T 0 0 0 18
    $border.BorderBrush = Brush '#66FF2E88'; $border.BorderThickness = T 1 1 1 1
    $bg = New-Object Windows.Media.LinearGradientBrush((Brush '#2A0A40').Color, (Brush '#1A0629').Color, 0.0); $border.Background = $bg
    $grid = New-TwoCol
    $sp = New-Object Windows.Controls.StackPanel
    $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = 'وضع اللعب'; $t1.FontSize = 20; $t1.FontWeight = 'Bold'; $t1.FontStyle = 'Italic'
    $t2 = New-Object Windows.Controls.TextBlock; $t2.TextWrapping = 'Wrap'; $t2.Foreground = Brush '#C9B2E0'; $t2.Margin = T 0 6 0 8
    $t2.Text = 'شغّله قبل ما تلعب. يوقف مؤقتاً تحديثات ويندوز والفهرسة وخدمات الخلفية، ويفرّغ الرام، ويعطي ألعابك المفتوحة أولوية High، ويرفع دقة مؤقت النظام لـ 0.5ms عشان يقل الـ Input Lag. خل التطبيق مفتوح (مصغّر) وأنت تلعب عشان المؤقت يظل شغال، وبعد ما تخلص أوقفه وكل شيء يرجع مثل ما كان.'
    $script:BoostState = New-Object Windows.Controls.TextBlock; $script:BoostState.FontWeight = 'SemiBold'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($script:BoostState)
    [void]$grid.Children.Add($sp)
    $script:BoostBtn = New-ActionButton 'شغّل وضع اللعب' { Toggle-GameBoost } $true
    $script:BoostBtn.MinWidth = 150; $script:BoostBtn.Height = 44; $script:BoostBtn.FontSize = 14; $script:BoostBtn.Margin = T 18 0 0 0; $script:BoostBtn.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($script:BoostBtn, 1)
    [void]$grid.Children.Add($script:BoostBtn)
    $border.Child = $grid
    [void]$st.Children.Add($border)

    # ألعاب جاهزة
    $h = New-Object Windows.Controls.TextBlock; $h.Text = 'ألعاب جاهزة (اضغط على اللعبة عشان تضيفها)'; $h.FontSize = 15; $h.FontWeight = 'SemiBold'; $h.Margin = T 2 0 0 10
    [void]$st.Children.Add($h)
    $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = T 0 0 0 8
    foreach ($pr in $GamePresets) {
        $b = New-ActionButton $pr.N { param($x) Add-Game $x.N $x.E $null } $false $pr
        $b.Margin = T 0 0 8 8
        [void]$wp.Children.Add($b)
    }
    [void]$st.Children.Add($wp)

    # إضافة لعبة
    $row = New-Object Windows.Controls.WrapPanel; $row.Margin = T 0 4 0 16
    $b1 = New-ActionButton 'أضف من البرامج المفتوحة' { Add-FromRunning } $true; $b1.Margin = T 0 0 10 0
    $b2 = New-ActionButton 'أضف لعبة من جهازك (exe)' { Add-FromFile }; 
    [void]$row.Children.Add($b1); [void]$row.Children.Add($b2)
    [void]$st.Children.Add($row)

    $h2 = New-Object Windows.Controls.TextBlock; $h2.Text = 'ألعابك'; $h2.FontSize = 15; $h2.FontWeight = 'SemiBold'; $h2.Margin = T 2 0 0 10
    [void]$st.Children.Add($h2)
    $script:GamesStack = New-Object Windows.Controls.StackPanel
    [void]$st.Children.Add($script:GamesStack)
    Build-Games
    Update-BoostUI
}

# ---------- الصفحات ----------
$Pages = [ordered]@{
    home    = @{ T = 'الرئيسية';        I = 0xE80F }
    boost   = @{ T = 'بوست الألعاب';    I = 0xE768; S = 'ألعابك تاخذ أولوية المعالج وكرت الشاشة، وشغّل وضع اللعب قبل ما تبدأ.' }
    perf    = @{ T = 'الأداء والمعالج'; I = 0xE945; S = 'خطة الطاقة وأنوية المعالج والمؤقت.' }
    games   = @{ T = 'الألعاب';         I = 0xE7FC; S = 'أولوية الألعاب وكرت الشاشة وإعدادات اللعب.' }
    input   = @{ T = 'الماوس والكيبورد'; I = 0xE962; S = 'استجابة أسرع للماوس والكيبورد وحركة أنعم.' }
    net     = @{ T = 'الشبكة والبنق';   I = 0xE839; S = 'تعديلات كرت الشبكة واللي يستهلك النت بالخلفية.' }
    sys     = @{ T = 'النظام';          I = 0xE770; S = 'تخفيف ويندوز وإيقاف اللي يشتغل بالخلفية بدون فايدة.' }
    startup = @{ T = 'بدء التشغيل';     I = 0xE7E8; S = 'البرامج اللي تشتغل مع الويندوز. كل برنامج توقفه يخلي الجهاز يقلع أسرع ويفضّي رام.' }
    tools   = @{ T = 'أدوات';           I = 0xE90F; S = 'تنظيف وتفريغ رام واختبار بنق ونقطة استعادة.' }
}
$script:PageViews = @{ home = $HomePage }
$script:NavButtons = @{}

function New-PageShell($key, $title, $sub) {
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Visibility = 'Collapsed'
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = T 0 0 10 16
    $hdr = New-TwoCol; $hdr.Margin = T 0 0 0 20
    $hs = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.TextBlock; $h.Text = $title; $h.FontSize = 28; $h.FontWeight = 'Bold'; $h.FontStyle = 'Italic'
    $s = New-Object Windows.Controls.TextBlock; $s.Text = $sub; $s.Foreground = Brush '#A88BC4'; $s.Margin = T 0 4 0 0; $s.TextWrapping = 'Wrap'
    [void]$hs.Children.Add($h); [void]$hs.Children.Add($s)
    [void]$hdr.Children.Add($hs)
    $btn = $null
    if ($key -in @('perf', 'games', 'input', 'net', 'sys')) {
        $btn = New-ActionButton 'فعّل الموصى به' {
            param($cat)
            Set-Busy $true; $n = 0
            foreach ($t in ($Tweaks | Where-Object { $_.Cat -eq $cat -and $_.Rec })) {
                $script:AdCache = $null
                if (-not (Test-Tweak $t)) { Set-Status "جاري تطبيق: $($t.Title)..."; Invoke-Apply $t; $n++ }
            }
            Set-Busy $false; Refresh-All
            if ($n) { Show-Toast "تم تفعيل $n تحسين" } else { Show-Toast 'كل الموصى به مفعّل من قبل ✓' }
        } $true $key
    } elseif ($key -eq 'startup') {
        $btn = New-ActionButton 'تحديث القائمة' { Build-Startup } $false
    }
    if ($btn) { $btn.VerticalAlignment = 'Bottom'; $btn.Margin = T 16 0 0 0; [Windows.Controls.Grid]::SetColumn($btn, 1); [void]$hdr.Children.Add($btn) }
    [void]$sp.Children.Add($hdr)
    $sv.Content = $sp
    [void]$ContentHost.Children.Add($sv)
    return @{ View = $sv; Stack = $sp }
}

$script:StartupStack = $null
foreach ($k in $Pages.Keys) {
    if ($k -eq 'home') { continue }
    $pg = New-PageShell $k $Pages[$k].T $Pages[$k].S
    $script:PageViews[$k] = $pg.View
    switch ($k) {
        'tools' {
            $st = $pg.Stack.Children
            [void]$st.Add((New-ActionCard 'تفريغ الرام' 'يفضّي ذاكرة الـ Standby اللي ويندوز يحجزها. يفيد قبل اللعب إذا لاحظت تقطيع بعد ما تفتح برامج كثير.' 'فرّغ' { Clear-Ram } $true))
            [void]$st.Add((New-ActionCard 'اختبار البنق' 'يقيس البنق والتذبذب (Jitter) على 8.8.8.8 و1.1.1.1.' 'اختبر' { Test-Ping }))
            [void]$st.Add((New-ActionCard 'تنظيف الملفات المؤقتة' 'يحذف ملفات Temp وملفات تحديثات ويندوز القديمة وملفات الأعطال.' 'نظّف' { Clear-TempFiles }))
            [void]$st.Add((New-ActionCard 'مسح كاش DNS' 'يفيد إذا فيه مواقع ما تفتح أو تفتح ببطء.' 'امسح' { Clear-Dns }))
            [void]$st.Add((New-ActionCard 'نقطة استعادة للنظام' 'تحفظ نسخة من إعدادات ويندوز ترجع لها لو صار أي شيء.' 'أنشئ' { New-RestorePointUI }))
            [void]$st.Add((New-ActionCard 'تنظيف كاش الشيدر' 'يحذف كاش الشيدر لكرت الشاشة وDirectX. يفيد إذا صار تقطيع بعد تحديث التعريف.' 'نظّف' { Clear-ShaderCache }))
            [void]$st.Add((New-ActionCard 'إعادة تشغيل الشبكة' 'يعيد تشغيل كرت الشبكة ويمسح DNS. يفيد إذا البنق ارتفع فجأة أو النت علّق.' 'أعد التشغيل' { Reset-Network }))
            [void]$st.Add((New-ActionCard 'تحقق من التحديثات' 'يشوف إذا فيه نسخة جديدة من Zero Lag، وتحدّثها بضغطة.' 'تحقق' { Check-Update $false } $true))
            [void]$st.Add((New-ActionCard 'رابط التحديث' 'المكان اللي يجيب منه التطبيق التحديثات (مجلد GitHub).' 'عدّل' { Set-UpdateUrl }))
            [void]$st.Add((New-ActionCard 'التطبيق على سطح المكتب' 'ينشئ أيقونة على سطح المكتب وفي قائمة ابدأ، أو يحدّثها إذا موجودة.' 'ثبّت / حدّث' { Install-App }))
            [void]$st.Add((New-ActionCard 'إرجاع كل شيء' 'يطفي كل التعديلات ويرجع القيم الأصلية.' 'رجّع الكل' { Revert-All }))
            [void]$st.Add((New-ActionCard 'مجلد النسخ الاحتياطي' 'فيه ملف القيم الأصلية وسجل بكل تعديل انعمل.' 'افتح' { Start-Process explorer.exe $AppDir }))
            [void]$st.Add((New-ActionCard 'إعادة تشغيل الجهاز' 'بعض التعديلات ما تشتغل إلا بعد الريستارت.' 'ريستارت' { Restart-PC }))
        }
        'startup' { $script:StartupStack = $pg.Stack }
        'boost'   { Build-BoostPage $pg.Stack }
        default { foreach ($t in ($Tweaks | Where-Object { $_.Cat -eq $k })) { [void]$pg.Stack.Children.Add((New-TweakCard $t)) } }
    }
}

function Build-Startup {
    $st = $script:StartupStack
    while ($st.Children.Count -gt 1) { $st.Children.RemoveAt(1) }
    $items = Get-StartupItems
    if ($items.Count -eq 0) {
        $e = New-Object Windows.Controls.TextBlock; $e.Text = 'ما فيه برامج تشتغل مع الويندوز ✓'; $e.Foreground = Brush '#A88BC4'
        [void]$st.Children.Add($e); return
    }
    foreach ($it in $items) {
        $border = New-Card; $grid = New-TwoCol
        $cmd = $it.Cmd; if ($cmd.Length -gt 95) { $cmd = $cmd.Substring(0, 92) + '...' }
        [void]$grid.Children.Add((New-CardBody $it.Show $cmd @(New-Badge $it.Scope '#A88BC4' '#2A1240') $true))
        $sw = New-Switch $it
        $sw.IsChecked = Test-StartupEnabled $it
        $sw.Add_Click({
            $i = $this.Tag; $on = [bool]$this.IsChecked
            try { Set-StartupEnabled $i $on } catch { Show-Toast "ما قدرت أغيّره: $($_.Exception.Message)" 'err' }
            $this.IsChecked = Test-StartupEnabled $i
            if ($on) { Show-Toast "$($i.Show) بيشتغل مع الويندوز" } else { Show-Toast "$($i.Show) ما عاد يشتغل مع الويندوز" }
        })
        [void]$grid.Children.Add($sw)
        $border.Child = $grid
        [void]$st.Children.Add($border)
    }
    $script:StartupLoaded = $true
}

function Show-Page($id) {
    foreach ($k in $script:PageViews.Keys) { if ($k -ne $id) { $script:PageViews[$k].Visibility = 'Collapsed' } }
    $v = $script:PageViews[$id]
    $v.Visibility = 'Visible'; $v.ScrollToTop()
    $tt = New-Object Windows.Media.TranslateTransform(0, 14); $v.RenderTransform = $tt
    $v.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1 260 0))
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim 0 320 14))
    foreach ($k in $script:NavButtons.Keys) {
        $b = $script:NavButtons[$k]
        if ($k -eq $id) { $b.Background = Brush '#2A0E40'; $b.Foreground = Brush '#FFFFFF'; $b.BorderBrush = $AccentGrad }
        else { $b.Background = Brush '#00000000'; $b.Foreground = Brush '#B79CD6'; $b.BorderBrush = Brush '#00000000' }
    }
    $script:CurrentPage = $id
    if ($id -eq 'startup' -and -not $script:StartupLoaded) { Build-Startup }
}

foreach ($k in $Pages.Keys) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $window.FindResource('NavBtn'); $b.Tag = $k
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $ic = New-Object Windows.Controls.TextBlock
    $ic.Text = [string][char]$Pages[$k].I; $ic.FontFamily = $window.FindResource('IconFont'); $ic.FontSize = 15
    $ic.VerticalAlignment = 'Center'; $ic.Margin = T 0 0 12 0
    $lb = New-Object Windows.Controls.TextBlock; $lb.Text = $Pages[$k].T; $lb.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($ic); [void]$sp.Children.Add($lb)
    $b.Content = $sp
    $b.Add_Click({ Show-Page ([string]$this.Tag) })
    [void]$NavPanel.Children.Add($b)
    $script:NavButtons[$k] = $b
}

# ---------- أدوات سريعة ----------
foreach ($q in @(
    @{ T = 'تفريغ الرام';   A = { Clear-Ram } }
    @{ T = 'اختبار البنق';  A = { Test-Ping } }
    @{ T = 'تنظيف المؤقتة'; A = { Clear-TempFiles } }
    @{ T = 'مسح DNS';       A = { Clear-Dns } }
    @{ T = 'ريستارت';       A = { Restart-PC } }
)) {
    $qb = New-ActionButton $q.T $q.A
    $qb.Margin = T 0 0 10 10; $qb.MinWidth = 110
    [void]$QuickPanel.Children.Add($qb)
}

# ---------- معلومات الجهاز ----------
try {
    $CpuName.Text = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $GpuName.Text = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Parsec|Remote' } | Select-Object -ExpandProperty Name) -join '  /  '
} catch {}
if ($script:NativeOk) { $m = [GBNative]::Mem(); $RamName.Text = "$([math]::Round($m[0])) GB" }

function Set-Bar($fill, $hostEl, [double]$pct) {
    $w = [math]::Max(0, $hostEl.ActualWidth * [math]::Min(100, $pct) / 100)
    $fill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-Anim $w 600))
}

$script:StatsTimer = New-Object Windows.Threading.DispatcherTimer
$script:StatsTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:StatsTimer.Add_Tick({
    if (-not $script:NativeOk -or $script:CurrentPage -ne 'home' -or $window.WindowState -eq 'Minimized') { return }
    $c = [GBNative]::Cpu(); $m = [GBNative]::Mem()
    $CpuUse.Text = "الاستهلاك: $c%"; Set-Bar $CpuBarFill $CpuBarHost $c
    $RamUse.Text = "المستخدم: $([math]::Round($m[1], 1)) من $([math]::Round($m[0])) GB"; Set-Bar $RamBarFill $RamBarHost $m[2]
})

# ---------- أزرار النافذة ----------
foreach ($cb in @($MinBtn, $MaxBtn, $CloseBtn)) { [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($cb, $true) }
$MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$MaxBtn.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$CloseBtn.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Maximized') { $RootBorder.Margin = T 7 7 7 7; $MaxBtn.Content = [string][char]0xE923 }
    else { $RootBorder.Margin = T 0 0 0 0; $MaxBtn.Content = [string][char]0xE922 }
})
$window.Add_SourceInitialized({
    if ($script:NativeOk) { try { [GBNative]::StyleWindow((New-Object Windows.Interop.WindowInteropHelper($window)).Handle) } catch {} }
})

$OptimizeBtn.Add_Click({ Start-Optimize })
$InstallBtn.Add_Click({ Install-App })
$UpdateBtn.Add_Click({ Install-Update })

# ---------- مشهد الغروب: نجوم وأرضية نيون متحركة ----------
function Draw-Floor {
    $c = $FloorCanvas; $c.Children.Clear()
    $w = $c.ActualWidth; $h = $c.ActualHeight
    if ($w -lt 20 -or $h -lt 10) { return }
    $pink = Brush '#FF2E88'; $vx = $w / 2
    for ($i = -16; $i -le 16; $i++) {
        $l = New-Object Windows.Shapes.Line
        $l.X1 = $vx + $i * 8; $l.Y1 = 0; $l.X2 = $vx + $i * ($w / 10); $l.Y2 = $h
        $l.Stroke = $pink; $l.StrokeThickness = 1.2
        [void]$c.Children.Add($l)
    }
    $grp = New-Object Windows.Controls.Canvas
    $sp = 15
    for ($k = -1; $k -le [math]::Ceiling($h / $sp) + 1; $k++) {
        $l = New-Object Windows.Shapes.Line
        $l.X1 = 0; $l.X2 = $w; $l.Y1 = $k * $sp; $l.Y2 = $k * $sp
        $l.Stroke = $pink; $l.StrokeThickness = 1.2
        [void]$grp.Children.Add($l)
    }
    $tt = New-Object Windows.Media.TranslateTransform
    $grp.RenderTransform = $tt
    [void]$c.Children.Add($grp)
    $a = New-Object Windows.Media.Animation.DoubleAnimation(0, $sp, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(900))))
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 30)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a)
}

function Draw-Stars {
    $c = $StarCanvas; $c.Children.Clear()
    $w = $c.ActualWidth; $h = $c.ActualHeight
    if ($w -lt 20) { return }
    $rnd = New-Object System.Random(7)
    for ($i = 0; $i -lt 34; $i++) {
        $e = New-Object Windows.Shapes.Ellipse
        $d = 1 + $rnd.NextDouble() * 1.8
        $e.Width = $d; $e.Height = $d
        $e.Fill = if ($i % 7 -eq 0) { Brush '#00E5FF' } elseif ($i % 5 -eq 0) { Brush '#FFD23F' } else { Brush '#FFFFFF' }
        $e.Opacity = 0.35 + $rnd.NextDouble() * 0.6
        [Windows.Controls.Canvas]::SetLeft($e, $rnd.NextDouble() * $w)
        [Windows.Controls.Canvas]::SetTop($e, $rnd.NextDouble() * ($h * 0.85))
        if ($i % 3 -eq 0) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation(0.15, 1, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(1200 + $rnd.Next(2000)))))
            $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $a.BeginTime = [TimeSpan]::FromMilliseconds($rnd.Next(1500))
            [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 20)
            $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
        }
        [void]$c.Children.Add($e)
    }
}

$Hero.Add_SizeChanged({
    $Hero.Clip = New-Object Windows.Media.RectangleGeometry((New-Object Windows.Rect(0, 0, $Hero.ActualWidth, $Hero.ActualHeight)), 18, 18)
})
$FloorCanvas.Add_SizeChanged({ Draw-Floor })
$StarCanvas.Add_SizeChanged({ Draw-Stars })

$window.Add_ContentRendered({
    Refresh-All
    if (-not (Test-Installed)) { $InstallBanner.Visibility = 'Visible' }
    if (Get-UpdateBase) { Check-Update $true }
    $script:StatsTimer.Start()
})

$window.Add_Closing({
    param($s, $e)
    if ($script:NeedRestart -and -not $script:AskedRestart) {
        $script:AskedRestart = $true
        if (Ask-YesNo 'فيه تعديلات تحتاج إعادة تشغيل عشان تشتغل. تعيد التشغيل الحين؟' $false 'قبل لا تطلع') { Restart-Computer -Force }
    }
})

try { $window.Icon = New-IconBitmap 64 } catch {}
$VersionText.Text = "v$AppVersion  •  وضع الأداء"
Show-Page 'home'
Write-Log 'APP STARTED'
[void]$window.ShowDialog()

<#
.SYNOPSIS
    Reports or repairs wrong display scaling caused by stale or corrupt display data

.DESCRIPTION
    Windows keeps display state that can outlive the conditions it was recorded
    under: a cached internal panel EDID, per-display scale choices keyed by
    display target, the NVIDIA hybrid graphics DPI value, and the legacy DPI
    values under HKCU\Control Panel\Desktop. When that state no longer matches
    the connected display, Windows can apply a scale that belongs to other
    display data, so everything on screen looks too large or too small even at
    the correct resolution. This state also survives a clean driver reinstall,
    including one performed with Display Driver Uninstaller (DDU), and the
    Custom Scaling page under Settings > System > Display can still report the
    expected scale as "Unmodified default" while the applied scale is wrong,
    which makes the cause hard to identify from the usual troubleshooting
    steps.

    Moving the installation to another SSD or disk, or restoring an image onto
    different hardware, is a common way to end up with that mismatch, because
    the display state travels with the installation while the panel and its
    saved scale do not. It is not the only way. A GPU driver update, rollback,
    or reinstall; a panel, cable, or motherboard replacement; a Windows upgrade
    that migrates DPI settings; a vendor display utility or GPU control panel
    change; switching between docked and undocked configurations; an
    interrupted shutdown while display settings were being written; or a
    manually edited display value can leave the same stale state behind.

    The script does not depend on how the state became stale. It reports the
    display state it finds, plans the changes that would clear it, and applies
    them only when asked.

    Without -Apply the script only reports. -Apply needs an elevated session and
    a reboot afterwards. Every registry key is exported before anything is
    removed, and -Restore imports the exports again.

.PARAMETER Apply
    Perform the changes. Without it the script only reports.

.PARAMETER Force
    Do not ask for confirmation.

.PARAMETER BackupPath
    Folder for registry exports and the report.
    Default: Desktop\DisplayScaleRepair_<timestamp>.

.PARAMETER PreserveExternalMonitorSettings
    Remove only scale entries that belong to the active panel instead of
    removing the whole per-display scale stores.

.PARAMETER ResetLegacyDpiValues
    Also set LogPixels to 96, Win8DpiScaling to 0 and remove
    DesktopDPIOverride.

.PARAMETER SkipMonitorReenumerate
    Do not remove and rescan the active panel's monitor device node.

.PARAMETER SkipNvidiaPersistenceReset
    Leave the NVIDIA hybrid graphics scale value untouched.

.PARAMETER NvidiaScalePercent
    Write this value instead of removing the NVIDIA value. Range 100-500.

.PARAMETER MonitorInstanceId
    Use these monitor device instance IDs as the active panel instead of
    discovering them.

.PARAMETER Restore
    Import the .reg files found in BackupPath and stop.

.PARAMETER Reboot
    Restart the computer after the changes.

.PARAMETER DeepScan
    Also scan the display registry for EDID-shaped values and for value names
    that contain dpi or scale.

.PARAMETER ReportPath
    Path for the JSON report when the script runs without -Apply.

.EXAMPLE
    .\Repair-DisplayScalingAfterTransplant.ps1

.EXAMPLE
    .\Repair-DisplayScalingAfterTransplant.ps1 -Apply -Force

.EXAMPLE
    .\Repair-DisplayScalingAfterTransplant.ps1 -Apply -ResetLegacyDpiValues -DeepScan

.EXAMPLE
    .\Repair-DisplayScalingAfterTransplant.ps1 -Restore -BackupPath .\DisplayScaleRepair_20260101-120000

.NOTES
    Useful after an SSD or disk move, a driver change, a panel replacement, or
    any other change that leaves stale display state behind.

    Tested on Windows 11 build 26300 on a laptop with an AMD iGPU and an NVIDIA
    GPU. Use at your own risk.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Force,
    [string]$BackupPath,
    [switch]$PreserveExternalMonitorSettings,
    [switch]$ResetLegacyDpiValues,
    [switch]$SkipMonitorReenumerate,
    [switch]$SkipNvidiaPersistenceReset,
    [Nullable[int]]$NvidiaScalePercent,
    [string[]]$MonitorInstanceId,
    [switch]$Restore,
    [switch]$Reboot,
    [switch]$DeepScan,
    [string]$ReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Warnings = New-Object System.Collections.ArrayList
$script:Errors = New-Object System.Collections.ArrayList
$script:Actions = New-Object System.Collections.ArrayList
$script:BackupFailures = 0

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ('   ' + $Text) -ForegroundColor $Color
}

function Add-Warning {
    param([string]$Text)
    [void]$script:Warnings.Add($Text)
    Write-Line ('Warn: ' + $Text) 'Yellow'
}

function Add-Error {
    param([string]$Text)
    [void]$script:Errors.Add($Text)
    Write-Line ('Error: ' + $Text) 'Red'
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-RegPath {
    param([string]$Path)
    $value = $Path
    # reg.exe does not accept the provider prefix that a PowerShell registry
    # path carries, so remove that exact prefix when it starts the path.
    $providerPrefix = 'Microsoft.PowerShell.Core\Registry::'
    $shortPrefix = 'Registry::'
    if ($value.StartsWith($providerPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring($providerPrefix.Length)
    }
    elseif ($value.StartsWith($shortPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring($shortPrefix.Length)
    }
    if ($value.StartsWith('HKLM:', [System.StringComparison]::OrdinalIgnoreCase)) { $value = 'HKLM' + $value.Substring(5) }
    elseif ($value.StartsWith('HKCU:', [System.StringComparison]::OrdinalIgnoreCase)) { $value = 'HKCU' + $value.Substring(5) }
    return $value
}

function Backup-RegistryKey {
    param([string]$Path, [string]$FileName, [string]$Folder)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Folder)) {
        try { New-Item -ItemType Directory -Path $Folder | Out-Null }
        catch {
            Add-Warning ('Backup failed for ' + $Path + ': ' + $_.Exception.Message)
            $script:BackupFailures = $script:BackupFailures + 1
            return $null
        }
    }
    $target = Join-Path $Folder $FileName
    try {
        & reg.exe export (ConvertTo-RegPath $Path) $target /y 2>&1 | Out-Null
    }
    catch {
        Add-Warning ('Backup failed for ' + $Path + ': ' + $_.Exception.Message)
        $script:BackupFailures = $script:BackupFailures + 1
        return $null
    }
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $target)) {
        [void]$script:Actions.Add('Backup: ' + $target)
        return $target
    }
    Add-Warning ('Backup failed for ' + $Path)
    $script:BackupFailures = $script:BackupFailures + 1
    return $null
}

function Remove-RegistryKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    catch {
        Add-Error ('Could not remove ' + $Path + ': ' + $_.Exception.Message)
        return $false
    }
    [void]$script:Actions.Add('Removed key: ' + $Path)
    return $true
}

function Remove-DpiScaleEntry {
    param([string]$Store, [string]$Name)
    if ($Store -eq 'User') { $path = 'HKCU:\Control Panel\Desktop\PerMonitorSettings\' + $Name }
    else { $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ScaleFactors\' + $Name }
    if (Test-Path -LiteralPath $path) {
        try {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
        catch {
            Add-Error ('Could not remove ' + $path + ': ' + $_.Exception.Message)
            return $false
        }
        [void]$script:Actions.Add('Removed scale entry: ' + $path)
        return $true
    }
    return $false
}

# The scale probe sets per-monitor awareness so the DPI numbers are not scaled
# by the process's own DPI context. The topology probe reads the target device
# name with a size scan because the structure size changes across Windows
# builds.
$source = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DisplayRepair
{
public static class DisplayScaleProbe
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }

    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDpiAwarenessContext();

    [DllImport("user32.dll")]
    private static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    public static List<string> Run()
    {
        List<string> lines = new List<string>();
        bool aware = false;
        int error = 0;
        try
        {
            aware = SetProcessDpiAwarenessContext(new IntPtr(-4));
            error = Marshal.GetLastWin32Error();
        }
        catch { }
        int level = -1;
        try { level = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()); } catch { }
        lines.Add("AWARE|" + aware + "|" + error + "|" + level);
        try
        {
            MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data)
            {
                MONITORINFOEX info = new MONITORINFOEX();
                info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (!GetMonitorInfo(monitor, ref info)) { return true; }
                uint dpiX = 0; uint dpiY = 0;
                int result = GetDpiForMonitor(monitor, 0, out dpiX, out dpiY);
                int width = info.Monitor.Right - info.Monitor.Left;
                int height = info.Monitor.Bottom - info.Monitor.Top;
                string device = info.Device == null ? "" : info.Device.Replace("|", "/");
                lines.Add("MONITOR|" + device + "|" + dpiX + "|" + dpiY + "|" + (dpiX * 100 / 96) + "|" + width + "x" + height + "|" + ((info.Flags & 1) != 0 ? "1" : "0") + "|" + result);
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        }
        catch { }
        try { lines.Add("SYSTEMDPI|" + GetDpiForSystem()); } catch { }
        return lines;
    }
}

public static class DisplayTopologyProbe
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SOURCEINFO
    {
        public LUID Adapter;
        public uint Id;
        public uint Mode;
        public uint Status;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TARGETINFO
    {
        public LUID Adapter;
        public uint Id;
        public uint Mode;
        public uint Technology;
        public uint Rotation;
        public uint Scaling;
        public uint RefreshNumerator;
        public uint RefreshDenominator;
        public uint ScanLine;
        public int Available;
        public uint Status;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PATHINFO
    {
        public SOURCEINFO Source;
        public TARGETINFO Target;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PATHINFO[] paths, ref uint modeCount, IntPtr modes, IntPtr topology);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int DisplayConfigGetDeviceInfo(IntPtr info);

    public static List<string> Run()
    {
        List<string> lines = new List<string>();
        uint pathCount = 0;
        uint modeCount = 0;
        int result = GetDisplayConfigBufferSizes(2, out pathCount, out modeCount);
        if (result != 0) { lines.Add("ERROR|sizes|" + result); return lines; }
        PATHINFO[] paths = new PATHINFO[pathCount];
        IntPtr modes = Marshal.AllocHGlobal((int)modeCount * 64);
        try
        {
            result = QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            if (result != 0) { lines.Add("ERROR|query|" + result); return lines; }
            for (uint i = 0; i < pathCount; i++)
            {
                PATHINFO path = paths[i];
                string name = "";
                string device = "";
                int mfg = 0;
                int product = 0;
                int size = 0;
                int error = 0;
                if (path.Target.Available != 0)
                {
                    TryReadName(path.Target.Adapter.Low, path.Target.Adapter.High, path.Target.Id, out name, out device, out mfg, out product, out size, out error);
                }
                lines.Add("PATH|" + path.Source.Adapter.High + "|" + path.Source.Adapter.Low + "|" + path.Source.Id + "|" + path.Target.Adapter.High + "|" + path.Target.Adapter.Low + "|" + path.Target.Id + "|" + path.Target.Technology + "|" + path.Target.Available + "|" + path.Flags + "|" + Base64(name) + "|" + Base64(device) + "|" + mfg + "|" + product + "|" + size + "|" + error);
            }
        }
        finally { Marshal.FreeHGlobal(modes); }
        return lines;
    }

    private static string Base64(string value)
    {
        return Convert.ToBase64String(Encoding.Unicode.GetBytes(value == null ? "" : value));
    }

    private static void TryReadName(uint low, int high, uint id, out string name, out string device, out int mfg, out int product, out int size, out int error)
    {
        name = "";
        device = "";
        mfg = 0;
        product = 0;
        size = 0;
        error = 0;
        IntPtr buffer = Marshal.AllocHGlobal(1024);
        try
        {
            int[] sizes = new int[] { 420, 424, 428, 432, 436, 440, 444, 448 };
            foreach (int candidate in sizes)
            {
                for (int i = 0; i < 1024; i++) Marshal.WriteByte(buffer, i, 0);
                Marshal.WriteInt32(buffer, 0, 2);
                Marshal.WriteInt32(buffer, 4, candidate);
                Marshal.WriteInt32(buffer, 8, (int)low);
                Marshal.WriteInt32(buffer, 12, high);
                Marshal.WriteInt32(buffer, 16, (int)id);
                int result = DisplayConfigGetDeviceInfo(buffer);
                error = result;
                if (result == 0)
                {
                    long start = buffer.ToInt64();
                    name = Marshal.PtrToStringUni(new IntPtr(start + 36), 64);
                    device = Marshal.PtrToStringUni(new IntPtr(start + 36 + 128), 128);
                    ushort rawMfg = (ushort)Marshal.ReadInt16(buffer, 28);
                    // The structure holds the manufacturer id bytes in the opposite
                    // order to the registry EDID, so reverse them here.
                    mfg = (int)(ushort)((rawMfg >> 8) | (rawMfg << 8));
                    product = (int)(ushort)Marshal.ReadInt16(buffer, 30);
                    size = candidate;
                    return;
                }
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
}
"@

# A second run in the same session would fail to compile the same types again,
# so the compile is skipped when both types are already loaded. The namespace
# carries a version; a change to the probe code needs a new namespace name,
# because a session that ran the older script keeps the older type loaded.
$scaleProbeType = ([System.Management.Automation.PSTypeName]'DisplayRepair.DisplayScaleProbe').Type
$topologyProbeType = ([System.Management.Automation.PSTypeName]'DisplayRepair.DisplayTopologyProbe').Type
if ($null -eq $scaleProbeType -or $null -eq $topologyProbeType) {
    Add-Type -TypeDefinition $source
}

function ConvertFrom-EdidBytes {
    param($Bytes)
    $info = [ordered]@{
        Valid = $false
        Length = 0
        Mfg = ''
        Product = 0
        Identity = ''
        Week = 0
        Year = 0
        WidthCm = 0
        HeightCm = 0
        DiagonalInches = 0.0
        Ppi = 0.0
        WidthPx = 0
        HeightPx = 0
        Extensions = 0
        ChecksumOk = $false
    }
    if ($null -eq $Bytes) { return [pscustomobject]$info }
    # A value stored under an EDID name with the wrong registry type is treated
    # as no EDID so a malformed value cannot stop the report.
    if (-not ($Bytes -is [byte[]])) { return [pscustomobject]$info }
    $info.Length = $Bytes.Length
    if ($Bytes.Length -lt 128) { return [pscustomobject]$info }
    if (-not ($Bytes[0] -eq 0 -and $Bytes[1] -eq 255 -and $Bytes[2] -eq 255 -and $Bytes[3] -eq 255 -and $Bytes[4] -eq 255 -and $Bytes[5] -eq 255 -and $Bytes[6] -eq 255 -and $Bytes[7] -eq 0)) {
        return [pscustomobject]$info
    }
    $sum = 0
    for ($i = 0; $i -lt 128; $i++) { $sum = ($sum + [int]$Bytes[$i]) -band 0xFF }
    $info.ChecksumOk = ($sum -eq 0)
    $mfgNumber = ([int]$Bytes[8] -shl 8) -bor [int]$Bytes[9]
    $first = [char](64 + (($mfgNumber -shr 10) -band 31))
    $second = [char](64 + (($mfgNumber -shr 5) -band 31))
    $third = [char](64 + ($mfgNumber -band 31))
    $info.Mfg = [string]::Concat($first, $second, $third)
    $info.Product = [int]$Bytes[10] -bor ([int]$Bytes[11] -shl 8)
    $info.Identity = $info.Mfg + ('{0:X4}' -f $info.Product)
    $info.Week = [int]$Bytes[16]
    $info.Year = 1990 + [int]$Bytes[17]
    $info.WidthCm = [int]$Bytes[21]
    $info.HeightCm = [int]$Bytes[22]
    if ($info.WidthCm -gt 0 -and $info.HeightCm -gt 0) {
        $info.DiagonalInches = [math]::Round([math]::Sqrt($info.WidthCm * $info.WidthCm + $info.HeightCm * $info.HeightCm) / 2.54, 1)
    }
    $info.WidthPx = [int]$Bytes[56] -bor ((([int]$Bytes[58]) -band 0xF0) -shl 4)
    $info.HeightPx = [int]$Bytes[59] -bor ((([int]$Bytes[61]) -band 0xF0) -shl 4)
    if ($info.DiagonalInches -gt 0 -and $info.WidthPx -gt 0 -and $info.HeightPx -gt 0) {
        $info.Ppi = [math]::Round([math]::Sqrt($info.WidthPx * $info.WidthPx + $info.HeightPx * $info.HeightPx) / $info.DiagonalInches, 0)
    }
    $info.Extensions = [int]$Bytes[126]
    $info.Valid = $true
    return [pscustomobject]$info
}

function Get-EffectiveScale {
    param([switch]$Quiet)
    $lines = @([DisplayRepair.DisplayScaleProbe]::Run())
    $monitors = New-Object System.Collections.ArrayList
    $systemDpi = 0
    $awareness = -1
    foreach ($line in $lines) {
        $parts = $line.Split('|')
        switch ($parts[0]) {
            'AWARE' { $awareness = [int]$parts[3] }
            'MONITOR' {
                [void]$monitors.Add([pscustomobject]@{
                    Device = $parts[1]
                    DpiX = [uint32]$parts[2]
                    DpiY = [uint32]$parts[3]
                    Percent = [int]$parts[4]
                    Bounds = $parts[5]
                    Primary = ($parts[6] -eq '1')
                    Result = [int]$parts[7]
                })
            }
            'SYSTEMDPI' { $systemDpi = [uint32]$parts[1] }
        }
    }
    $result = $monitors.ToArray()
    if (-not $Quiet) {
        foreach ($monitor in @($result)) {
            if ($monitor.Result -ne 0) {
                Add-Warning ('The DPI query failed for ' + $monitor.Device + ' (result ' + $monitor.Result + '), so the scale for that display is not known.')
            }
        }
    }
    return [pscustomobject]@{ Monitors = $result; SystemDpi = $systemDpi; Awareness = $awareness }
}

function Wait-DisplayReady {
    param([int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastView = $null
    while ($true) {
        Start-Sleep -Milliseconds 500
        $scale = Get-EffectiveScale -Quiet
        $healthy = @($scale.Monitors | Where-Object { $_.Result -eq 0 })
        # A rescan needs a moment, so one healthy sample is not enough: the
        # same display set must come back twice before the state is read.
        $view = (@($scale.Monitors | ForEach-Object { $_.Device + '|' + $_.Result + '|' + $_.DpiX } | Sort-Object) -join ';')
        if ($healthy.Count -gt 0 -and $view -eq $lastView) { return $scale }
        $lastView = $view
        if ((Get-Date) -ge $deadline) { return $scale }
    }
}

function Get-DisplayPaths {
    param([switch]$Quiet)
    $lines = @([DisplayRepair.DisplayTopologyProbe]::Run())
    $paths = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $parts = $line.Split('|')
        if ($parts[0] -eq 'ERROR') {
            if (-not $Quiet) { Add-Warning ('The display topology query returned an error: ' + $line) }
            continue
        }
        if ($parts[0] -ne 'PATH') { continue }
        $name = ''
        $device = ''
        if ($parts[10].Length -gt 0) { $name = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($parts[10])) }
        if ($parts[11].Length -gt 0) { $device = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($parts[11])) }
        [void]$paths.Add([pscustomobject]@{
            SourceAdapterHigh = [int]$parts[1]
            SourceAdapterLow = [uint32]$parts[2]
            SourceId = [uint32]$parts[3]
            TargetAdapterHigh = [int]$parts[4]
            TargetAdapterLow = [uint32]$parts[5]
            TargetId = [uint32]$parts[6]
            Technology = [uint32]$parts[7]
            Available = [int]$parts[8]
            Flags = [uint32]$parts[9]
            Name = $name
            DevicePath = $device
            EdidMfg = [int]$parts[12]
            EdidProduct = [int]$parts[13]
            StructSize = [int]$parts[14]
            ProbeResult = [int]$parts[15]
        })
    }
    return $paths.ToArray()
}

function Get-MonitorRecord {
    $records = New-Object System.Collections.ArrayList
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    if (-not (Test-Path -LiteralPath $root)) { return $records.ToArray() }
    $present = @{}
    $pnpDevices = @()
    $presentRead = $false
    try {
        $pnpDevices = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
        $presentRead = $true
    }
    catch { Add-Warning ('The monitor device list could not be read: ' + $_.Exception.Message) }
    foreach ($device in $pnpDevices) {
        if ($null -ne $device -and -not [string]::IsNullOrEmpty($device.InstanceId)) {
            $present[$device.InstanceId] = $device
        }
    }
    foreach ($monitorKey in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $monitorId = $monitorKey.PSChildName
        foreach ($instanceKey in @(Get-ChildItem -LiteralPath $monitorKey.PSPath -ErrorAction SilentlyContinue)) {
            $instanceName = $instanceKey.PSChildName
            $instanceId = 'DISPLAY\' + $monitorId + '\' + $instanceName
            $parameterPath = Join-Path $instanceKey.PSPath 'Device Parameters'
            $edidBytes = $null
            $overrideBytes = $null
            if (Test-Path -LiteralPath $parameterPath) {
                $values = Get-ItemProperty -LiteralPath $parameterPath -ErrorAction SilentlyContinue
                if ($null -ne $values -and $null -ne $values.PSObject.Properties['EDID']) { $edidBytes = $values.EDID }
                if ($null -ne $values -and $null -ne $values.PSObject.Properties['EDID_OVERRIDE']) { $overrideBytes = $values.EDID_OVERRIDE }
            }
            $edid = ConvertFrom-EdidBytes -Bytes $edidBytes
            $override = $null
            if ($null -ne $overrideBytes) { $override = ConvertFrom-EdidBytes -Bytes $overrideBytes }
            $device = $null
            if ($present.ContainsKey($instanceId)) { $device = $present[$instanceId] }
            $status = 'Unknown'
            if ($presentRead) { $status = 'Not present' }
            $friendlyName = ''
            $containerId = ''
            if ($null -ne $device) {
                $status = $device.Status
                $friendlyName = $device.FriendlyName
            }
            $instanceValues = Get-ItemProperty -LiteralPath $instanceKey.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $instanceValues -and $null -ne $instanceValues.PSObject.Properties['ContainerID']) { $containerId = $instanceValues.ContainerID }
            [void]$records.Add([pscustomobject]@{
                MonitorId = $monitorId
                InstanceName = $instanceName
                InstanceId = $instanceId
                Status = $status
                FriendlyName = $friendlyName
                ContainerId = $containerId
                Edid = $edid
                Override = $override
                EnumPath = $instanceKey.PSPath
            })
        }
    }
    return $records.ToArray()
}

function Resolve-Panel {
    param($Paths, $Records, $InternalEdid, [string[]]$OverrideIds)
    $activeIds = New-Object System.Collections.ArrayList
    foreach ($path in @($Paths)) {
        if ($path.DevicePath -match 'DISPLAY#(?<hardware>[^#]+)#(?<instance>[^#]+)#') {
            [void]$activeIds.Add('DISPLAY\' + $Matches['hardware'] + '\' + $Matches['instance'])
        }
    }
    $overrideActive = ($null -ne $OverrideIds -and $OverrideIds.Count -gt 0)
    $matched = @()
    $selection = 'none'
    if ($overrideActive) {
        $selection = 'override'
        $matched = @($Records | Where-Object { $OverrideIds -contains $_.InstanceId })
        if ($matched.Count -eq 0) {
            Add-Warning ('No monitor device matches -MonitorInstanceId: ' + ($OverrideIds -join ', '))
        }
    }
    else {
        $cacheIds = New-Object System.Collections.ArrayList
        foreach ($entry in @($InternalEdid)) {
            if ($null -ne $entry -and $entry.Edid.Valid) { [void]$cacheIds.Add($entry.Edid.Identity) }
        }
        if ($cacheIds.Count -gt 0) {
            # The cache only tells active displays apart. A stale entry must never
            # select a monitor that is no longer active.
            $matched = @($Records | Where-Object { $cacheIds -contains $_.Edid.Identity -and $activeIds -contains $_.InstanceId })
            if ($matched.Count -gt 0) { $selection = 'cache' }
        }
        if ($matched.Count -eq 0) {
            $internalRecords = New-Object System.Collections.ArrayList
            try {
                foreach ($entry in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop)) {
                    $instance = $entry.InstanceName -replace '_0$', ''
                    $technology = [uint32]$entry.VideoOutputTechnology
                    if ($technology -eq [uint32]2147483648 -or $technology -eq 11) {
                        foreach ($record in @($Records | Where-Object { $_.InstanceId -eq $instance })) { [void]$internalRecords.Add($record) }
                    }
                }
            }
            catch { Add-Warning ('The monitor connection query failed: ' + $_.Exception.Message) }
            if ($internalRecords.Count -gt 0) {
                $internalIdentities = @($internalRecords | Where-Object { $_.Edid.Valid } | ForEach-Object { $_.Edid.Identity })
                $samePanel = @($Records | Where-Object { $internalIdentities -contains $_.Edid.Identity -and $activeIds -contains $_.InstanceId })
                if ($samePanel.Count -gt 0) {
                    $matched = $samePanel
                    $selection = 'wmi-identity'
                }
                else {
                    $matched = @($internalRecords)
                    $selection = 'wmi-internal'
                }
            }
        }
        if ($matched.Count -eq 0) {
            $matched = @($Records | Where-Object { $activeIds -contains $_.InstanceId })
            if ($matched.Count -gt 0) { $selection = 'active-path' }
        }
    }
    $identity = $null
    $validRecords = @($matched | Where-Object { $_.Edid.Valid })
    if ($validRecords.Count -gt 0) { $identity = $validRecords[0].Edid.Identity }
    $activeRecords = @($Records | Where-Object { $activeIds -contains $_.InstanceId })
    return [pscustomobject]@{
        Records = $matched
        Identity = $identity
        InstanceIds = @($matched | ForEach-Object { $_.InstanceId })
        Selection = $selection
        ActiveRecordCount = $activeRecords.Count
    }
}

function Get-ScaleEntry {
    $entries = New-Object System.Collections.ArrayList
    $stores = @(
        @{ Path = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'; Store = 'User' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ScaleFactors'; Store = 'Machine' }
    )
    foreach ($store in $stores) {
        if (-not (Test-Path -LiteralPath $store.Path)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $store.Path -ErrorAction SilentlyContinue)) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $dpiValue = $null
            if ($null -ne $values -and $null -ne $values.PSObject.Properties['DpiValue']) { $dpiValue = $values.DpiValue }
            [void]$entries.Add([pscustomobject]@{ Store = $store.Store; Name = $key.PSChildName; DpiValue = $dpiValue })
        }
    }
    return $entries.ToArray()
}

function Get-InternalPanelEdid {
    $entries = New-Object System.Collections.ArrayList
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\InternalMonEdid'
    if (-not (Test-Path -LiteralPath $root)) { return $entries.ToArray() }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        $bytes = $null
        if ($null -ne $values -and $null -ne $values.PSObject.Properties['EDID']) { $bytes = $values.EDID }
        [void]$entries.Add([pscustomobject]@{ Name = $key.PSChildName; Edid = (ConvertFrom-EdidBytes -Bytes $bytes) })
    }
    return $entries.ToArray()
}

function Get-NvidiaDpiValue {
    $entries = New-Object System.Collections.ArrayList
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\Global\NvHybrid\Persistence'
    if (-not (Test-Path -LiteralPath $root)) { return $entries.ToArray() }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue)) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $values) { continue }
        foreach ($property in @($values.PSObject.Properties)) {
            if ($property.Name -eq 'DpiScalePercent') {
                [void]$entries.Add([pscustomobject]@{ KeyPath = $key.PSPath; KeyName = $key.Name; Value = $property.Value })
            }
        }
    }
    # The value can sit on the Persistence key itself or on a key below it.
    $rootValues = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $rootValues -and $null -ne $rootValues.PSObject.Properties['DpiScalePercent']) {
        [void]$entries.Add([pscustomobject]@{ KeyPath = $root; KeyName = $root; Value = $rootValues.DpiScalePercent })
    }
    return $entries.ToArray()
}

function Get-LegacyDpiValue {
    $desktop = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
    $font = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontDPI' -ErrorAction SilentlyContinue
    $logPixels = $null
    $win8 = $null
    $override = $null
    $fontDpi = $null
    if ($null -ne $desktop) {
        if ($null -ne $desktop.PSObject.Properties['LogPixels']) { $logPixels = $desktop.LogPixels }
        if ($null -ne $desktop.PSObject.Properties['Win8DpiScaling']) { $win8 = $desktop.Win8DpiScaling }
        if ($null -ne $desktop.PSObject.Properties['DesktopDPIOverride']) { $override = $desktop.DesktopDPIOverride }
    }
    if ($null -ne $font -and $null -ne $font.PSObject.Properties['LogPixels']) { $fontDpi = $font.LogPixels }
    return [pscustomobject]@{ LogPixels = $logPixels; Win8DpiScaling = $win8; DesktopDPIOverride = $override; FontDpiLogPixels = $fontDpi }
}

function Find-EdidValue {
    $roots = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Video',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}',
        'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm',
        'HKLM:\SYSTEM\CurrentControlSet\Services\amdkmdag',
        'HKLM:\SOFTWARE\NVIDIA Corporation',
        'HKLM:\SOFTWARE\AMD',
        'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    )
    $hits = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        $baseKey = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
        if ($null -eq $baseKey) { continue }
        $stack = New-Object System.Collections.Stack
        $stack.Push($baseKey)
        while ($stack.Count -gt 0) {
            $key = $stack.Pop()
            try {
                foreach ($name in @($key.GetValueNames())) {
                    $kind = 'Unknown'
                    try { $kind = $key.GetValueKind($name) } catch { continue }
                    if ($kind -ne 'Binary') { continue }
                    $bytes = $key.GetValue($name)
                    if ($bytes -and $bytes.Length -ge 128 -and $bytes[0] -eq 0 -and $bytes[1] -eq 255 -and $bytes[2] -eq 255 -and $bytes[3] -eq 255 -and $bytes[4] -eq 255 -and $bytes[5] -eq 255 -and $bytes[6] -eq 255 -and $bytes[7] -eq 0) {
                        $edid = ConvertFrom-EdidBytes -Bytes $bytes
                        [void]$hits.Add([pscustomobject]@{ Key = $key.Name; Value = $name; Identity = $edid.Identity; Length = $bytes.Length })
                    }
                }
            }
            catch { }
            try {
                foreach ($child in @($key.GetSubKeyNames())) {
                    $subKey = $key.OpenSubKey($child)
                    if ($null -ne $subKey) { $stack.Push($subKey) }
                }
            }
            catch { }
            $key.Dispose()
        }
    }
    return $hits.ToArray()
}

function Find-DpiValueName {
    $roots = @(
        'HKCU:\Control Panel',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion',
        'HKLM:\SOFTWARE\NVIDIA Corporation',
        'HKLM:\SOFTWARE\AMD',
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Video',
        'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm',
        'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceContainers'
    )
    $hits = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        $baseKey = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
        if ($null -eq $baseKey) { continue }
        $stack = New-Object System.Collections.Stack
        $stack.Push($baseKey)
        while ($stack.Count -gt 0) {
            $key = $stack.Pop()
            try {
                foreach ($name in @($key.GetValueNames())) {
                    if ($name -match '(?i)dpi') {
                        [void]$hits.Add([pscustomobject]@{ Key = $key.Name; Value = $name })
                        continue
                    }
                    # Names such as Tailscale and VideoUpScale are unrelated to
                    # the display size, so they are left out.
                    if ($name -match '(?i)scale' -and $name -notmatch '(?i)upscale|tailscale|gamma') {
                        [void]$hits.Add([pscustomobject]@{ Key = $key.Name; Value = $name })
                    }
                }
            }
            catch { }
            try {
                foreach ($child in @($key.GetSubKeyNames())) {
                    $subKey = $key.OpenSubKey($child)
                    if ($null -ne $subKey) { $stack.Push($subKey) }
                }
            }
            catch { }
            $key.Dispose()
        }
    }
    return $hits.ToArray()
}

function Invoke-MonitorReenumerate {
    param([string[]]$InstanceIds)
    if ($null -eq $InstanceIds -or $InstanceIds.Count -eq 0) {
        Add-Warning 'No monitor device instance was identified; the monitor was not rescanned.'
        return 0
    }
    $tool = Get-Command -Name 'pnputil.exe' -ErrorAction SilentlyContinue
    if ($null -eq $tool) {
        Add-Error 'pnputil.exe was not found, so the monitor was not rescanned.'
        return 0
    }
    $prefixList = New-Object System.Collections.ArrayList
    foreach ($id in $InstanceIds) {
        $segments = $id -split '\\'
        if ($segments.Count -ge 2) {
            $prefix = $segments[0] + '\' + $segments[1]
            if (-not ($prefixList -contains $prefix)) { [void]$prefixList.Add($prefix) }
        }
    }
    $prefixes = $prefixList.ToArray()
    $removed = 0
    foreach ($id in $InstanceIds) {
        try {
            & pnputil.exe /remove-device "$id" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $removed = $removed + 1
                [void]$script:Actions.Add('Removed monitor device: ' + $id)
            }
            else {
                Add-Warning ('Could not remove monitor device ' + $id + ' (pnputil exit code ' + $LASTEXITCODE + ').')
            }
        }
        catch {
            Add-Warning ('Could not remove monitor device ' + $id + ': ' + $_.Exception.Message)
        }
    }
    try {
        & pnputil.exe /scan-devices 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { [void]$script:Actions.Add('Rescanned display devices.') }
        else { Add-Warning ('The device rescan returned pnputil exit code ' + $LASTEXITCODE + '.') }
    }
    catch {
        Add-Warning ('The device rescan could not be started: ' + $_.Exception.Message)
    }
    # The device returns with a new instance id, so the wait looks for the
    # hardware id rather than the old instance or the device count.
    if ($prefixes.Count -gt 0) {
        $waitSeconds = 15
        $deadline = (Get-Date).AddSeconds($waitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $found = $false
            try {
                foreach ($device in @(Get-PnpDevice -Class Monitor -ErrorAction Stop)) {
                    if ($null -eq $device -or [string]::IsNullOrEmpty($device.InstanceId)) { continue }
                    foreach ($prefix in $prefixes) {
                        if ($device.InstanceId.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $found = $true }
                    }
                    if ($found) { break }
                }
            }
            catch {
                Add-Warning ('The monitor device list could not be read after the rescan: ' + $_.Exception.Message)
                return $removed
            }
            if ($found) { break }
        }
        if (-not $found) {
            Add-Warning ('The monitor device under ' + ($prefixes -join ', ') + ' did not reappear within ' + $waitSeconds + ' seconds after the rescan.')
        }
    }
    return $removed
}

function Reset-LegacyDpiValues {
    $folder = $script:BackupFolder
    $failuresBefore = $script:BackupFailures
    [void](Backup-RegistryKey -Path 'HKCU:\Control Panel\Desktop' -FileName 'HKCU_Desktop.reg' -Folder $folder)
    if ($script:BackupFailures -gt $failuresBefore) {
        return 'backup-failed'
    }
    try {
        Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name LogPixels -Value 96 -Type DWord
        Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name Win8DpiScaling -Value 0 -Type DWord
        # Remove the value whether or not it is present: a read taken before the
        # removal can fail and would leave the value in place.
        Remove-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name DesktopDPIOverride -ErrorAction SilentlyContinue
    }
    catch {
        Add-Error ('The legacy DPI values could not be reset: ' + $_.Exception.Message)
        return 'failed'
    }
    [void]$script:Actions.Add('Reset legacy DPI values (LogPixels=96, Win8DpiScaling=0).')
    return 'done'
}

function Save-Report {
    param([string]$Path, [object]$Data)
    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        # A .NET file call resolves a relative path against the process working
        # directory, which can differ from the PowerShell location.
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $folder = Split-Path -Parent $fullPath
        if (-not [string]::IsNullOrEmpty($folder) -and -not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder | Out-Null
        }
        # JSON is written without a byte order mark so strict parsers accept it.
        $json = $Data | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($fullPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Add-Warning ('The report could not be written to ' + $Path + ': ' + $_.Exception.Message)
        return
    }
    Write-Line ('Report written to ' + $fullPath)
}

if ($Restore) {
    $ignoredByRestore = New-Object System.Collections.ArrayList
    if ($Apply) { [void]$ignoredByRestore.Add('-Apply') }
    if ($Reboot) { [void]$ignoredByRestore.Add('-Reboot') }
    if ($PreserveExternalMonitorSettings) { [void]$ignoredByRestore.Add('-PreserveExternalMonitorSettings') }
    if ($ResetLegacyDpiValues) { [void]$ignoredByRestore.Add('-ResetLegacyDpiValues') }
    if ($SkipMonitorReenumerate) { [void]$ignoredByRestore.Add('-SkipMonitorReenumerate') }
    if ($SkipNvidiaPersistenceReset) { [void]$ignoredByRestore.Add('-SkipNvidiaPersistenceReset') }
    if ($null -ne $NvidiaScalePercent) { [void]$ignoredByRestore.Add('-NvidiaScalePercent') }
    if ($null -ne $MonitorInstanceId -and $MonitorInstanceId.Count -gt 0) { [void]$ignoredByRestore.Add('-MonitorInstanceId') }
    if ($DeepScan) { [void]$ignoredByRestore.Add('-DeepScan') }
    if ($ignoredByRestore.Count -gt 0) { Add-Warning ('These switches have no effect because -Restore only imports the .reg files: ' + ($ignoredByRestore -join ', ') + '.') }
    if (-not [string]::IsNullOrEmpty($ReportPath)) { Add-Warning 'The -ReportPath value is ignored because -Restore does not write a report.' }
    if ([string]::IsNullOrEmpty($BackupPath)) { Write-Line 'Restore needs -BackupPath.' 'Red'; return }
    if (-not (Test-Path -LiteralPath $BackupPath)) { Write-Line ('Folder not found: ' + $BackupPath) 'Red'; return }
    if (Test-Path -LiteralPath $BackupPath -PathType Leaf) { Write-Line ('The backup path is a file, not a folder: ' + $BackupPath) 'Red'; return }
    if (-not (Test-Admin)) { Write-Line 'Restore needs an elevated session.' 'Red'; return }
    $files = @(Get-ChildItem -LiteralPath $BackupPath -Filter '*.reg' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Line 'No .reg files found in the backup folder.' 'Red'; return }
    Write-Step 'Restore'
    $imported = 0
    $importFailed = 0
    foreach ($file in $files) {
        $importProblem = ''
        try {
            & reg.exe import $file.FullName 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $importProblem = 'reg.exe exit code ' + $LASTEXITCODE }
        }
        catch {
            $importProblem = $_.Exception.Message
        }
        if ([string]::IsNullOrEmpty($importProblem)) {
            $imported = $imported + 1
            Write-Line ('Imported ' + $file.Name) 'Green'
        }
        else {
            $importFailed = $importFailed + 1
            Write-Line ('Import failed: ' + $file.Name + ' (' + $importProblem + ')') 'Red'
        }
    }
    Write-Line ''
    if ($importFailed -gt 0) {
        Write-Line ('Restore finished with errors: ' + $imported + ' of ' + $files.Count + ' file(s) imported, ' + $importFailed + ' failed.') 'Red'
    }
    else {
        Write-Line ('Restore finished: ' + $imported + ' of ' + $files.Count + ' file(s) imported.') 'Yellow'
    }
    Write-Line 'Reboot before checking the display scale.' 'Yellow'
    return
}

$elevated = Test-Admin
if ($Apply -and -not $elevated) {
    Write-Line 'Applying changes needs an elevated session. Run the script from an administrator console.' 'Red'
    return
}
if ($null -ne $NvidiaScalePercent -and ($NvidiaScalePercent -lt 100 -or $NvidiaScalePercent -gt 500)) {
    Write-Line 'NvidiaScalePercent must be between 100 and 500.' 'Red'
    return
}
if ($null -ne $NvidiaScalePercent -and $SkipNvidiaPersistenceReset) {
    Add-Warning 'The -NvidiaScalePercent value is ignored because -SkipNvidiaPersistenceReset is set.'
}
if ($Apply -and -not [string]::IsNullOrEmpty($ReportPath)) {
    Add-Warning 'The -ReportPath value is ignored because -Apply writes the report into the backup folder.'
}
if (-not $Apply -and -not $Restore -and -not [string]::IsNullOrEmpty($BackupPath)) {
    Add-Warning 'The -BackupPath value is ignored because report mode makes no changes.'
}
if ([string]::IsNullOrEmpty($BackupPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrEmpty($desktop)) { $desktop = $env:TEMP }
    $BackupPath = Join-Path $desktop ('DisplayScaleRepair_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$script:BackupFolder = $BackupPath

$scaleBefore = Get-EffectiveScale
# The first attempt is quiet so a transient error does not leave a warning
# when the retry succeeds.
$pathsBefore = @(Get-DisplayPaths -Quiet)
$pathsNeedRetry = ($pathsBefore.Count -eq 0) -or (@($pathsBefore | Where-Object { $_.Available -ne 0 -and ($_.ProbeResult -ne 0 -or [string]::IsNullOrEmpty($_.DevicePath)) }).Count -gt 0)
if ($pathsNeedRetry) {
    Start-Sleep -Milliseconds 250
    $pathsBefore = @(Get-DisplayPaths)
}
$monitorsBefore = @(Get-MonitorRecord)
$internalEdidBefore = @(Get-InternalPanelEdid)
$panel = Resolve-Panel -Paths $pathsBefore -Records $monitorsBefore -InternalEdid $internalEdidBefore -OverrideIds $MonitorInstanceId
$panelDeviceIds = @($panel.InstanceIds | Sort-Object -Unique)
# More than one matched device cannot be told apart, so the per-panel scale
# removal and the actions that name a panel device are skipped unless the
# operator named the devices with -MonitorInstanceId.
$ambiguousPanel = ($panel.Selection -ne 'override') -and ($panelDeviceIds.Count -gt 1)
$panelIdentityKnown = ($null -ne $panel.Identity) -or ($panel.Selection -eq 'override')
$panelIdentified = (-not $ambiguousPanel) -and ($panelDeviceIds.Count -gt 0) -and $panelIdentityKnown
# A matched device and a readable panel identity are separate facts, so the
# messages below name whichever fact is missing. The default is the generic
# truth for "not identified", so a message can never claim that no device was
# selected when one was.
$panelSkipReason = 'the panel could not be identified'
if ($ambiguousPanel) { $panelSkipReason = 'the panel could not be told apart from other displays' }
elseif ($panelDeviceIds.Count -eq 0) { $panelSkipReason = 'no monitor device matched the panel' }
elseif (-not $panelIdentityKnown) { $panelSkipReason = 'the panel identity could not be read' }
$overrideCount = @($panel.Records | Where-Object { $null -ne $_.Override }).Count
$scaleEntriesBefore = @(Get-ScaleEntry)
$nvidiaBefore = @(Get-NvidiaDpiValue)
$legacyBefore = Get-LegacyDpiValue

Write-Step 'System'
$computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
if ($null -ne $computer) { Write-Line ($computer.Manufacturer + ' ' + $computer.Model) }
if ($null -ne $bios) { Write-Line ('BIOS ' + $bios.SMBIOSBIOSVersion + ' ' + $bios.ReleaseDate) }
Write-Line ('Elevated: ' + $elevated)

Write-Step 'Effective scale'
foreach ($monitor in @($scaleBefore.Monitors)) {
    if ($monitor.Result -ne 0) {
        Write-Line ($monitor.Device + '  DPI query failed (result ' + $monitor.Result + ')') 'Yellow'
    }
    else {
        Write-Line ($monitor.Device + '  DPI ' + $monitor.DpiX + 'x' + $monitor.DpiY + '  ' + $monitor.Percent + '%  ' + $monitor.Bounds)
    }
}
if (@($scaleBefore.Monitors).Count -eq 0) {
    Add-Warning 'The monitor enumeration returned no display, so no effective scale could be read.'
}
Write-Line ('System DPI: ' + $scaleBefore.SystemDpi)
if ($scaleBefore.Awareness -ne 2) {
    Add-Warning ('Per-monitor DPI awareness is not active (level ' + $scaleBefore.Awareness + '), so the reported scale may be virtualized.')
}

Write-Step 'Active display paths'
foreach ($path in @($pathsBefore)) {
    $edidText = 'edid unknown'
    if ($path.Available -ne 0 -and $path.ProbeResult -eq 0) { $edidText = 'edid 0x' + ('{0:X4}' -f $path.EdidMfg) + ':0x' + ('{0:X4}' -f $path.EdidProduct) }
    Write-Line ('Target 0x' + ('{0:X}' -f $path.TargetId) + '  tech 0x' + ('{0:X}' -f $path.Technology) + '  ' + $edidText + '  ' + $path.DevicePath)
}
if ($pathsBefore.Count -eq 0) { Write-Line 'No active path was returned.' 'Yellow' }

Write-Step 'Panel'
if ($null -ne $panel.Identity) {
    $panelRecord = @($panel.Records | Where-Object { $_.Edid.Valid })[0]
    Write-Line ('Identity: ' + $panel.Identity)
    Write-Line ('EDID: ' + $panelRecord.Edid.Mfg + ' product 0x' + ('{0:X4}' -f $panelRecord.Edid.Product) + '  ' + $panelRecord.Edid.WidthCm + 'x' + $panelRecord.Edid.HeightCm + ' cm  ' + $panelRecord.Edid.DiagonalInches + ' in  ' + $panelRecord.Edid.Ppi + ' PPI')
    Write-Line ('Monitor devices: ' + ($panel.InstanceIds -join ', '))
    Write-Line ('Matched by: ' + $panel.Selection)
    if ($ambiguousPanel) {
        if ($panel.Selection -eq 'active-path') {
            Add-Warning ('More than one display is active and none was identified as the internal panel, so ' + $panel.Identity + ' was taken from the active display paths. Pass -MonitorInstanceId to name the panel.')
        }
        else {
            Add-Warning ('More than one monitor device matches the panel evidence (' + $panelDeviceIds.Count + '), so no single panel device was selected. Pass -MonitorInstanceId to name the panel.')
        }
    }
}
else {
    if ($panelDeviceIds.Count -eq 0) {
        Write-Line 'The panel could not be matched to a monitor device.' 'Yellow'
    }
    else {
        Write-Line ('The panel was matched to ' + ($panelDeviceIds -join ', ') + ' but no readable EDID identity was found.') 'Yellow'
    }
}

Write-Step 'Monitor devices'
foreach ($record in @($monitorsBefore)) {
    $overrideText = 'no'
    if ($null -ne $record.Override) {
        if ($record.Override.Valid) { $overrideText = 'yes (' + $record.Override.Identity + ')' }
        else { $overrideText = 'yes (not a valid EDID)' }
    }
    $edidText = 'unknown'
    if ($record.Edid.Valid) { $edidText = $record.Edid.Identity }
    Write-Line ($record.InstanceId + '  ' + $record.Status + '  EDID ' + $edidText + '  override ' + $overrideText)
}

Write-Step 'Internal panel EDID cache'
if ($internalEdidBefore.Count -eq 0) { Write-Line 'No cache entries.' }
foreach ($entry in @($internalEdidBefore)) {
    $edidText = 'unknown'
    $staleText = 'unknown'
    if ($entry.Edid.Valid) {
        $edidText = $entry.Edid.Identity
        if ($null -ne $panel.Identity) {
            if ($entry.Edid.Identity -ne $panel.Identity) { $staleText = 'yes' } else { $staleText = 'no' }
        }
    }
    Write-Line ($entry.Name + '  ' + $edidText + '  stale: ' + $staleText)
}

Write-Step 'Per-display scale state'
if ($scaleEntriesBefore.Count -eq 0) { Write-Line 'No entries.' }
foreach ($entry in @($scaleEntriesBefore)) {
    Write-Line ($entry.Store + '  ' + $entry.Name + '  DpiValue ' + $entry.DpiValue)
}

Write-Step 'NVIDIA hybrid graphics'
if ($nvidiaBefore.Count -eq 0) { Write-Line 'No hybrid graphics scale value.' }
foreach ($entry in @($nvidiaBefore)) {
    Write-Line ($entry.KeyName + '  DpiScalePercent ' + $entry.Value)
}

Write-Step 'Legacy DPI values'
Write-Line ('HKCU LogPixels: ' + $legacyBefore.LogPixels + '  Win8DpiScaling: ' + $legacyBefore.Win8DpiScaling + '  DesktopDPIOverride: ' + $legacyBefore.DesktopDPIOverride)
Write-Line ('HKLM FontDPI LogPixels: ' + $legacyBefore.FontDpiLogPixels)

$deepScanData = $null
if ($DeepScan) {
    Write-Step 'Deep scan'
    $edidValues = @(Find-EdidValue)
    Write-Line ('EDID-shaped values: ' + $edidValues.Count)
    foreach ($hit in @($edidValues | Select-Object -First 30)) {
        Write-Line ($hit.Key + ' :: ' + $hit.Value + ' :: ' + $hit.Identity)
    }
    $dpiValues = @(Find-DpiValueName)
    Write-Line ('DPI/scale value names: ' + $dpiValues.Count)
    foreach ($hit in @($dpiValues | Select-Object -First 30)) {
        Write-Line ($hit.Key + ' :: ' + $hit.Value)
    }
    $deepScanData = [ordered]@{
        edidValueCount = $edidValues.Count
        edidValues = @($edidValues | Select-Object -First 200)
        dpiValueCount = $dpiValues.Count
        dpiValues = @($dpiValues | Select-Object -First 200)
    }
}

if (-not $Apply) {
    Write-Step 'Plan'
    $planItems = New-Object System.Collections.ArrayList
    [void]$planItems.Add('Export the display registry keys that will be touched.')
    [void]$planItems.Add('Remove the internal panel EDID cache and the topology caches.')
    if ($PreserveExternalMonitorSettings -and ($null -eq $panel.Identity)) {
        [void]$planItems.Add('Leave per-display scale entries in place because the panel identity is unknown.')
    }
    elseif ($PreserveExternalMonitorSettings -and $ambiguousPanel) {
        [void]$planItems.Add('Leave per-display scale entries in place because the panel could not be told apart from other displays.')
    }
    elseif ($PreserveExternalMonitorSettings) {
        [void]$planItems.Add('Remove the per-display scale entries that belong to ' + $panel.Identity + '.')
    }
    else {
        [void]$planItems.Add('Remove all per-display scale entries.')
    }
    if (($null -ne $NvidiaScalePercent) -and (-not $SkipNvidiaPersistenceReset) -and ($nvidiaBefore.Count -eq 0)) {
        Add-Warning 'The NVIDIA hybrid graphics scale value is not present, so the set request cannot be applied.'
        [void]$planItems.Add('Do not set the NVIDIA hybrid graphics scale value because it is not present.')
    }
    elseif (-not $SkipNvidiaPersistenceReset) {
        if ($null -ne $NvidiaScalePercent) { [void]$planItems.Add('Set the NVIDIA hybrid graphics scale value to ' + $NvidiaScalePercent + '%.') }
        else { [void]$planItems.Add('Remove the NVIDIA hybrid graphics scale value when present.') }
    }
    if ($overrideCount -gt 0) {
        if ($panelIdentified) { [void]$planItems.Add('Remove the EDID override on the identified panel device (' + $overrideCount + ').') }
        else { [void]$planItems.Add('Leave the EDID override in place because ' + $panelSkipReason + ' (' + $overrideCount + ').') }
    }
    if ($ResetLegacyDpiValues) { [void]$planItems.Add('Reset the legacy DPI values.') }
    if (-not $SkipMonitorReenumerate) {
        if (-not $panelIdentified) { [void]$planItems.Add('Skip the monitor rescan because ' + $panelSkipReason + '.') }
        else { [void]$planItems.Add('Remove and rescan the active panel monitor device.') }
    }
    [void]$planItems.Add('Re-read the state, write a report, and ask for a reboot.')
    Write-Line 'Run with -Apply to perform these changes:'
    for ($index = 0; $index -lt $planItems.Count; $index++) {
        Write-Line (($index + 1).ToString() + '. ' + $planItems[$index])
    }
    Write-Line ''
    Write-Line 'No change was made.'
    if ($Reboot) { Write-Line 'The -Reboot switch was ignored because no change was made.' 'Yellow' }
    $reportData = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        mode = 'Report'
        elevated = $elevated
        scale = $scaleBefore
        paths = $pathsBefore
        panel = $panel
        monitors = $monitorsBefore
        internalPanelEdid = $internalEdidBefore
        scaleEntries = $scaleEntriesBefore
        nvidia = $nvidiaBefore
        legacy = $legacyBefore
        deepScan = $deepScanData
        warnings = $script:Warnings
        errors = $script:Errors
    }
    if (-not [string]::IsNullOrEmpty($ReportPath)) { Save-Report -Path $ReportPath -Data $reportData }
    return
}

if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
    Add-Error ('The backup path is a file, not a folder: ' + $BackupPath)
    Write-Line 'No change was made.' 'Yellow'
    return
}
Write-Step 'Plan'
Write-Line ('Backup folder: ' + $BackupPath)
if ($null -ne $panel.Identity) {
    Write-Line ('Panel identity: ' + $panel.Identity)
    Write-Line ('Panel identified by: ' + $panel.Selection)
}
else { Write-Line 'Panel identity: unknown' 'Yellow' }
if (-not $SkipMonitorReenumerate) {
    if (-not $panelIdentified) { Write-Line ('Monitor rescan will be skipped because ' + $panelSkipReason + '.') 'Yellow' }
    else { Write-Line ('Monitor devices to rescan: ' + ($panel.InstanceIds -join ', ')) }
}
else { Write-Line 'Monitor rescan is skipped (-SkipMonitorReenumerate).' }
if (-not $SkipNvidiaPersistenceReset) {
    if (($null -ne $NvidiaScalePercent) -and ($nvidiaBefore.Count -eq 0)) {
        Add-Warning 'The NVIDIA hybrid graphics scale value is not present, so the set request cannot be applied.'
        Write-Line 'The NVIDIA scale value cannot be set because it is not present.' 'Yellow'
    }
    elseif ($null -ne $NvidiaScalePercent) { Write-Line ('NVIDIA scale value will be set to ' + $NvidiaScalePercent + '%.') }
    else { Write-Line 'NVIDIA scale value will be removed when present.' }
}
else { Write-Line 'The NVIDIA scale value is left untouched (-SkipNvidiaPersistenceReset).' }
if ($PreserveExternalMonitorSettings) {
    if ($null -eq $panel.Identity) { Write-Line 'Per-display scale entries will be left in place because the panel identity is unknown.' 'Yellow' }
    elseif ($ambiguousPanel) { Write-Line 'Per-display scale entries will be left in place because the panel could not be told apart from other displays.' 'Yellow' }
    else { Write-Line ('Scale entries for ' + $panel.Identity + ' will be removed; entries for other displays are kept.') }
}
else { Write-Line 'All per-display scale entries will be removed.' }
Write-Line 'The internal panel EDID cache and topology caches will be removed.'
if ($overrideCount -gt 0) {
    if ($panelIdentified) { Write-Line ('The EDID override on the identified panel device will be removed (' + $overrideCount + ').') }
    else { Write-Line ('The EDID override will be left in place because ' + $panelSkipReason + ' (' + $overrideCount + ').') 'Yellow' }
}
if ($ResetLegacyDpiValues) { Write-Line 'Legacy DPI values will be reset.' }

if (-not $Force) {
    Write-Line ''
    $answer = Read-Host 'Type YES to apply these changes'
    if ($answer -ne 'YES') {
        Write-Line 'Cancelled.' 'Yellow'
        return
    }
}

if (-not (Test-Path -LiteralPath $BackupPath)) {
    try { New-Item -ItemType Directory -Path $BackupPath | Out-Null }
    catch {
        Add-Error ('The backup folder could not be created: ' + $_.Exception.Message)
        Write-Line 'No change was made.' 'Yellow'
        return
    }
}

Write-Step 'Backup'
[void](Backup-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\InternalMonEdid' -FileName 'InternalMonEdid.reg' -Folder $BackupPath)
[void](Backup-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ScaleFactors' -FileName 'ScaleFactors.reg' -Folder $BackupPath)
[void](Backup-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' -FileName 'Configuration.reg' -Folder $BackupPath)
[void](Backup-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity' -FileName 'Connectivity.reg' -Folder $BackupPath)
[void](Backup-RegistryKey -Path 'HKCU:\Control Panel\Desktop\PerMonitorSettings' -FileName 'PerMonitorSettings.reg' -Folder $BackupPath)
[void](Backup-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\Global\NvHybrid' -FileName 'NvHybrid.reg' -Folder $BackupPath)
$enumBackups = @{}
foreach ($record in @($monitorsBefore)) {
    if ($enumBackups.ContainsKey($record.MonitorId)) { continue }
    $enumBackups[$record.MonitorId] = $true
    $enumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\' + $record.MonitorId
    [void](Backup-RegistryKey -Path $enumPath -FileName ('Enum_DISPLAY_' + $record.MonitorId + '.reg') -Folder $BackupPath)
}

if ($script:BackupFailures -gt 0) {
    Add-Error ('Backup failed for ' + $script:BackupFailures + ' registry key(s). No change was made.')
    return
}

if (-not $SkipNvidiaPersistenceReset) {
    Write-Step 'NVIDIA hybrid graphics'
    $nvidiaEntries = @(Get-NvidiaDpiValue)
    if ($nvidiaEntries.Count -eq 0) {
        if ($null -ne $NvidiaScalePercent) {
            Add-Error ('No hybrid graphics scale value exists, so it could not be set to ' + $NvidiaScalePercent + '%.')
        }
        else { Write-Line 'No hybrid graphics scale value found.' }
    }
    foreach ($entry in @($nvidiaEntries)) {
        try {
            if ($null -ne $NvidiaScalePercent) {
                Set-ItemProperty -LiteralPath $entry.KeyPath -Name DpiScalePercent -Value $NvidiaScalePercent -Type DWord
                [void]$script:Actions.Add('Set NVIDIA DpiScalePercent to ' + $NvidiaScalePercent + ' at ' + $entry.KeyName)
                Write-Line ('Set ' + $entry.KeyName + ' to ' + $NvidiaScalePercent)
            }
            else {
                Remove-ItemProperty -LiteralPath $entry.KeyPath -Name DpiScalePercent
                [void]$script:Actions.Add('Removed NVIDIA DpiScalePercent at ' + $entry.KeyName)
                Write-Line ('Removed ' + $entry.KeyName + ' DpiScalePercent')
            }
        }
        catch {
            Add-Error ('The NVIDIA scale value could not be changed at ' + $entry.KeyName + ': ' + $_.Exception.Message)
        }
    }
}

Write-Step 'Display state'
if (-not $PreserveExternalMonitorSettings) {
    $machineScaleResult = Remove-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ScaleFactors'
    $userScaleResult = Remove-RegistryKey -Path 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    if ($machineScaleResult -eq $false -or $userScaleResult -eq $false) { Write-Line 'Some per-display scale stores could not be removed.' 'Yellow' }
    elseif ($machineScaleResult -eq $true -or $userScaleResult -eq $true) { Write-Line 'Removed the per-display scale stores that were present.' }
    else { Write-Line 'No per-display scale stores were present.' }
}
else {
    if ($null -eq $panel.Identity) {
        Add-Warning 'The panel identity is unknown, so per-panel scale entries were left in place. Run without -PreserveExternalMonitorSettings to remove all entries.'
    }
    elseif ($ambiguousPanel) {
        Add-Warning 'More than one monitor device could be the panel, so per-panel scale entries were left in place to avoid changing another display. Pass -MonitorInstanceId to name the panel.'
    }
    else {
        $prefix = $panel.Identity
        $matchedCount = 0
        $removeCount = 0
        foreach ($entry in @(Get-ScaleEntry)) {
            # Compare the identity literally: a wildcard character in a malformed
            # EDID must not change which entries are removed.
            if ($entry.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchedCount = $matchedCount + 1
                if (Remove-DpiScaleEntry -Store $entry.Store -Name $entry.Name) { $removeCount = $removeCount + 1 }
            }
        }
        if ($matchedCount -eq 0) { Write-Line ('No saved scale entry for ' + $prefix + ' was found.') }
        elseif ($removeCount -lt $matchedCount) { Write-Line ('Removed ' + $removeCount + ' of ' + $matchedCount + ' scale entries for ' + $prefix + '; the rest could not be removed.') 'Yellow' }
        else { Write-Line ('Removed ' + $removeCount + ' scale entries for ' + $prefix + '.') }
    }
}
$cacheResult = Remove-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\InternalMonEdid'
$configurationResult = Remove-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
$connectivityResult = Remove-RegistryKey -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity'
if ($cacheResult -eq $false -or $configurationResult -eq $false -or $connectivityResult -eq $false) { Write-Line 'Some display caches could not be removed.' 'Yellow' }
elseif ($cacheResult -eq $true -or $configurationResult -eq $true -or $connectivityResult -eq $true) { Write-Line 'Removed the display caches that were present.' }
else { Write-Line 'No display caches were present.' }

Write-Step 'Panel EDID override'
if (-not $panelIdentified) {
    Write-Line ('The EDID override step was skipped because ' + $panelSkipReason + '.') 'Yellow'
}
else {
    $overrideSeen = 0
    $overrideRemoved = 0
    foreach ($record in @($panel.Records)) {
        if ($null -eq $record.Override) { continue }
        $overrideSeen = $overrideSeen + 1
        $parameterPath = Join-Path $record.EnumPath 'Device Parameters'
        $failuresBefore = $script:BackupFailures
        [void](Backup-RegistryKey -Path $record.EnumPath -FileName ('Enum_' + $record.MonitorId + '_' + $record.InstanceName + '.reg') -Folder $BackupPath)
        if ($script:BackupFailures -gt $failuresBefore) {
            Add-Warning ('The EDID override on ' + $record.InstanceId + ' was kept because its backup failed.')
            continue
        }
        try {
            Remove-ItemProperty -LiteralPath $parameterPath -Name EDID_OVERRIDE
        }
        catch {
            Add-Error ('The EDID override on ' + $record.InstanceId + ' could not be removed: ' + $_.Exception.Message)
            continue
        }
        [void]$script:Actions.Add('Removed EDID_OVERRIDE from ' + $record.InstanceId)
        $overrideRemoved = $overrideRemoved + 1
    }
    if ($overrideSeen -eq 0) { Write-Line 'No EDID override was present on the identified panel device.' }
    elseif ($overrideRemoved -eq 0) {
        if ($overrideSeen -eq 1) { Write-Line 'The EDID override on the identified panel device was kept.' 'Yellow' }
        else { Write-Line ('All ' + $overrideSeen + ' EDID overrides on the identified panel device were kept.') 'Yellow' }
    }
    elseif ($overrideRemoved -lt $overrideSeen) { Write-Line ('Removed ' + $overrideRemoved + ' of ' + $overrideSeen + ' EDID overrides on the identified panel device.') 'Yellow' }
    else { Write-Line ('Removed ' + $overrideRemoved + ' EDID override(s) on the identified panel device.') }
}

if ($ResetLegacyDpiValues) {
    Write-Step 'Legacy DPI values'
    $legacyResult = Reset-LegacyDpiValues
    if ($legacyResult -eq 'done') { Write-Line 'Legacy DPI values reset.' }
    elseif ($legacyResult -eq 'backup-failed') { Write-Line 'Legacy DPI values were left unchanged because the backup failed.' 'Yellow' }
    else { Write-Line 'The legacy DPI values could not be fully reset.' 'Yellow' }
}

if (-not $SkipMonitorReenumerate) {
    Write-Step 'Monitor rescan'
    if (-not $panelIdentified) {
        Add-Warning ('The monitor was not rescanned because ' + $panelSkipReason + '.')
    }
    else {
        $removedDevices = Invoke-MonitorReenumerate -InstanceIds $panel.InstanceIds
        Write-Line ('Monitor devices removed: ' + $removedDevices)
    }
}

$scaleAfter = Wait-DisplayReady -TimeoutSeconds 10
foreach ($monitor in @($scaleAfter.Monitors)) {
    if ($monitor.Result -ne 0) {
        Add-Warning ('The DPI query failed for ' + $monitor.Device + ' (result ' + $monitor.Result + ') after the changes, so the resulting scale is not known for that display.')
    }
}
$pathsAfter = @(Get-DisplayPaths)
$internalEdidAfter = @(Get-InternalPanelEdid)
$scaleEntriesAfter = @(Get-ScaleEntry)
$nvidiaAfter = @(Get-NvidiaDpiValue)
$legacyAfter = Get-LegacyDpiValue

Write-Step 'State after the changes'
foreach ($monitor in @($scaleAfter.Monitors)) {
    if ($monitor.Result -ne 0) {
        Write-Line ($monitor.Device + '  DPI query failed (result ' + $monitor.Result + ')') 'Yellow'
    }
    else {
        Write-Line ($monitor.Device + '  DPI ' + $monitor.DpiX + 'x' + $monitor.DpiY + '  ' + $monitor.Percent + '%')
    }
}
if (@($scaleAfter.Monitors).Count -eq 0) {
    Add-Warning 'The monitor enumeration returned no display after the changes, so the resulting scale could not be read.'
}
Write-Line ('System DPI: ' + $scaleAfter.SystemDpi)
Write-Line ('Internal panel cache entries: ' + $internalEdidAfter.Count)
Write-Line ('Scale entries: ' + $scaleEntriesAfter.Count)
$nvidiaText = 'none'
if ($nvidiaAfter.Count -gt 0) { $nvidiaText = (($nvidiaAfter | ForEach-Object { $_.Value }) -join ',') }
Write-Line ('NVIDIA hybrid graphics scale: ' + $nvidiaText)

$reportData = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    mode = 'Apply'
    elevated = $elevated
    backupFolder = $BackupPath
    before = [ordered]@{
        scale = $scaleBefore
        paths = $pathsBefore
        panel = $panel
        monitors = $monitorsBefore
        internalPanelEdid = $internalEdidBefore
        scaleEntries = $scaleEntriesBefore
        nvidia = $nvidiaBefore
        legacy = $legacyBefore
        deepScan = $deepScanData
    }
    after = [ordered]@{
        scale = $scaleAfter
        paths = $pathsAfter
        internalPanelEdid = $internalEdidAfter
        scaleEntries = $scaleEntriesAfter
        nvidia = $nvidiaAfter
        legacy = $legacyAfter
    }
    actions = $script:Actions
    warnings = $script:Warnings
    errors = $script:Errors
}
Save-Report -Path (Join-Path $BackupPath 'report.json') -Data $reportData

if ($script:Errors.Count -gt 0) {
    Write-Line ('Some steps failed (' + $script:Errors.Count + ' error(s)); the system may be partially changed. See the Error lines above and the report file.') 'Yellow'
}

Write-Step 'Next steps'
Write-Line 'Reboot before judging the result.' 'Yellow'
Write-Line 'After the reboot, open Settings > System > Display and set Scale to Recommended or to the size you want.'
Write-Line 'If the scale is still wrong, run the script again with -DeepScan and check the NVIDIA hybrid graphics scale value.'
Write-Line 'Other causes to check by hand: a vendor display utility, the GPU control panel MUX mode, or an outdated GPU driver.'

if ($Reboot) {
    if (-not $Force) {
        $answer = Read-Host 'Type YES to restart now'
        if ($answer -ne 'YES') { Write-Line 'Restart skipped.' 'Yellow'; return }
    }
    try {
        Restart-Computer -Force
    }
    catch {
        Write-Line ('The restart failed: ' + $_.Exception.Message) 'Red'
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
  Monitor SGuard64.exe / SGuardSvc64.exe: last CPU affinity + Low priority.
#>

param(
    [string[]] $TargetProcessNames = @('SGuard64.exe', 'SGuardSvc64.exe'),
    [int] $PollIntervalSeconds = 60,
    [string] $LogFile = ''
)

$ErrorActionPreference = 'Stop'

if (-not ('Win32.ProcessTune' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class Win32 {
    public const uint PROCESS_SET_INFORMATION = 0x0200;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint IDLE_PRIORITY_CLASS = 0x00000040;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetPriorityClass(IntPtr hProcess);
}
'@
}

function Write-MonitorLog {
    param([string] $Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    if ($Host.Name -ne 'NonInteractiveHost') {
        Write-Host $line
    }
    if ($LogFile) {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        if (-not (Test-Path $LogFile)) {
            [System.IO.File]::WriteAllText($LogFile, "$line`r`n", $utf8Bom)
        } else {
            [System.IO.File]::AppendAllText($LogFile, "$line`r`n", $utf8Bom)
        }
    }
}

function Write-MonitorWarning {
    param([string] $Message)
    Write-MonitorLog "WARN: $Message"
    Write-Warning $Message
}

function Get-LastCpuAffinityMask {
    $n = [Environment]::ProcessorCount
    [IntPtr]::new([Int64](1 -shl ($n - 1)))
}

function Test-IsLowPriority {
    param([System.Diagnostics.Process] $Process)
    try {
        $cls = [Win32]::GetPriorityClass($Process.Handle)
        if ($cls -eq 0) { return $false }
        return $cls -eq [Win32]::IDLE_PRIORITY_CLASS
    } catch {
        try {
            return $Process.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::Idle
        } catch {
            return $false
        }
    }
}

function Set-ProcessLowPriority {
    param([System.Diagnostics.Process] $Process)

    if (-not [Win32]::SetPriorityClass($Process.Handle, [Win32]::IDLE_PRIORITY_CLASS)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetPriorityClass failed, error: $err"
    }

    if (-not (Test-IsLowPriority -Process $Process)) {
        throw 'SetPriorityClass returned OK but priority is still not Low'
    }
}

function Set-ProcessLastCpuAffinity {
    param([System.Diagnostics.Process] $Process)
    $Process.ProcessorAffinity = Get-LastCpuAffinityMask
    $expected = [Int64](Get-LastCpuAffinityMask)
    if ($Process.ProcessorAffinity.ToInt64() -ne $expected) {
        throw 'ProcessorAffinity set failed verification'
    }
}

function Test-ProcessNeedsTune {
    param([System.Diagnostics.Process] $Process)

    $needsAffinity = $false
    $needsPriority = $false

    try {
        $expected = [Int64](Get-LastCpuAffinityMask)
        $needsAffinity = $Process.ProcessorAffinity.ToInt64() -ne $expected
    } catch {
        $needsAffinity = $true
    }

    try {
        $needsPriority = -not (Test-IsLowPriority -Process $Process)
    } catch {
        $needsPriority = $true
    }

    return ($needsAffinity -or $needsPriority)
}

function Invoke-ProcessTune {
    param(
        [System.Diagnostics.Process] $Process,
        [switch] $Reapplied
    )

    $cpuIndex = [Environment]::ProcessorCount - 1
    $action = if ($Reapplied) { 're-applied' } else { 'applied' }
    $parts = @()

    try {
        Set-ProcessLastCpuAffinity -Process $Process
        $parts += "CPU $cpuIndex only"
    } catch {
        Write-MonitorWarning "$($Process.ProcessName) (PID $($Process.Id)) affinity: $($_.Exception.Message)"
    }

    try {
        Set-ProcessLowPriority -Process $Process
        $parts += 'Low priority'
    } catch {
        Write-MonitorWarning "$($Process.ProcessName) (PID $($Process.Id)) priority: $($_.Exception.Message)"
    }

    if ($parts.Count -gt 0) {
        Write-MonitorLog "$($Process.ProcessName) (PID $($Process.Id)) -> $action $($parts -join ', ')"
    }
}

$targetSet = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($n in $TargetProcessNames) {
    [void]$targetSet.Add($n)
    if ($n -match '\.exe$') {
        [void]$targetSet.Add($n.Substring(0, $n.Length - 4))
    }
}

function Test-TargetProcess {
    param([string] $ProcessName)
    return $targetSet.Contains($ProcessName)
}

$loggedPids = [System.Collections.Generic.HashSet[int]]::new()
$lastCpu = [Environment]::ProcessorCount - 1
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-MonitorLog "Watching: $($TargetProcessNames -join ', ')"
Write-MonitorLog "Actions: Low priority + last CPU only (CPU $lastCpu of $([Environment]::ProcessorCount))"
Write-MonitorLog "Re-check every ${PollIntervalSeconds}s and re-apply if ACE-Guard changes settings"
Write-MonitorLog "Running as admin: $isAdmin"
if (-not $isAdmin) {
    Write-MonitorWarning 'Not running as administrator - priority may fail to apply'
}
if ($LogFile) { Write-MonitorLog "Log file: $LogFile" }
Write-MonitorLog "----- monitor started -----"

while ($true) {
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if (-not (Test-TargetProcess -ProcessName $proc.ProcessName)) { continue }

        try {
            if (-not (Test-ProcessNeedsTune -Process $proc)) { continue }
        } catch {
            Write-MonitorWarning "$($proc.ProcessName) (PID $($proc.Id)) check: $($_.Exception.Message)"
            continue
        }

        try {
            $reapplied = $loggedPids.Contains($proc.Id)
            Invoke-ProcessTune -Process $proc -Reapplied:$reapplied
            [void]$loggedPids.Add($proc.Id)
        } catch {
            Write-MonitorWarning "$($proc.ProcessName) (PID $($proc.Id)): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}

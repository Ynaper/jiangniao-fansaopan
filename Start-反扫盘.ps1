#Requires -Version 5.1
<#
.SYNOPSIS
  反扫盘主入口 - 管理托盘图标、进程监控、悬浮窗
  -Boot      开机自启模式（不显示设置窗口）
  -Settings  直接打开设置窗口
#>
param(
    [switch] $Boot,
    [switch] $Settings,
    [string] $ScriptDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $ScriptDir = $ScriptDir.Trim().Trim('"').TrimEnd('\', '/')
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$MonitorScript  = Join-Path $ScriptDir 'Set-ProcessEfficiencyMonitor.ps1'
$OverlayScript  = Join-Path $ScriptDir 'Show-CharacterOverlay.ps1'
$SettingsScript = Join-Path $ScriptDir 'Show-SettingsWindow.ps1'
$SettingsFile   = Join-Path $ScriptDir 'settings.json'
$LogFile        = Join-Path $ScriptDir 'monitor.log'
$PidFile        = Join-Path $ScriptDir 'monitor.pid'

function Read-Settings {
    if (Test-Path $SettingsFile) {
        try {
            $s = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $s.PSObject.Properties.Match('FirstRunComplete').Count) { $s | Add-Member NoteProperty FirstRunComplete $false }
            if (-not $s.PSObject.Properties.Match('AutoStartEnabled').Count) { $s | Add-Member NoteProperty AutoStartEnabled $false }
            if (-not $s.PSObject.Properties.Match('ShowOverlayByDefault').Count) { $s | Add-Member NoteProperty ShowOverlayByDefault $true }
            if (-not $s.PSObject.Properties.Match('OverlayPermanentlyHidden').Count) { $s | Add-Member NoteProperty OverlayPermanentlyHidden $false }
            if (-not $s.PSObject.Properties.Match('CustomCharacters').Count) { $s | Add-Member NoteProperty CustomCharacters @() }
            if (-not $s.PSObject.Properties.Match('CustomReplies').Count) { $s | Add-Member NoteProperty CustomReplies @() }
            return $s
        } catch {}
    }
    return [pscustomobject]@{FirstRunComplete=$false;AutoStartEnabled=$false;ShowOverlayByDefault=$true;OverlayPermanentlyHidden=$false;CustomCharacters=@();CustomReplies=@()}
}

function Save-Settings($s) { $s | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsFile -Encoding UTF8 }

function Test-MonitorRunning {
    if (Test-Path -LiteralPath $PidFile) {
        $pidText = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pidText -match '^\d+$') {
            $proc = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
            if ($proc) { return $true }
        }
    }
    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Set-ProcessEfficiencyMonitor*' }
    return [bool]$running
}

function Test-OverlayRunning {
    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Show-CharacterOverlay*' }
    return [bool]$running
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-MonitorBackground {
    if (Test-MonitorRunning) { return }
    $monitorArgs = @(
        '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
        '-File',$MonitorScript,'-LogFile',$LogFile,'-PollIntervalSeconds','60'
    )
    $startParams = @{
        FilePath         = 'powershell.exe'
        ArgumentList     = $monitorArgs
        WorkingDirectory = $ScriptDir
        WindowStyle      = 'Hidden'
        PassThru         = $true
    }
    if (-not (Test-IsAdmin)) { $startParams['Verb'] = 'RunAs' }
    $proc = Start-Process @startParams
    $proc.Id | Set-Content -LiteralPath $PidFile -Encoding ASCII
}

function Start-Overlay {
    if (Test-OverlayRunning) { return }
    if (-not (Test-Path -LiteralPath $OverlayScript)) { return }

    $overlayArgs = @(
        '-NoProfile','-WindowStyle','Hidden','-STA','-ExecutionPolicy','Bypass',
        '-File',$OverlayScript
    )
    $olFile = Join-Path $ScriptDir 'overlay.log'
    $oeFile = Join-Path $ScriptDir 'overlay-error.log'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $overlayArgs `
        -WorkingDirectory $ScriptDir -WindowStyle Hidden `
        -RedirectStandardOutput $olFile -RedirectStandardError $oeFile
}

function Stop-Overlay {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Show-CharacterOverlay*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-Monitor {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Set-ProcessEfficiencyMonitor*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
}

function Open-Settings {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SettingsScript,'-ScriptDir',$ScriptDir)
    Start-Process powershell -Wait -ArgumentList $args
    # Reload settings after user may have changed them
    $script:CurrentSettings = Read-Settings
    Sync-TrayMenu
}

function Toggle-Overlay {
    if (Test-OverlayRunning) {
        Stop-Overlay
    } else {
        $script:CurrentSettings.OverlayPermanentlyHidden = $false
        Save-Settings $script:CurrentSettings
        Start-Overlay
    }
    Sync-TrayMenu
}

# ============== Tray Icon ==============
$script:TrayIcon = $null
$script:CurrentSettings = $null
$script:showOverlayItem = $null
$script:hideOverlayItem = $null

function New-TrayIcon {
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = New-Object System.Drawing.Icon (Join-Path $ScriptDir 'icon.ico')
    $icon.Text = '反扫盘'
    $icon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $settingsItem = $menu.Items.Add('打开设置')
    $settingsItem.Add_Click({ Open-Settings })

    $menu.Items.Add('-') | Out-Null

    $script:overlayToggleItem = $menu.Items.Add('显示/隐藏悬浮窗')
    $script:overlayToggleItem.Add_Click({ Toggle-Overlay })

    $menu.Items.Add('-') | Out-Null

    $exitItem = $menu.Items.Add('退出')
    $exitItem.Add_Click({
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
        Stop-Overlay
        Stop-Monitor
        [System.Windows.Forms.Application]::Exit()
    })

    $icon.ContextMenuStrip = $menu
    $icon.Add_DoubleClick({ Open-Settings })

    $script:TrayIcon = $icon
}

function Sync-TrayMenu {
    if (-not $script:TrayIcon) { return }
    if ($script:overlayToggleItem) {
        $script:overlayToggleItem.Text = '显示/隐藏悬浮窗'
    }
}

# ============== Main Entry ==============
$script:CurrentSettings = Read-Settings

# Always start the monitor
Start-MonitorBackground

# Create tray icon
New-TrayIcon
Sync-TrayMenu

if ($Settings) {
    Open-Settings
} elseif ($Boot) {
    # Boot mode: no settings window, launch overlay if enabled
    if ($script:CurrentSettings.ShowOverlayByDefault -and -not $script:CurrentSettings.OverlayPermanentlyHidden) {
        Start-Overlay
    }
} else {
    # Manual launch
    if (-not $script:CurrentSettings.FirstRunComplete) {
        Open-Settings
        # Reload after settings closed
        $script:CurrentSettings = Read-Settings
    }
    # Launch overlay if configured
    if ($script:CurrentSettings.ShowOverlayByDefault -and -not $script:CurrentSettings.OverlayPermanentlyHidden) {
        Start-Overlay
    }
}
Sync-TrayMenu

# Keep the tray icon alive
[System.Windows.Forms.Application]::Run()

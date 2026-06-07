#Requires -Version 5.1
<#
.SYNOPSIS
  反扫盘设置窗口 - 首次安装弹出，之后仅在手动打开时显示
#>
param(
    [string] $ScriptDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)
$ErrorActionPreference = 'Stop'
$ScriptDir = $ScriptDir.Trim().Trim('"').TrimEnd('\', '/')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$SettingsFile = Join-Path $ScriptDir 'settings.json'
$XamlFile = Join-Path $ScriptDir 'settings-window.xaml'

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

function Save-OverlayUi($ui) {
    $ui | ConvertTo-Json -Depth 8 | Set-Content -Path $OverlayUiFile -Encoding UTF8
}

function Get-SafeFileName([string]$Name) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = $Name.Trim()
    foreach ($ch in $invalid) {
        $safe = $safe.Replace([string]$ch, '_')
    }
    $safe = $safe -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'character' }
    return $safe
}

function Ensure-OverlayUiDefaults {
    if (-not (Test-Path $OverlayUiFile)) {
        $defaultUi = [pscustomobject]@{
            hide           = 'Hide'
            close          = 'Exit'
            switch         = 'Switch'
            show           = 'Show'
            title          = 'Monitor'
            noImages       = 'No images in characters folder.'
            clickLines     = @()
            characterLines = [pscustomobject]@{}
            characterNames = [pscustomobject]@{}
        }
        Save-OverlayUi $defaultUi
        return $defaultUi
    }

    try {
        $ui = Get-Content $OverlayUiFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $ui.PSObject.Properties.Match('clickLines').Count) { $ui | Add-Member NoteProperty clickLines @() }
        if (-not $ui.PSObject.Properties.Match('characterLines').Count) { $ui | Add-Member NoteProperty characterLines @{} }
        if (-not $ui.PSObject.Properties.Match('characterNames').Count) { $ui | Add-Member NoteProperty characterNames @{} }
        return $ui
    } catch {
        return [pscustomobject]@{ clickLines=@(); characterLines=[pscustomobject]@{}; characterNames=[pscustomobject]@{} }
    }
}

function Get-CharacterEntries {
    param($UiData)

    $entries = @()
    if (Test-Path $CharactersDir) {
        foreach ($file in Get-ChildItem $CharactersDir -File -ErrorAction SilentlyContinue) {
            $ext = $file.Extension.ToLowerInvariant()
            if ($ext -notin '.png', '.jpg', '.jpeg', '.gif', '.bmp') { continue }
            $display = $file.BaseName
            if ($UiData -and $UiData.characterNames -and $UiData.characterNames.PSObject.Properties.Name -contains $file.Name) {
                $display = [string]$UiData.characterNames.PSObject.Properties[$file.Name].Value
            }
            $entries += [pscustomobject]@{
                File = $file.Name
                Display = $display
            }
        }
    }
    return $entries
}

$settings = Read-Settings

$xaml = Get-Content $XamlFile -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$chkAutoStart   = $window.FindName('ChkAutoStart')
$chkShowOverlay = $window.FindName('ChkShowOverlay')
$btnAddChar     = $window.FindName('BtnAddCharacter')
$btnAddReply    = $window.FindName('BtnAddReply')
$btnSave        = $window.FindName('BtnSave')
$btnCancel      = $window.FindName('BtnCancel')
$statusText     = $window.FindName('StatusText')

$chkAutoStart.IsChecked   = $settings.AutoStartEnabled
$chkShowOverlay.IsChecked = $settings.ShowOverlayByDefault

$InstallScript = Join-Path $ScriptDir 'Install-StartupMonitor.ps1'
$UninstallScript = Join-Path $ScriptDir 'Uninstall-StartupMonitor.ps1'
$CharactersDir = Join-Path $ScriptDir 'characters'
$OverlayUiFile = Join-Path $ScriptDir 'overlay-ui.json'

function Show-Status($Msg) { $statusText.Text = $Msg }

function Invoke-AdminScript($ScriptPath) {
    try {
        $proc = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ScriptPath`""
        )
        return $proc.ExitCode -eq 0
    } catch { return $false }
}

$btnAddChar.Add_Click({
    $fd = New-Object Microsoft.Win32.OpenFileDialog
    $fd.Title = '选择角色图片'
    $fd.Filter = '图片文件|*.png;*.jpg;*.jpeg;*.gif;*.bmp|所有文件|*.*'
    $fd.Multiselect = $false
    if ($fd.ShowDialog() -eq $true) {
        $nameWin = New-Object System.Windows.Window
        $nameWin.Title = '命名角色'
        $nameWin.Width = 360
        $nameWin.Height = 180
        $nameWin.WindowStartupLocation = 'CenterOwner'
        $nameWin.Owner = $window
        $nameWin.ResizeMode = 'NoResize'
        $nameWin.Background = '#F5F6FA'
        $nameWin.FontFamily = 'Microsoft YaHei UI'

        $namePanel = New-Object System.Windows.Controls.StackPanel
        $namePanel.Margin = New-Object System.Windows.Thickness 20,15,20,15

        $nameLabel = New-Object System.Windows.Controls.TextBlock
        $nameLabel.Text = '输入角色名称：'
        $nameLabel.FontSize = 13
        $nameLabel.Foreground = '#2D3436'
        $nameLabel.Margin = New-Object System.Windows.Thickness 0,0,0,10
        $namePanel.AddChild($nameLabel) | Out-Null

        $nameBox = New-Object System.Windows.Controls.TextBox
        $nameBox.FontSize = 13
        $nameBox.Height = 28
        $nameBox.Margin = New-Object System.Windows.Thickness 0,0,0,12
        $namePanel.AddChild($nameBox) | Out-Null

        $nameButtons = New-Object System.Windows.Controls.StackPanel
        $nameButtons.Orientation = 'Horizontal'
        $nameButtons.HorizontalAlignment = 'Right'

        $nameCancel = New-Object System.Windows.Controls.Button
        $nameCancel.Content = '取消'
        $nameCancel.Width = 60
        $nameCancel.Height = 30
        $nameCancel.Margin = New-Object System.Windows.Thickness 0,0,8,0
        $nameCancel.Add_Click({ $nameWin.DialogResult = $false })

        $nameOk = New-Object System.Windows.Controls.Button
        $nameOk.Content = '确定'
        $nameOk.Width = 60
        $nameOk.Height = 30
        $nameOk.Add_Click({ $nameWin.DialogResult = $true })

        $nameButtons.AddChild($nameCancel) | Out-Null
        $nameButtons.AddChild($nameOk) | Out-Null
        $namePanel.AddChild($nameButtons) | Out-Null
        $nameWin.Content = $namePanel

        if ($nameWin.ShowDialog() -ne $true) { return }
        $customName = $nameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($customName)) { Show-Status '角色名称不能为空'; return }

        if (-not (Test-Path $CharactersDir)) {
            New-Item -ItemType Directory -Path $CharactersDir -Force | Out-Null
        }

        $uiData = Ensure-OverlayUiDefaults
        $safeBase = Get-SafeFileName $customName
        $ext = [System.IO.Path]::GetExtension($fd.FileName)
        $destName = "$safeBase$ext"
        $dest = Join-Path $CharactersDir $destName
        $suffix = 1
        while (Test-Path $dest) {
            $destName = "${safeBase}_$suffix$ext"
            $dest = Join-Path $CharactersDir $destName
            $suffix++
        }

        try {
            Copy-Item -LiteralPath $fd.FileName -Destination $dest -Force
            if (-not $uiData.characterNames) { $uiData | Add-Member NoteProperty characterNames ([pscustomobject]@{}) }
            if (-not $uiData.characterLines) { $uiData | Add-Member NoteProperty characterLines ([pscustomobject]@{}) }
            $uiData.characterNames | Add-Member -Force -NotePropertyName $destName -NotePropertyValue $customName
            if (-not ($uiData.characterLines.PSObject.Properties.Name -contains $destName)) {
                $uiData.characterLines | Add-Member -Force -NotePropertyName $destName -NotePropertyValue @()
            }
            Save-OverlayUi $uiData
            Show-Status "已添加角色：$customName"
        }
        catch {
            Show-Status "添加失败：$($_.Exception.Message)"
        }
    }
})

$btnAddReply.Add_Click({
    $uiData = Ensure-OverlayUiDefaults
    $chars = Get-CharacterEntries -UiData $uiData
    if ($chars.Count -eq 0) { Show-Status '请先添加角色图片'; return }

    $selectWin = New-Object System.Windows.Window
    $selectWin.Title = '选择角色'
    $selectWin.Width = 360
    $selectWin.Height = 330
    $selectWin.WindowStartupLocation = 'CenterOwner'
    $selectWin.Owner = $window
    $selectWin.ResizeMode = 'NoResize'
    $selectWin.Background = '#F5F6FA'
    $selectWin.FontFamily = 'Microsoft YaHei UI'

    $selectPanel = New-Object System.Windows.Controls.StackPanel
    $selectPanel.Margin = New-Object System.Windows.Thickness 20,15,20,15

    $selectLabel = New-Object System.Windows.Controls.TextBlock
    $selectLabel.Text = '选择要设置台词的角色：'
    $selectLabel.FontSize = 13
    $selectLabel.Margin = New-Object System.Windows.Thickness 0,0,0,10
    $selectPanel.AddChild($selectLabel) | Out-Null

    $list = New-Object System.Windows.Controls.ListBox
    $list.FontSize = 13
    $list.Height = 190
    $list.Margin = New-Object System.Windows.Thickness 0,0,0,12
    foreach ($ch in $chars) {
        [void]$list.Items.Add($ch.Display)
    }
    $list.SelectedIndex = 0
    $selectPanel.AddChild($list) | Out-Null

    $selectButtons = New-Object System.Windows.Controls.StackPanel
    $selectButtons.Orientation = 'Horizontal'
    $selectButtons.HorizontalAlignment = 'Right'

    $selectCancel = New-Object System.Windows.Controls.Button
    $selectCancel.Content = '取消'
    $selectCancel.Width = 60
    $selectCancel.Height = 30
    $selectCancel.Margin = New-Object System.Windows.Thickness 0,0,8,0
    $selectCancel.Add_Click({ $selectWin.DialogResult = $false })

    $selectOk = New-Object System.Windows.Controls.Button
    $selectOk.Content = '下一步'
    $selectOk.Width = 70
    $selectOk.Height = 30
    $selectOk.Add_Click({ $selectWin.DialogResult = $true })

    $selectButtons.AddChild($selectCancel) | Out-Null
    $selectButtons.AddChild($selectOk) | Out-Null
    $selectPanel.AddChild($selectButtons) | Out-Null
    $selectWin.Content = $selectPanel

    if ($selectWin.ShowDialog() -ne $true -or $list.SelectedIndex -lt 0) { return }
    $selected = $chars[$list.SelectedIndex].File

    $existingLines = @()
    if ($uiData.characterLines -and ($uiData.characterLines.PSObject.Properties.Name -contains $selected)) {
        $raw = $uiData.characterLines.PSObject.Properties[$selected].Value
        if ($raw -is [System.Array]) {
            $existingLines = @($raw)
        } elseif ($null -ne $raw) {
            $existingLines = @($raw)
        }
    } elseif ($uiData.clickLines) {
        $existingLines = @($uiData.clickLines)
    }

    $editWin = New-Object System.Windows.Window
    $editWin.Title = "设置台词 - $($chars[$list.SelectedIndex].Display)"
    $editWin.Width = 420
    $editWin.Height = 330
    $editWin.WindowStartupLocation = 'CenterOwner'
    $editWin.Owner = $window
    $editWin.ResizeMode = 'NoResize'
    $editWin.Background = '#F5F6FA'
    $editWin.FontFamily = 'Microsoft YaHei UI'

    $editPanel = New-Object System.Windows.Controls.StackPanel
    $editPanel.Margin = New-Object System.Windows.Thickness 20,15,20,15

    $editLabel = New-Object System.Windows.Controls.TextBlock
    $editLabel.Text = '每行一条，点击悬浮窗时随机显示：'
    $editLabel.FontSize = 12
    $editLabel.Foreground = '#666666'
    $editLabel.Margin = New-Object System.Windows.Thickness 0,0,0,8
    $editPanel.AddChild($editLabel) | Out-Null

    $editBox = New-Object System.Windows.Controls.TextBox
    $editBox.FontSize = 13
    $editBox.Height = 170
    $editBox.TextWrapping = 'Wrap'
    $editBox.AcceptsReturn = $true
    $editBox.VerticalScrollBarVisibility = 'Auto'
    $editBox.Margin = New-Object System.Windows.Thickness 0,0,0,12
    $editBox.Text = ($existingLines -join "`r`n")
    $editPanel.AddChild($editBox) | Out-Null

    $editButtons = New-Object System.Windows.Controls.StackPanel
    $editButtons.Orientation = 'Horizontal'
    $editButtons.HorizontalAlignment = 'Right'

    $editCancel = New-Object System.Windows.Controls.Button
    $editCancel.Content = '取消'
    $editCancel.Width = 60
    $editCancel.Height = 30
    $editCancel.Margin = New-Object System.Windows.Thickness 0,0,8,0
    $editCancel.Add_Click({ $editWin.DialogResult = $false })

    $editOk = New-Object System.Windows.Controls.Button
    $editOk.Content = '保存'
    $editOk.Width = 60
    $editOk.Height = 30
    $editOk.Add_Click({ $editWin.DialogResult = $true })

    $editButtons.AddChild($editCancel) | Out-Null
    $editButtons.AddChild($editOk) | Out-Null
    $editPanel.AddChild($editButtons) | Out-Null
    $editWin.Content = $editPanel

    if ($editWin.ShowDialog() -eq $true) {
        $text = $editBox.Text.Trim()
        $lines = @()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $lines = @($text -split "`r`n|`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        try {
            if (-not $uiData.characterLines) { $uiData | Add-Member NoteProperty characterLines ([pscustomobject]@{}) }
            $uiData.characterLines | Add-Member -Force -NotePropertyName $selected -NotePropertyValue $lines
            Save-OverlayUi $uiData
            Show-Status "已保存 $($chars[$list.SelectedIndex].Display) 的台词"
        } catch {
            Show-Status "保存失败：$($_.Exception.Message)"
        }
    }
})

$btnSave.Add_Click({
    $settings.AutoStartEnabled = ($chkAutoStart.IsChecked -eq $true)
    $settings.ShowOverlayByDefault = ($chkShowOverlay.IsChecked -eq $true)
    $settings.FirstRunComplete = $true
    Save-Settings $settings

    if ($chkAutoStart.IsChecked) {
        Invoke-AdminScript -ScriptPath $InstallScript
        Show-Status '已启用开机自启动'
    } else {
        Invoke-AdminScript -ScriptPath $UninstallScript
        Show-Status '已关闭开机自启动'
    }
    Start-Sleep -Milliseconds 800
    $window.DialogResult = $true
})

$btnCancel.Add_Click({ $window.DialogResult = $false })

$window.Add_Closing({
    if (-not $window.DialogResult) { $window.DialogResult = $false }
})

[void]$window.ShowDialog()

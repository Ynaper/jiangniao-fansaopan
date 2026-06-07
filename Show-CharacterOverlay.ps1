#Requires -Version 5.1
param(
    [string] $ScriptDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $ScriptDir.Trim().Trim('"').TrimEnd('\', '/')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

$UiFile = Join-Path $ScriptDir 'overlay-ui.json'
$Ui = if (Test-Path $UiFile) {
    Get-Content $UiFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{
        hide     = 'Hide'
        close    = 'Exit'
        switch   = 'Switch'
        show     = 'Show'
        title    = 'Monitor'
        noImages = 'No images in characters folder.'
    }
}

function Ensure-DefaultCharacters {
    param([string] $CharactersDir)
    if (-not (Test-Path $CharactersDir)) {
        New-Item -ItemType Directory -Path $CharactersDir -Force | Out-Null
    }
    $existing = Get-ChildItem -Path $CharactersDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg', '.gif', '.bmp' }
    if ($existing.Count -gt 0) { return }

    $names = @('default-blue.png', 'default-pink.png')
    $colors = @([Drawing.Color]::FromArgb(255, 100, 149, 237), [Drawing.Color]::FromArgb(255, 255, 105, 180))
    for ($i = 0; $i -lt $names.Count; $i++) {
        $path = Join-Path $CharactersDir $names[$i]
        $bmp = New-Object Drawing.Bitmap 128, 128
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        $brush = New-Object Drawing.SolidBrush $colors[$i]
        $g.FillEllipse($brush, 10, 10, 108, 108)
        $g.FillEllipse([Drawing.Brushes]::White, 36, 42, 18, 22)
        $g.FillEllipse([Drawing.Brushes]::White, 74, 42, 18, 22)
        $g.FillEllipse([Drawing.Brushes]::Black, 42, 50, 8, 10)
        $g.FillEllipse([Drawing.Brushes]::Black, 80, 50, 8, 10)
        $g.DrawArc([Drawing.Pens]::Black, 44, 68, 40, 24, 0, 180)
        $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        $brush.Dispose(); $g.Dispose(); $bmp.Dispose()
    }
}

function Get-CharacterImages {
    param([string] $CharactersDir)
    Get-ChildItem -Path $CharactersDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg', '.gif', '.bmp' } |
        Sort-Object Name
}

function Read-OverlayConfig {
    param([string] $ConfigFile)
    if (Test-Path $ConfigFile) {
        try { return Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ CharacterIndex = 0; Left = 100; Top = 100 }
}

function Save-OverlayConfig {
    param([string] $ConfigFile, [double] $Left, [double] $Top, [int] $CharacterIndex)
    $data = [ordered]@{
        CharacterIndex = $CharacterIndex
        Left           = [math]::Round($Left)
        Top            = [math]::Round($Top)
    }
    ($data | ConvertTo-Json) | Set-Content -Path $ConfigFile -Encoding UTF8
}

function Stop-MonitorProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Set-ProcessEfficiencyMonitor*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $pidFile = Join-Path $ScriptDir 'monitor.pid'
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
}

$CharactersDir = Join-Path $ScriptDir 'characters'
$ConfigFile = Join-Path $ScriptDir 'overlay-config.json'
Ensure-DefaultCharacters -CharactersDir $CharactersDir
$images = @(Get-CharacterImages -CharactersDir $CharactersDir)
if ($images.Count -eq 0) {
    [System.Windows.MessageBox]::Show($Ui.noImages, $Ui.title) | Out-Null
    exit 1
}

$config = Read-OverlayConfig -ConfigFile $ConfigFile
$script:CharacterIndex = [math]::Min([int]$config.CharacterIndex, $images.Count - 1)
if ($script:CharacterIndex -lt 0) { $script:CharacterIndex = 0 }

$clickLines = if ($Ui.clickLines -and $Ui.clickLines.Count -gt 0) {
    @($Ui.clickLines)
} else {
    @('...')
}

# Hardcoded runtime-only line so it cannot be edited through the overlay UI.
$script:InjectedPromoLine = '支持与建议：抖音搜索江鸟lab'
$script:InjectedPromoChancePercent = 1

# Per-character click lines: { "filename.png": ["line1","line2"] }
$characterLines = @{}
if ($Ui.characterLines) {
    foreach ($prop in $Ui.characterLines.PSObject.Properties) {
        $characterLines[$prop.Name] = @($prop.Value)
    }
}

function Get-CharacterClickLines {
    $fname = $images[$script:CharacterIndex].Name
    $custom = $null
    if ($characterLines.ContainsKey($fname)) {
        $custom = $characterLines[$fname]
    }
    if ($custom -and $custom.Count -gt 0) { return @($custom) }
    return $clickLines
}

function Get-BubbleText {
    $lines = Get-CharacterClickLines
    if ((Get-Random -Minimum 1 -Maximum 101) -le $script:InjectedPromoChancePercent) {
        return $script:InjectedPromoLine
    }
    if ($lines -and $lines.Count -gt 0) {
        return $lines | Get-Random
    }
    return '...'
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Overlay" Width="240" Height="260"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Grid>
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Bottom">
      <Border x:Name="Bubble" Background="#EEFFFFFF" CornerRadius="10" Padding="8,4"
              HorizontalAlignment="Center" Margin="0,0,0,4"
              Visibility="Collapsed" MaxWidth="220" MaxHeight="110">
        <ScrollViewer x:Name="BubbleScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                      MaxHeight="100" Padding="0">
          <TextBlock x:Name="BubbleText" TextWrapping="Wrap" FontSize="12" Foreground="#333333"
                     MaxWidth="200" HorizontalAlignment="Center" TextAlignment="Center"/>
        </ScrollViewer>
      </Border>
      <Image x:Name="CharacterImage" Width="128" Height="128"
             HorizontalAlignment="Center"
             RenderTransformOrigin="0.5,0.5" Cursor="Hand">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="CharacterScale" ScaleX="1" ScaleY="1"/>
            <TranslateTransform x:Name="CharacterOffset" Y="0"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = $Ui.title
$characterImage = $window.FindName('CharacterImage')
$bubble = $window.FindName('Bubble')
$bubbleScroll = $window.FindName('BubbleScroll')
$bubbleText = $window.FindName('BubbleText')
$characterScale = $window.FindName('CharacterScale')
$characterOffset = $window.FindName('CharacterOffset')

$script:IsDragging = $false
$script:DragStart = $null
$script:BubbleTimer = $null
$script:BubbleScrollTimer = $null
$script:BubbleScrollStep = 0.0
$script:NotifyIcon = $null

function Set-CharacterImage {
    $path = $images[$script:CharacterIndex].FullName
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = [Uri]$path
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $characterImage.Source = $bitmap
}

function Show-ClickBubble {
    $text = [string](Get-BubbleText)
    $bubbleText.Text = $text
    $bubble.Visibility = 'Visible'
    if ($script:BubbleTimer) { $script:BubbleTimer.Stop() }
    if ($script:BubbleScrollTimer) { $script:BubbleScrollTimer.Stop() }

    $bubbleScroll.ScrollToTop()
    $bubble.UpdateLayout()

    $hideBubble = {
        $bubble.Visibility = 'Collapsed'
        $script:BubbleTimer.Stop()
        if ($script:BubbleScrollTimer) { $script:BubbleScrollTimer.Stop() }
    }

    $script:BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BubbleTimer.Add_Tick($hideBubble)
    if ($bubbleScroll.ScrollableHeight -gt 0) {
        $script:BubbleScrollTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:BubbleScrollTimer.Interval = [TimeSpan]::FromMilliseconds(40)
        $script:BubbleScrollStep = [math]::Max(0.25, $bubbleScroll.ScrollableHeight / 260.0)
        $script:BubbleScrollTimer.Add_Tick({
            $nextOffset = [math]::Min($bubbleScroll.ScrollableHeight, $bubbleScroll.VerticalOffset + $script:BubbleScrollStep)
            $bubbleScroll.ScrollToVerticalOffset($nextOffset)
            if ($nextOffset -ge $bubbleScroll.ScrollableHeight) {
                $script:BubbleScrollTimer.Stop()
                $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds(1.8)
                $script:BubbleTimer.Start()
            }
        })
        $script:BubbleScrollTimer.Start()
    } else {
        $seconds = [math]::Min(8.0, [math]::Max(2.5, 2.5 + ($text.Length / 35.0)))
        $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds($seconds)
        $script:BubbleTimer.Start()
    }
}

function Stop-ClickAnimation {
    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $characterOffset.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
}

function Start-ClickPress {
    Stop-ClickAnimation
    $characterScale.ScaleX = 1.0
    $characterScale.ScaleY = 1.0
    $characterOffset.Y = 0.0

    $pressDuration = [TimeSpan]::FromMilliseconds(80)
    $pressEase = New-Object System.Windows.Media.Animation.QuadraticEase
    $pressEase.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $pressX = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pressX.To = 1.10
    $pressX.Duration = $pressDuration
    $pressX.EasingFunction = $pressEase

    $pressY = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pressY.To = 0.76
    $pressY.Duration = $pressDuration
    $pressY.EasingFunction = $pressEase

    $pressOffset = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pressOffset.To = 10.0
    $pressOffset.Duration = $pressDuration
    $pressOffset.EasingFunction = $pressEase

    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pressX)
    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pressY)
    $characterOffset.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $pressOffset)
}

function Play-ClickSquish {
    Stop-ClickAnimation
    $characterScale.ScaleX = 1.10
    $characterScale.ScaleY = 0.76
    $characterOffset.Y = 10.0

    $bounceDuration = [TimeSpan]::FromMilliseconds(620)

    $ease = New-Object System.Windows.Media.Animation.ElasticEase
    $ease.Oscillations = 2
    $ease.Springiness = 4
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $bounceX = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bounceX.To = 1.0
    $bounceX.Duration = $bounceDuration
    $bounceX.EasingFunction = $ease

    $bounceY = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bounceY.To = 1.0
    $bounceY.Duration = $bounceDuration
    $bounceY.EasingFunction = $ease

    $bounceOffset = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bounceOffset.To = 0.0
    $bounceOffset.Duration = $bounceDuration
    $bounceOffset.EasingFunction = $ease

    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $bounceX)
    $characterScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $bounceY)
    $characterOffset.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $bounceOffset)
    Show-ClickBubble
}

function Save-WindowConfig {
    Save-OverlayConfig -ConfigFile $ConfigFile -Left $window.Left -Top $window.Top -CharacterIndex $script:CharacterIndex
}

function Switch-Character {
    $script:CharacterIndex = ($script:CharacterIndex + 1) % $images.Count
    Set-CharacterImage
    Save-WindowConfig
    Play-ClickSquish
}

function Hide-Overlay {
    $window.Hide()
    if (-not $script:NotifyIcon) {
        $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:NotifyIcon.Icon = New-Object System.Drawing.Icon (Join-Path $ScriptDir "icon.ico")
        $script:NotifyIcon.Text = [string]$Ui.title
        $script:NotifyIcon.Visible = $true
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $showItem = $menu.Items.Add([string]$Ui.show)
        $switchItem = $menu.Items.Add([string]$Ui.switch)
        $exitItem = $menu.Items.Add([string]$Ui.close)
        $script:NotifyIcon.ContextMenuStrip = $menu
        $showItem.Add_Click({ $window.Show(); $window.Activate() })
        $switchItem.Add_Click({ Switch-Character })
        $exitItem.Add_Click({
            if ($script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
            Stop-MonitorProcesses
            $window.Dispatcher.Invoke([action]{ $window.Close() })
        })
        $script:NotifyIcon.Add_DoubleClick({ $window.Show(); $window.Activate() })
    }
}

function Close-App {
    Save-WindowConfig
    if ($script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
    Stop-MonitorProcesses
    $window.Close()
}

$contextMenu = New-Object System.Windows.Controls.ContextMenu
$hideItem = New-Object System.Windows.Controls.MenuItem; $hideItem.Header = [string]$Ui.hide
$switchItem = New-Object System.Windows.Controls.MenuItem; $switchItem.Header = [string]$Ui.switch
$closeItem = New-Object System.Windows.Controls.MenuItem; $closeItem.Header = [string]$Ui.close
$permHideItem = New-Object System.Windows.Controls.MenuItem; $permHideItem.Header = '永久隐藏悬浮窗（可在软件中重新打开）'
$sepItem = New-Object System.Windows.Controls.Separator
[void]$contextMenu.Items.Add($hideItem)
[void]$contextMenu.Items.Add($switchItem)
[void]$contextMenu.Items.Add($sepItem)
[void]$contextMenu.Items.Add($permHideItem)
[void]$contextMenu.Items.Add($closeItem)
$characterImage.ContextMenu = $contextMenu
$hideItem.Add_Click({ Hide-Overlay })
$switchItem.Add_Click({ Switch-Character })
$closeItem.Add_Click({ Close-App })
$permHideItem.Add_Click({
    Save-WindowConfig
    $settingsFile = Join-Path $ScriptDir 'settings.json'
    if (Test-Path $settingsFile) {
        try {
            $s = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $s.OverlayPermanentlyHidden = $true
            $s | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsFile -Encoding UTF8
        } catch {}
    }
    Close-App
})

$characterImage.Add_MouseLeftButtonDown({
    param($sender, $e)
    $script:IsDragging = $true
    $script:DragStart = $e.GetPosition($window)
    Start-ClickPress
    $sender.CaptureMouse() | Out-Null
})
$characterImage.Add_MouseLeftButtonUp({
    param($sender, $e)
    if ($script:IsDragging) {
        $end = $e.GetPosition($window)
        if ([math]::Abs($end.X - $script:DragStart.X) -lt 5 -and [math]::Abs($end.Y - $script:DragStart.Y) -lt 5) {
            Play-ClickSquish
        } else {
            Stop-ClickAnimation
            $characterScale.ScaleX = 1.0
            $characterScale.ScaleY = 1.0
            $characterOffset.Y = 0.0
            Save-WindowConfig
        }
    }
    $script:IsDragging = $false
    $sender.ReleaseMouseCapture() | Out-Null
})
$characterImage.Add_MouseMove({
    param($sender, $e)
    if (-not $script:IsDragging) { return }
    $pos = $e.GetPosition($window)
    $window.Left += $pos.X - $script:DragStart.X
    $window.Top += $pos.Y - $script:DragStart.Y
})
$window.Add_Closing({
    Save-WindowConfig
    if ($script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
})

$window.Left = [double]$config.Left
$window.Top = [double]$config.Top
Set-CharacterImage
[void]$window.ShowDialog()

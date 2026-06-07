#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$TaskName = 'ACE-Guard进程监测'
$ExePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '反扫盘.exe'
if (-not (Test-Path $ExePath)) { throw "找不到: $ExePath" }
$action = New-ScheduledTaskAction -Execute $ExePath -Argument '-Boot' -WorkingDirectory (Split-Path -Parent $ExePath)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Description '登录后启动反扫盘（EXE版）' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host ''
Write-Host '安装完成！' -ForegroundColor Green
Write-Host "  任务名称: $TaskName"
Write-Host "  程序路径: $ExePath"
Write-Host '  触发条件: 用户登录时自动启动'
Write-Host ''
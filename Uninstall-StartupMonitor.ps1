#Requires -RunAsAdministrator
#Requires -Version 5.1

$TaskName = 'ACE-Guard进程监测'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已卸载开机自启任务: $TaskName" -ForegroundColor Green
} else {
    Write-Host '未找到已安装的开机自启任务。' -ForegroundColor Yellow
}

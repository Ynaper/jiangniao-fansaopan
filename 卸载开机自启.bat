@echo off
chcp 65001 >nul
title ACE-Guard 监测 - 卸载开机自启

echo.
echo 正在请求管理员权限并卸载开机自启...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"%~dp0Uninstall-StartupMonitor.ps1\"\"'"

echo.
pause

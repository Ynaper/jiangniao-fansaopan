@echo off
chcp 65001 >nul
title ACE-Guard 监测 - 安装开机自启

echo.
echo 正在请求管理员权限并安装开机自启...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"%~dp0Install-StartupMonitor.ps1\"\"'"

echo.
pause

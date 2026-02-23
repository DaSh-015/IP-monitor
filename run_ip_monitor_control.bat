@echo off
setlocal
powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0ip_monitor_control.ps1"
endlocal

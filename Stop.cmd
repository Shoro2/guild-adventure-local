@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\control.ps1" -Action Stop %*
pause

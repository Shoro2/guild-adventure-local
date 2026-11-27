@echo off
rem Guild Adventure: one-click installer. See README.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\install.ps1" %*
if errorlevel 1 echo. & echo Installation stopped with an error. Run Install.cmd again to go on where it stopped.
pause

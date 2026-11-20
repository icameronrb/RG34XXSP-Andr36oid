@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Card-v45.ps1" %*
pause

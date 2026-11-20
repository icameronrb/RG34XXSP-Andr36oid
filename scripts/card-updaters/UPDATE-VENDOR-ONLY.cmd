@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Vendor-Only.ps1" %*
pause

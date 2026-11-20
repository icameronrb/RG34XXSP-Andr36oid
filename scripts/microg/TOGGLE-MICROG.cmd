@echo off
title RG34XX SP - microG Google Services Toggle
echo =========================================================
echo   RG34XX SP - microG Google Services On-Demand Toggle
echo =========================================================
echo.
echo   [1] Check microG Status
echo   [2] ENABLE microG Google Services (Turn ON)
echo   [3] DISABLE microG Google Services (Turn OFF - 0 MB RAM)
echo   [4] Reinstall microG APKs
echo   [5] Exit
echo.
set /p choice=Choose an option (1-5): 

if "%choice%"=="1" powershell -ExecutionPolicy Bypass -File "%~dp0Install-And-Toggle-microG.ps1" -Action Status
if "%choice%"=="2" powershell -ExecutionPolicy Bypass -File "%~dp0Install-And-Toggle-microG.ps1" -Action Enable
if "%choice%"=="3" powershell -ExecutionPolicy Bypass -File "%~dp0Install-And-Toggle-microG.ps1" -Action Disable
if "%choice%"=="4" powershell -ExecutionPolicy Bypass -File "%~dp0Install-And-Toggle-microG.ps1" -Action Install
if "%choice%"=="5" exit /b 0

echo.
pause

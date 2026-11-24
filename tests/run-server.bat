@echo off
setlocal
cd /d "%~dp0.."
echo.
echo ================================================
echo   SCALPING EDGE - SERVIDOR
echo ================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\start.ps1"
pause
@echo off
setlocal
cd /d "%~dp0.."
echo.
echo ================================================
echo   SCALPING EDGE - TESTES
echo ================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -Force; Invoke-Pester -Path '.\tests\AnalysisContract.Tests.ps1'"
echo.
pause
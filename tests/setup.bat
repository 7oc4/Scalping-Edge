@echo off
setlocal
cd /d "%~dp0.."
echo.
echo ================================================
echo   SCALPING EDGE - SETUP AUTOMATIZADO
echo ================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\setup.ps1"
echo.
if errorlevel 1 (
  echo [FALHOU] Veja os erros acima.
) else (
  echo [CONCLUIDO] Tudo pronto.
)
echo.
pause
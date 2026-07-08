@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nettoyer_Chaines_TURKTV.ps1"
echo.
pause

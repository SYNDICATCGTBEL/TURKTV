@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tester_Lecteur_TURKTV.ps1"
echo.
pause

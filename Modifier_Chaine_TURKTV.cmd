@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Modifier_Chaine_TURKTV.ps1"
echo.
pause

@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verifier_Chaines_TURKTV.ps1"
echo.
pause

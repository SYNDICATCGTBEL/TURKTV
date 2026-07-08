@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TURKTV_Studio.ps1"
if errorlevel 1 (
  echo.
  echo TURKTV Studio n'a pas pu demarrer. Une erreur est affichee ci-dessus.
  echo.
  pause
)

@echo off
setlocal
cd /d "%~dp0"

echo ===================================================
echo               TURKTV STUDIO
echo ===================================================
echo.
choice /C ON /M "Voulez-vous verifier et nettoyer les chaines avant de demarrer ?"
if errorlevel 2 goto start_studio
if errorlevel 1 goto verify

:verify
echo.
echo [1/2] Verification des liens (cela peut prendre quelques minutes)...
python "%~dp0checker.py"
echo.
echo [2/2] Nettoyage, suppression des doublons et creation de la playlist finale...
python "%~dp0combine.py"
echo.
echo Verification terminee avec succes !
echo ===================================================
echo.

:start_studio
echo Lancement de TURKTV Studio...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TURKTV_Studio.ps1"
if errorlevel 1 (
  echo.
  echo TURKTV Studio n'a pas pu demarrer. Une erreur est affichee ci-dessus.
  echo.
  pause
)

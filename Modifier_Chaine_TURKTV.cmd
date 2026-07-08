@echo off
setlocal
cd /d "%~dp0"

:menu
cls
echo TURKTV
echo.
echo 1 - Modifier le lien ou l'image d'une chaine
echo 2 - Verifier les chaines qui ne fonctionnent pas
echo 3 - Nettoyer la playlist avec le dernier rapport
echo 4 - Quitter
echo.
set /p choix=Votre choix : 

if "%choix%"=="1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Modifier_Chaine_TURKTV.ps1"
if "%choix%"=="2" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verifier_Chaines_TURKTV.ps1"
if "%choix%"=="3" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nettoyer_Chaines_TURKTV.ps1"
if "%choix%"=="4" goto fin

echo.
pause
goto menu

:fin

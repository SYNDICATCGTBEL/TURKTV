@echo off
setlocal
cd /d "%~dp0"

:menu
cls
echo TURKTV
echo.
echo 1 - Ouvrir TURKTV Studio visuel
echo 2 - Modifier le lien ou l'image d'une chaine
echo 3 - Verifier les chaines qui ne fonctionnent pas
echo 4 - Nettoyer la playlist avec le dernier rapport
echo 5 - Importer les chaines absentes de index.m3u
echo 6 - Tester une chaine dans un lecteur
echo 7 - Quitter
echo.
set /p choix=Votre choix : 

if "%choix%"=="1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TURKTV_Studio.ps1"
if "%choix%"=="2" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Modifier_Chaine_TURKTV.ps1"
if "%choix%"=="3" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verifier_Chaines_TURKTV.ps1"
if "%choix%"=="4" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nettoyer_Chaines_TURKTV.ps1"
if "%choix%"=="5" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Importer_Index_TURKTV.ps1"
if "%choix%"=="6" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tester_Lecteur_TURKTV.ps1"
if "%choix%"=="7" goto fin

echo.
pause
goto menu

:fin

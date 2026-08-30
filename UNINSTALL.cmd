@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "UNINSTALL_SCRIPT=%~dp0scripts\uninstall.ps1"

if not exist "%UNINSTALL_SCRIPT%" (
  echo Uninstall files are incomplete: scripts\uninstall.ps1 was not found.
  pause
  exit /b 2
)

cd /d "%TEMP%"
powershell.exe -NoLogo -NoProfile -File "%UNINSTALL_SCRIPT%"
set "UNINSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%UNINSTALL_EXIT%"=="0" (
  echo Coremail Controller was disabled successfully.
) else (
  echo Uninstall stopped with exit code %UNINSTALL_EXIT%.
)
pause
exit /b %UNINSTALL_EXIT%

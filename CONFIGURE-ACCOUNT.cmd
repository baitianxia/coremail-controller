@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

if not exist "%~dp0scripts\configure-account.ps1" (
  echo Configuration files are incomplete: scripts\configure-account.ps1 was not found.
  pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -File "%~dp0scripts\configure-account.ps1"
set "CONFIGURE_EXIT=%ERRORLEVEL%"

echo.
if "%CONFIGURE_EXIT%"=="0" (
  echo Coremail account configuration completed.
) else (
  echo Account configuration stopped with exit code %CONFIGURE_EXIT%.
)
pause
exit /b %CONFIGURE_EXIT%

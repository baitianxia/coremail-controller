@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

if not exist "%~dp0scripts\configure-account.ps1" (
  echo Configuration files are incomplete: scripts\configure-account.ps1 was not found.
  pause
  exit /b 2
)

set "COREMAIL_LOG_DIR=%TEMP%\CoremailController"
if not exist "%COREMAIL_LOG_DIR%" mkdir "%COREMAIL_LOG_DIR%"
set "COREMAIL_LAUNCH_LOG=%COREMAIL_LOG_DIR%\CONFIGURE-%RANDOM%-%RANDOM%.log"
powershell.exe -NoLogo -NoProfile -File "%~dp0scripts\configure-account.ps1" -LogPath "%COREMAIL_LAUNCH_LOG%"
set "CONFIGURE_EXIT=%ERRORLEVEL%"

echo.
if "%CONFIGURE_EXIT%"=="0" (
  echo Coremail account configuration completed.
) else (
  echo Account configuration stopped with exit code %CONFIGURE_EXIT%.
  if exist "%COREMAIL_LAUNCH_LOG%" powershell.exe -NoLogo -NoProfile -Command "Get-Content -LiteralPath $env:COREMAIL_LAUNCH_LOG -Tail 40"
)
echo Diagnostic log: %COREMAIL_LAUNCH_LOG%
pause
exit /b %CONFIGURE_EXIT%

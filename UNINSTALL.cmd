@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "UNINSTALL_SCRIPT=%~dp0scripts\uninstall.ps1"

if not exist "%UNINSTALL_SCRIPT%" (
  echo Uninstall files are incomplete: scripts\uninstall.ps1 was not found.
  pause
  exit /b 2
)

cd /d "%TEMP%"
set "COREMAIL_LOG_DIR=%TEMP%\CoremailController"
if not exist "%COREMAIL_LOG_DIR%" mkdir "%COREMAIL_LOG_DIR%"
set "COREMAIL_LAUNCH_LOG=%COREMAIL_LOG_DIR%\UNINSTALL-%RANDOM%-%RANDOM%.log"
powershell.exe -NoLogo -NoProfile -File "%UNINSTALL_SCRIPT%" -LogPath "%COREMAIL_LAUNCH_LOG%"
set "UNINSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%UNINSTALL_EXIT%"=="0" (
  echo Coremail Controller was disabled successfully.
) else (
  echo Uninstall stopped with exit code %UNINSTALL_EXIT%.
  if exist "%COREMAIL_LAUNCH_LOG%" powershell.exe -NoLogo -NoProfile -Command "Get-Content -LiteralPath $env:COREMAIL_LAUNCH_LOG -Tail 40"
)
echo Diagnostic log: %COREMAIL_LAUNCH_LOG%
pause
exit /b %UNINSTALL_EXIT%

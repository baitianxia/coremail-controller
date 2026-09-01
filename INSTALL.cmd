@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

if not exist "%~dp0scripts\install.ps1" (
  echo Installation files are incomplete: scripts\install.ps1 was not found.
  pause
  exit /b 2
)

echo Coremail Controller setup is starting...
set "COREMAIL_LOG_DIR=%TEMP%\CoremailController"
if not exist "%COREMAIL_LOG_DIR%" mkdir "%COREMAIL_LOG_DIR%"
set "COREMAIL_LAUNCH_LOG=%COREMAIL_LOG_DIR%\INSTALL-%RANDOM%-%RANDOM%.log"
powershell.exe -NoLogo -NoProfile -File "%~dp0scripts\install.ps1" -LogPath "%COREMAIL_LAUNCH_LOG%"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%INSTALL_EXIT%"=="0" (
  echo Coremail Controller setup completed.
) else (
  echo Setup stopped with exit code %INSTALL_EXIT%.
  echo Read the message above; existing mailbox data was not deleted.
  if exist "%COREMAIL_LAUNCH_LOG%" powershell.exe -NoLogo -NoProfile -Command "Get-Content -LiteralPath $env:COREMAIL_LAUNCH_LOG -Tail 40"
)
echo Diagnostic log: %COREMAIL_LAUNCH_LOG%
pause
exit /b %INSTALL_EXIT%

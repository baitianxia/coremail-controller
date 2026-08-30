@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

if not exist "%~dp0scripts\install.ps1" (
  echo Installation files are incomplete: scripts\install.ps1 was not found.
  pause
  exit /b 2
)

echo Coremail Controller setup is starting...
powershell.exe -NoLogo -NoProfile -File "%~dp0scripts\install.ps1"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%INSTALL_EXIT%"=="0" (
  echo Coremail Controller setup completed.
) else (
  echo Setup stopped with exit code %INSTALL_EXIT%.
  echo Read the message above; existing mailbox data was not deleted.
)
pause
exit /b %INSTALL_EXIT%

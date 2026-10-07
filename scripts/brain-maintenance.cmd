@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0brain-maintenance.ps1"
echo.
echo Exit code: %ERRORLEVEL%
pause

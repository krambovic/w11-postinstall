@echo off
setlocal
set "WPI_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "WPI_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%WPI_POWERSHELL%" -NoLogo -NoProfile -File "%~dp0Start.ps1" %*
exit /b %errorlevel%

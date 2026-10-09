@echo off
rem Language Profile launcher. Starts the GUI, or the CLI when parameters are given (e.g. -Preset Standard).
rem Uses 64-bit Windows PowerShell 5.1 even when started from a 32-bit process (Intune/SCCM).
setlocal
set "LP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "LP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%LP_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0LanguageProfile.ps1" %*
exit /b %ERRORLEVEL%

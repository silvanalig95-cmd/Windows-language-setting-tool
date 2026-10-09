@echo off
rem VM ONLY: registry diff for Language Profile. Double-click and pick a scenario.
set "LP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "LP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%LP_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Capture-RegistryDiff.ps1" %*

@echo off
where pwsh.exe >nul 2>nul
if %errorlevel% equ 0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0transcribe.ps1" %*
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0transcribe.ps1" %*
)

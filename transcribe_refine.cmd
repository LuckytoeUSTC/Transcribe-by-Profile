@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0transcribe_refine.ps1" %*

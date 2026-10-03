@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0transcribe_lecture.ps1" %*

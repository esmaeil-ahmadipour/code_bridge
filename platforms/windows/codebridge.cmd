@echo off
rem dw v2 launcher (CMD / PowerShell)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dw-core.ps1" %*
exit /b %ERRORLEVEL%

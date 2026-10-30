@echo off
rem Double-click me: applies diff.txt (next to this file) to the repo written on its first line.
call "%~dp0dw.cmd" %*
echo.
pause

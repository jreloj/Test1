@echo off
title PowerRename
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PowerRename.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  Something went wrong. Error code: %ERRORLEVEL%
    echo.
    pause
)

@echo off
setlocal
title PC cleanup and optimization
cd /d "%~dp0"

rem Administrator rights are required for cleanup and system settings
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="elevated" (
        echo Could not get administrator rights.
        echo Right-click start.bat and choose "Run as administrator".
        pause
        exit /b 1
    )
    echo Requesting administrator rights...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\menu.ps1"
endlocal

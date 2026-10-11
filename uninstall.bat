@echo off
setlocal enabledelayedexpansion

:: Self-elevate: the scheduled task was registered elevated, so removing it needs admin too
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Define ANSI Colors
set "ESC= "
set "Green=!ESC![92m"
set "Cyan=!ESC![96m"
set "Yellow=!ESC![93m"
set "Red=!ESC![91m"
set "Gray=!ESC![90m"
set "Reset=!ESC![0m"

cls
echo.
echo !Cyan!========================================================!Reset!
echo !Cyan!   Developer Junk Files Cleaner - Uninstall!Reset!
echo !Cyan!========================================================!Reset!
echo.
echo !Gray!This will cleanly remove Developer Junk Cleaner from Windows Startup,!Reset!
echo !Gray!Apps list, and task registries. Your code will remain untouched.!Reset!
echo.

set /p confirm="Are you sure you want to uninstall? (Y/N): "
if /i not "!confirm!"=="Y" (
    echo Uninstallation cancelled. Exiting.
    exit /b 0
)

echo.
echo !Cyan!Uninstalling configurations and active registry integrations...!Reset!
powershell -ExecutionPolicy Bypass -File "%~dp0auto_delete_junk_files.ps1" -Uninstall

echo.
echo !Cyan!========================================================!Reset!
echo !Green!   Uninstall Complete!!Reset!
echo !Cyan!========================================================!Reset!
echo.
echo    !Green!The program has been cleanly removed from startup and registries.!Reset!
echo    !Green!You can now safely delete this folder to complete removal.!Reset!
echo.
pause

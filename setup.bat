@echo off
setlocal enabledelayedexpansion

:: Self-elevate: one UAC prompt so the daily scheduled task can be registered elevated
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
echo !Cyan!   Developer Junk Files Cleaner - Native Setup!Reset!
echo !Cyan!========================================================!Reset!
echo.
echo !Gray!This setup will register the tool in Windows Startup and!Reset!
echo !Gray!add an entry in the Windows "Apps ^& Features" Control Panel.!Reset!
echo.

:: -------------------------------------------------------------
:: Step 1: Check PowerShell Availability
:: -------------------------------------------------------------
echo !Cyan![1/3] Checking native PowerShell availability...!Reset!
where powershell >nul 2>&1
if errorlevel 1 (
    echo !Red![ERROR] PowerShell was not found in your system PATH.!Reset!
    echo Please make sure Windows PowerShell is installed.
    pause
    exit /b 1
)
echo    !Green![OK] PowerShell detected.!Reset!
echo.

:: -------------------------------------------------------------
:: Step 2: Register Installer Registry & Startup Link
:: -------------------------------------------------------------
echo !Cyan![2/3] Installing files and writing system configurations...!Reset!
powershell -ExecutionPolicy Bypass -File "%~dp0auto_delete_junk_files.ps1" -Install
if errorlevel 1 (
    echo !Red![ERROR] System integration failed. Please run setup.bat again.!Reset!
    pause
    exit /b 1
)
echo.

:: -------------------------------------------------------------
:: Step 3: Optional Verification Dry-Run
:: -------------------------------------------------------------
echo !Cyan![3/3] System integration successfully verified.!Reset!
echo.
set /p runtest="Show a read-only size report of what can be reclaimed now? (Y/N): "
if /i "!runtest!"=="Y" (
    echo.
    echo Scanning caches (read-only, nothing is deleted)...
    powershell -ExecutionPolicy Bypass -File "%~dp0auto_delete_junk_files.ps1" -Report
)

echo.
echo !Cyan!========================================================!Reset!
echo !Green!   Setup Complete!!Reset!
echo !Cyan!========================================================!Reset!
echo.
echo    !Green!The cleaner is now registered natively under Windows Startup!Reset!
echo    !Green!and listed in Windows Apps list as "Developer Junk Cleaner".!Reset!
echo.
echo    You can run it manually anytime using:
echo    powershell -ExecutionPolicy Bypass -File "%ProgramFiles%\DeveloperJunkCleaner\auto_delete_junk_files.ps1"
echo.
pause

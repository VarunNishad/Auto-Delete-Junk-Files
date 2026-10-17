@echo off
echo ========================================
echo  Auto Delete Junk Files - Uninstall
echo ========================================
echo.

:: Remove the daily scheduled task first (works even without Python)
echo Removing daily Task Scheduler job (if any)...
schtasks /Delete /F /TN AutoDeleteJunkFilesDaily >nul 2>&1

:: Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python is not installed or not in PATH.
    pause
    exit /b 1
)

:: Remove from startup
echo Removing from Windows startup...
python "%~dp0auto_delete_junk_files.py" --uninstall

echo.
echo ========================================
echo  Uninstall Complete!
echo ========================================
echo The script has been removed from startup and the daily task deleted.
echo You can delete this folder to fully remove the program.
echo.
pause

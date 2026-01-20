@echo off
setlocal enabledelayedexpansion

echo.
echo ========================================================
echo    Auto Delete Junk Files - Setup
echo ========================================================
echo.

:: ============================================================
:: STEP 1: Check Python Installation
:: ============================================================
echo [1/4] Checking Python installation...

where python >nul 2>&1
if errorlevel 1 (
    echo.
    echo ============================================================
    echo    ERROR: Python is not installed or not in PATH
    echo ============================================================
    echo.
    echo    To fix this:
    echo    1. Download Python from: https://python.org/downloads
    echo    2. During installation, CHECK "Add Python to PATH"
    echo    3. Restart this setup after installation
    echo.
    echo    If Python is installed but not in PATH:
    echo    1. Open Windows Settings ^> System ^> About
    echo    2. Click "Advanced system settings"
    echo    3. Click "Environment Variables"
    echo    4. Add Python's install path to the "Path" variable
    echo.
    pause
    exit /b 1
)

for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYTHON_VERSION=%%v
echo    [OK] Python %PYTHON_VERSION% found

:: ============================================================
:: STEP 2: Upgrade pip (prevents many installation issues)
:: ============================================================
echo.
echo [2/4] Upgrading pip...
python -m pip install --upgrade pip --quiet
if errorlevel 1 (
    echo    [WARNING] Could not upgrade pip, continuing anyway...
) else (
    echo    [OK] pip upgraded successfully
)

:: ============================================================
:: STEP 3: Install Dependencies
:: ============================================================
echo.
echo [3/4] Installing dependencies...
echo.

:: Install each package separately for better error handling
set INSTALL_FAILED=0

echo    Installing win10toast...
pip install win10toast --quiet
if errorlevel 1 (
    echo    [FAILED] win10toast installation failed
    set INSTALL_FAILED=1
) else (
    echo    [OK] win10toast installed
)

echo    Installing winshell...
pip install winshell --quiet
if errorlevel 1 (
    echo    [FAILED] winshell installation failed
    set INSTALL_FAILED=1
) else (
    echo    [OK] winshell installed
)

echo    Installing pywin32...
pip install pywin32 --quiet
if errorlevel 1 (
    echo    [FAILED] pywin32 installation failed
    set INSTALL_FAILED=1
) else (
    echo    [OK] pywin32 installed
    echo    Running post-install script...
    python -m pywin32_postinstall -install >nul 2>&1
)

if %INSTALL_FAILED%==1 (
    echo.
    echo ============================================================
    echo    ERROR: Some packages failed to install
    echo ============================================================
    echo.
    echo    Try these fixes:
    echo    1. Run Command Prompt as Administrator
    echo    2. Run: pip install --upgrade pip
    echo    3. Run: pip install -r requirements.txt
    echo.
    echo    For pywin32 issues specifically:
    echo    - pip uninstall pywin32
    echo    - pip install pywin32
    echo    - python -m pywin32_postinstall -install
    echo.
    pause
    exit /b 1
)

:: ============================================================
:: STEP 4: Verify Installation
:: ============================================================
echo.
echo [4/4] Verifying installation...
echo.

python "%~dp0auto_delete_junk_files.py" --test
if errorlevel 1 (
    echo.
    echo ============================================================
    echo    ERROR: Verification failed
    echo ============================================================
    echo.
    echo    The test did not pass. Check the error messages above
    echo    for specific troubleshooting steps.
    echo.
    pause
    exit /b 1
)

:: ============================================================
:: ASK: Add to Startup?
:: ============================================================
echo.
set /p addstartup="Add to Windows startup? (Y/N): "
if /i "%addstartup%"=="Y" (
    python "%~dp0auto_delete_junk_files.py" --install
    if errorlevel 1 (
        echo    [WARNING] Could not add to startup automatically.
        echo    You can try running this script as Administrator.
    )
)

echo.
echo ========================================================
echo    Setup Complete!
echo ========================================================
echo.
echo    The script will now run automatically when Windows starts.
echo    You can also run it manually anytime:
echo.
echo    python auto_delete_junk_files.py          (run cleanup)
echo    python auto_delete_junk_files.py --test   (test mode)
echo.
pause

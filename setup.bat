@echo off
setlocal EnableDelayedExpansion
title Auto Delete Junk Files - Setup
set "LOG=%~dp0setup_log.txt"
cd /d "%~dp0"

set "SCRIPT=%~dp0auto_delete_junk_files.py"
if not exist "%SCRIPT%" (
    echo ERROR: auto_delete_junk_files.py is missing next to setup.bat.
    echo Extract the whole folder before running setup.
    pause
    exit /b 1
)

:: ============================================================
::  Pinned versions / package ids (edit here if needed)
:: ============================================================
set "SCRIPT=%~dp0auto_delete_junk_files.py"
set "WINGET_ID_314=Python.Python.3.14"
set "WINGET_ID_ANY=Python.Python.3"
set "PYTHON_VER=3.14.7"
set "PYTHON_DL_URL=https://www.python.org/ftp/python/%PYTHON_VER%/python-%PYTHON_VER%-amd64.exe"

echo.
echo ========================================================
echo    Auto Delete Junk Files - Setup
echo ========================================================
echo.
call :log "=== setup started ==="

:: ============================================================
:: STEP 1/5: Ensure Python (auto-installs if missing)
:: ============================================================
echo [1/5] Checking for Python...

call :detect_python
if not defined PYEXE call :locate_installed
if not defined PYEXE (
    echo    Python not found - installing it automatically...
    echo    (this can take a few minutes, please wait^)
    call :install_winget
)
if not defined PYEXE call :install_direct

if not defined PYEXE (
    echo.
    echo ============================================================
    echo    ERROR: Could not install Python automatically
    echo ============================================================
    echo.
    echo    Please do this once by hand:
    echo    1. Open: https://www.python.org/downloads
    echo    2. Download the latest Python 3 installer
    echo    3. IMPORTANT: TICK the checkbox "Add python.exe to PATH"
    echo    4. Run this setup.bat again
    echo.
    echo    Details are in: setup_log.txt
    call :log "FATAL auto-install failed"
    pause
    exit /b 1
)

%PYEXE% --version
call :log "STEP1 OK interpreter=%PYEXE%"
echo    [OK] Python is ready

:: ============================================================
:: STEP 2/5: Upgrade pip
:: ============================================================
echo.
echo [2/5] Upgrading pip...
%PYEXE% -c "import pip" >nul 2>&1
if errorlevel 1 (
    echo    pip itself is missing - bootstrapping it with ensurepip...
    %PYEXE% -m ensurepip --upgrade
)
%PYEXE% -m pip install --upgrade pip --quiet
if errorlevel 1 (
    echo    Retrying with --user...
    %PYEXE% -m pip install --user --upgrade pip --quiet
)
if errorlevel 1 (
    echo    [WARNING] Could not upgrade pip - continuing anyway...
    call :log "STEP2 WARN pip upgrade failed"
) else (
    echo    [OK] pip is current
    call :log "STEP2 OK pip upgraded"
)

:: ============================================================
:: STEP 3/5: Install dependencies
:: ============================================================
echo.
echo [3/5] Installing dependencies...

set INSTALL_FAILED=0
:: NOTE: must quote %%R — without quotes, CALL splits at '=' and drops the pin
for /f "usebackq eol=# delims=" %%R in ("%~dp0requirements.txt") do call :package "%%R"
if not "%INSTALL_FAILED%"=="0" goto :deps_error

:: verify the imports really work (win10toast lesson: pip OK != import OK)
%PYEXE% -c "import winotify, winshell, win32com.client" 2>nul
if errorlevel 1 (
    echo    [FAIL] Packages installed but imports fail.
    echo    Run as Administrator once, or reinstall with:
    echo       pip uninstall pywin32 ^&^& pip install pywin32
    call :log "STEP3 FAIL import check"
    pause
    exit /b 1
)
:: optional pywin32 DLL registration (may need admin - tolerated failure)
%PYEXE% -m pywin32_postinstall -install >nul 2>&1
echo    [OK] All dependencies installed and importable
call :log "STEP3 OK deps+imports"

:: ============================================================
:: STEP 4/5: Verify installation (runs the updated v2 script)
:: ============================================================
echo.
echo [4/5] Verifying installation...
%PYEXE% "%SCRIPT%" --test
if errorlevel 1 (
    echo.
    call :log "STEP4 FAIL --test"
    echo ============================================================
    echo    ERROR: Verification failed - see messages above
    echo ============================================================
    pause
    exit /b 1
)
call :log "STEP4 OK verification"

:: ============================================================
:: STEP 5/5: Startup integration
:: ============================================================
echo.
echo [5/5] Integrate: startup, daily task, first run...
set TASK_INSTALLED=0
set /p addstartup="Add to Windows startup? (Y/N): "
if /i "%addstartup%"=="Y" (
    %PYEXE% "%SCRIPT%" --install
    if errorlevel 1 (
        echo    [WARNING] Could not add to startup automatically.
        echo    Try running this setup as Administrator.
        call :log "STEP5 WARN install"
    ) else (
        call :log "STEP5 OK startup installed"
    )
) else (
    echo    Skipped. You can add it later with:
    echo       %PYEXE% "%SCRIPT%" --install
)

echo.
set /p addtask="Also clean daily at 12:00 even if the PC stays on? (Y/N): "
if /i "%addtask%"=="Y" (
    %PYEXE% "%SCRIPT%" --install-task
    if errorlevel 1 (
        echo    [WARNING] Could not create the scheduled task.
        call :log "STEP5 WARN task"
    ) else (
        set TASK_INSTALLED=1
        call :log "STEP5 OK scheduled task"
    )
) else (
    echo    Skipped. You can add it later with:
    echo       %PYEXE% "%SCRIPT%" --install-task
)

echo.
set /p runnow="Run the first cleanup right now? (Y/N): "
if /i "%runnow%"=="Y" %PYEXE% "%SCRIPT%" --force
call :log "STEP5 first-cleanup answered=%runnow%"

echo.
set /p sysclean="Also clean Windows system folders now (1 Administrator/UAC click)? (Y/N): "
if /i "%sysclean%"=="Y" %PYEXE% "%SCRIPT%" --force --elevate
call :log "STEP5 elevate answered=%sysclean%"

echo.
echo ========================================================
echo    Setup Complete!
echo ========================================================
echo.
echo    The cleaner now runs at Windows startup (once a day).
if "%TASK_INSTALLED%"=="1" echo    It also runs daily at 12:00 via Task Scheduler, even without a restart.
echo    It also cleans dev-tool caches (pip, npm, VS Code, ...).
echo.
echo    Useful commands:
echo       python auto_delete_junk_files.py --dry-run    (peek, deletes nothing)
echo       python auto_delete_junk_files.py --elevate    (also system folders)
echo       python auto_delete_junk_files.py --deep       (include opt-in caches)
echo.
echo    Details of every step: setup_log.txt
echo.
call :log "=== setup finished OK ==="
pause
exit /b 0

:: ============================================================
:: Failed dependency block
:: ============================================================
:deps_error
echo.
echo ============================================================
echo    ERROR: Some packages failed to install
echo ============================================================
echo.
echo    Try:
echo      1. Check your internet connection
echo      2. Run this setup again
echo      3. Run Command Prompt as Administrator and run this setup
echo.
echo    Details: setup_log.txt
pause
exit /b 1

:: ============================================================
:: FUNCTIONS
:: ============================================================

:detect_python
set "PYEXE="
:: Guard every pipeline with 'where' first:
::  - running a NOT-FOUND command through "2>&1 | findstr" deadlocks CMD
::    forever when stdin is redirected (verified), so never do it blind
::  - the Microsoft Store "python" stub must never be executed
where py >nul 2>&1
if not errorlevel 1 (
    py -3 --version 2>&1 | findstr /b /c:"Python 3" >nul 2>&1
    if not errorlevel 1 (
        set "PYEXE=py -3"
        goto :eof
    )
)
where python >nul 2>&1
if not errorlevel 1 (
    set "PYPATH="
    for /f "delims=" %%P in ('where python') do if not defined PYPATH set "PYPATH=%%P"
    echo(!PYPATH!| findstr /i /c:"WindowsApps" >nul 2>&1
    if errorlevel 1 (
        python --version 2>&1 | findstr /b /c:"Python 3" >nul 2>&1
        if not errorlevel 1 (
            set "PYEXE=python"
            goto :eof
        )
    )
)
goto :eof

:: search well-known install folders (newest first) and fix PATH locally
:locate_installed
call :log "STEP1 python/py not on PATH - scanning common install dirs"
set "CAND="
for %%D in (
    "%LOCALAPPDATA%\Programs\Python\Python315"
    "%LOCALAPPDATA%\Programs\Python\Python314"
    "%LOCALAPPDATA%\Programs\Python\Python313"
    "%LOCALAPPDATA%\Programs\Python\Python312"
    "C:\Program Files\Python315"
    "C:\Program Files\Python314"
    "C:\Program Files\Python313"
    "C:\Program Files\Python312"
    "C:\Python314"
    "C:\Python313"
) do (
    if not defined CAND if exist "%%~D\python.exe" set "CAND=%%~D"
)
if defined CAND (
    echo    Found existing Python in: %CAND%
    echo    Fixing PATH for this session...
    set "PATH=%CAND%;%CAND%\Scripts;%PATH%"
    echo    %CAND%>>"%LOG%"
    call :detect_python
)
goto :eof

:install_winget
where winget >nul 2>&1
if errorlevel 1 (
    echo    winget not available on this PC - skipping.
    call :log "STEP1 winget missing"
    goto :eof
)
call :log "STEP1 winget install %WINGET_ID_314%"
echo    ^> winget install %WINGET_ID_314% (silent, per-user^)
winget install --id %WINGET_ID_314% --exact --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
if errorlevel 1 (
    echo    ^> Trying the generic Python package id...
    winget install --id %WINGET_ID_ANY% --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
)
call :attempt_detect
goto :eof

:install_direct
:: fallback for PCs without winget: official installer, silent per-user install
call :log "STEP1 direct download attempt %PYTHON_VER%"
set "DLDIR=%TEMP%\python-junk-setup"
if not exist "%DLDIR%" mkdir "%DLDIR%"
set "DLFILE=%DLDIR%\python-%PYTHON_VER%-amd64.exe"

echo    Downloading Python %PYTHON_VER% from python.org ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri '%PYTHON_DL_URL%' -OutFile '%DLFILE%' -UseBasicParsing; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo    [FAIL] Download failed (check internet connection^).
    call :log "STEP1 download failed"
    goto :eof
)
for /f %%S in ('powershell -NoProfile -Command "(Get-Item '%DLFILE%').Length"') do set "DLSIZE=%%S"
if %DLSIZE% LSS 20000000 (
    echo    [FAIL] Download incomplete.
    call :log "STEP1 download too small %DLSIZE%"
    goto :eof
)
echo    Installing silently (per-user, adds to PATH) - ~1-2 minutes...
"%DLFILE%" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_pip=1
if errorlevel 1 call :log "STEP1 installer exitcode!=0"
call :attempt_detect
if exist "%DLFILE%" del "%DLFILE%" >nul 2>&1
goto :eof

:: after an install: give Windows time, refresh PATH from registry, retry detection 3x
:attempt_detect
for %%N in (1 2 3) do (
    ping -n 3 127.0.0.1 >nul
    if not defined PYEXE (
        echo    Waiting for Windows to register the install... attempt %%N/3
        call :refresh_path
        call :detect_python
    )
)
goto :eof

:: merge machine + user PATH from registry into THIS session
:refresh_path
set "SYS_P="
set "USR_P="
for /f "tokens=2*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_P=%%b"
for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_P=%%b"
if defined SYS_P set "PATH=!SYS_P!;%PATH%"
if defined USR_P set "PATH=!USR_P!;%PATH%"
:: and the usual guessed locations (covers REG_EXPAND_SZ raw values)
set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Python\Python315;%LOCALAPPDATA%\Programs\Python\Python314;%LOCALAPPDATA%\Programs\Python\Python313;%LOCALAPPDATA%\Programs\Python\Launcher"
goto :eof

:: install one dependency, retry with --user on failure
:package
echo    Installing %~1...
%PYEXE% -m pip install %~1 --quiet
if errorlevel 1 (
    echo    Retrying %~1 with --user...
    %PYEXE% -m pip install %~1 --user --quiet
)
if errorlevel 1 (
    echo    [FAILED] %~1 installation failed
    set INSTALL_FAILED=1
    call :log "STEP3 FAIL %~1"
) else (
    echo    [OK] %~1 installed
    call :log "STEP3 OK %~1"
)
goto :eof

:: append a timestamped line to setup_log.txt
:log
(echo [%date% %time%] %~1)>>"%LOG%"
goto :eof

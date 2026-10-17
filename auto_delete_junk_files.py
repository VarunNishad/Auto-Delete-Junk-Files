"""
Auto Delete Junk Files — v2.0
=============================
Cleanly deletes temporary/junk files: Windows temp folders, dev-tool caches
(pip, npm, yarn, pnpm, electron, go, cargo, .NET ...), editor caches and
system folders (with optional elevation).

Runs once per day (logon trigger) and shows a toast notification with the
amount of freed space. Everything is logged to cleanup_log.txt.

Usage:
    python auto_delete_junk_files.py                # normal cleanup
    python auto_delete_junk_files.py --dry-run      # no deletion; what WOULD happen
    python auto_delete_junk_files.py --deep         # also opt-in caches (see targets.json)
    python auto_delete_junk_files.py --elevate      # relaunch elevated for system targets
    python auto_delete_junk_files.py --test         # dependency + permission check
    python auto_delete_junk_files.py --list-targets # show rules table
    python auto_delete_junk_files.py --install      # add to Windows startup
    python auto_delete_junk_files.py --uninstall    # remove from Windows startup
    python auto_delete_junk_files.py --install-task [HH:MM]  # daily Task Scheduler job
    python auto_delete_junk_files.py --uninstall-task        # remove that job
"""

import os
import sys
import json
import fnmatch
import argparse
import datetime
import re
import subprocess

# Make sure emoji/Unicode output never crashes on non-UTF-8 consoles
# (e.g. when output is redirected to a file or pipe). sys.stdout is None
# when the script runs silently via pythonw.exe, which is fine.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ICON_PATH = os.path.join(SCRIPT_DIR, "Icon", "Autodeleteicon.ico")
LAST_RUN_FILE = os.path.join(SCRIPT_DIR, "last_run.txt")
LOG_FILE = os.path.join(SCRIPT_DIR, "cleanup_log.txt")
REPORT_FILE = os.path.join(SCRIPT_DIR, "cleanup_report.json")
CONFIG_FILE = os.path.join(SCRIPT_DIR, "targets.json")
BATCH_FILE = os.path.join(SCRIPT_DIR, "run_silent.bat")
TASK_NAME = "AutoDeleteJunkFilesDaily"
LOCK_FILE = os.path.join(SCRIPT_DIR, "cleanup.lock")
MAX_LOG_LINES = 4000

# Never delete files inside these directory names (any target).
DEFAULT_EXCLUSIONS = ["opencode"]

# ---------------------------------------------------------------------------
# Default target catalog — written to targets.json on first run so users can
# edit it without touching the Python code.
# ---------------------------------------------------------------------------
E = "deep",
DEFAULT_TARGETS = {
    "exclusions_default": ["opencode"],
    "targets": [
        # --- Windows / OS ---
        {"id": "user_temp", "name": "User TEMP folder", "category": "os",
         "paths": ["%TEMP%"], "requires_admin": False, "min_age_days": 1,
         "default_enabled": True, "danger": "low"},
        {"id": "system_temp", "name": "Windows system temp", "category": "system",
         "paths": ["%SYSTEMROOT%\\Temp"], "requires_admin": True, "min_age_days": 1,
         "default_enabled": True, "danger": "low",
         "note": "Needs Administrator"},
        {"id": "windows_update", "name": "Windows Update downloads", "category": "system",
         "paths": ["%SYSTEMROOT%\\SoftwareDistribution\\Download"], "requires_admin": True,
         "min_age_days": 1, "default_enabled": True, "danger": "low",
         "note": "Needs Administrator — safe, Windows re-downloads when needed"},
        {"id": "user_wer", "name": "Windows Error Reports (user)", "category": "os",
         "paths": ["%LOCALAPPDATA%\\Microsoft\\Windows\\WER"], "requires_admin": False,
         "min_age_days": 7, "default_enabled": True, "danger": "low"},
        {"id": "system_wer", "name": "Windows Error Reports (all users)", "category": "system",
         "paths": ["%PROGRAMDATA%\\Microsoft\\Windows\\WER\\ReportQueue",
                   "%PROGRAMDATA%\\Microsoft\\Windows\\WER\\ReportArchive"],
         "requires_admin": True, "min_age_days": 7, "default_enabled": True, "danger": "low",
         "note": "Needs Administrator"},
        {"id": "inet_cache", "name": "Windows web cache (INetCache)", "category": "os",
         "paths": ["%LOCALAPPDATA%\\Microsoft\\Windows\\INetCache"], "requires_admin": False,
         "min_age_days": 7, "default_enabled": True, "danger": "low"},
        {"id": "crash_dumps", "name": "Application crash dumps", "category": "os",
         "paths": ["%LOCALAPPDATA%\\CrashDumps"], "requires_admin": False, "min_age_days": 7,
         "default_enabled": True, "danger": "low"},

        # --- Python ---
        {"id": "pip_cache", "name": "pip cache", "category": "python",
         "paths": ["%LOCALAPPDATA%\\pip\\cache", "~\\.cache\\pip"], "requires_admin": False,
         "min_age_days": 0, "default_enabled": True, "danger": "low"},
        {"id": "uv_cache", "name": "uv cache", "category": "python",
         "paths": ["%LOCALAPPDATA%\\uv\\cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "poetry_cache", "name": "Poetry cache", "category": "python",
         "paths": ["%LOCALAPPDATA%\\pypoetry\\Cache", "%LOCALAPPDATA%\\pypoetry\\cache"],
         "requires_admin": False, "min_age_days": 0, "default_enabled": True, "danger": "low"},

        # --- JavaScript / Node ---
        {"id": "npm_cache", "name": "npm cache", "category": "node",
         "paths": ["%LOCALAPPDATA%\\npm-cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "npm_legacy", "name": "npm legacy cache & logs", "category": "node",
         "paths": ["~\\.npm"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "yarn_cache", "name": "Yarn cache", "category": "node",
         "paths": ["%LOCALAPPDATA%\\Yarn\\Cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "pnpm_cache", "name": "pnpm cache & logs", "category": "node",
         "paths": ["%LOCALAPPDATA%\\pnpm-cache", "%LOCALAPPDATA%\\pnpm\\State",
                   "%LOCALAPPDATA%\\pnpm\\_logs"],
         "requires_admin": False, "min_age_days": 0, "default_enabled": True, "danger": "low"},
        {"id": "electron_cache", "name": "Electron download cache", "category": "node",
         "paths": ["%LOCALAPPDATA%\\electron\\Cache", "%LOCALAPPDATA%\\electron-builder\\Cache"],
         "requires_admin": False, "min_age_days": 0, "default_enabled": True, "danger": "low"},
        {"id": "cypress_cache", "name": "Cypress binary cache", "category": "node",
         "paths": ["%LOCALAPPDATA%\\Cypress\\Cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "bun_cache", "name": "Bun package cache", "category": "node",
         "paths": ["~\\.bun\\install\\cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "playwright_browsers", "name": "Playwright browser binaries", "category": "node",
         "paths": ["%LOCALAPPDATA%\\ms-playwright"], "requires_admin": False, "min_age_days": 30,
         "default_enabled": False, "danger": "med",
         "note": "Opt-in (--deep) — browsers re-download on next test run"},

        # --- .NET / Go / Rust / JVM ---
        {"id": "nuget_http_cache", "name": "NuGet http cache (metadata)", "category": "dotnet",
         "paths": ["%LOCALAPPDATA%\\NuGet\\v3-cache"], "requires_admin": False, "min_age_days": 0,
         "default_enabled": True, "danger": "low"},
        {"id": "nuget_packages", "name": "NuGet global package store", "category": "dotnet",
         "paths": ["~\\.nuget\\packages"], "requires_admin": False, "min_age_days": 30,
         "default_enabled": False, "danger": "med", "keep_root": True,
         "note": "Opt-in (--deep) — full re-download cost"},
        {"id": "go_build_cache", "name": "Go build cache", "category": "golang",
         "paths": ["%LOCALAPPDATA%\\go-build"], "requires_admin": False, "min_age_days": 7,
         "default_enabled": True, "danger": "low"},
        {"id": "cargo_cache", "name": "Cargo registry cache", "category": "rust",
         "paths": ["~\\.cargo\\registry\\cache"], "requires_admin": False, "min_age_days": 30,
         "default_enabled": False, "danger": "med", "note": "Opt-in (--deep)"},
        {"id": "gradle_caches", "name": "Gradle caches", "category": "jvm",
         "paths": ["~\\.gradle\\caches"], "requires_admin": False, "min_age_days": 30,
         "default_enabled": False, "danger": "med",
         "note": "Opt-in (--deep) — dependencies re-download (can be GBs, slow)"},

        # --- Editors / IDEs ---
        {"id": "vscode_cache", "name": "VS Code caches & logs", "category": "editor",
         "paths": ["%APPDATA%\\Code\\Cache", "%APPDATA%\\Code\\CachedData",
                   "%APPDATA%\\Code\\CachedExtensionVSIXs", "%APPDATA%\\Code\\logs",
                   "%APPDATA%\\Code\\Service Worker\\CacheStorage",
                   "%APPDATA%\\Code\\Code Cache"],
         "requires_admin": False, "min_age_days": 1, "default_enabled": True, "danger": "low",
         "note": "Locked parts are skipped and reported if VS Code is running"},
        {"id": "vscode_insiders_cache", "name": "VS Code Insiders caches & logs", "category": "editor",
         "paths": ["%APPDATA%\\Code - Insiders\\Cache", "%APPDATA%\\Code - Insiders\\CachedData",
                   "%APPDATA%\\Code - Insiders\\CachedExtensionVSIXs",
                   "%APPDATA%\\Code - Insiders\\logs"],
         "requires_admin": False, "min_age_days": 1, "default_enabled": True, "danger": "low"},
        {"id": "jetbrains_cache", "name": "JetBrains caches", "category": "editor",
         "paths": ["%LOCALAPPDATA%\\JetBrains"], "requires_admin": False, "min_age_days": 7,
         "default_enabled": True, "danger": "med", "keep_root": True, "custom": "jetbrains",
         "note": "Deletes only product caches/index/LocalHistory subfolders; "
                 "settings live in %APPDATA%\\JetBrains and are never touched"},
    ],
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def is_admin():
    """True if the current process has Administrator rights."""
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def fmt_size(num_bytes):
    for unit in ("B", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return f"{num_bytes:.0f} {unit}" if unit in ("B", "KB") else f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} GB"


def load_targets():
    """Load target list from targets.json, creating it from defaults on first run."""
    if not os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_TARGETS, f, indent=2)
        print(f"Created default configuration: {CONFIG_FILE}")
    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        config = json.load(f)
    return config.get("targets", []), config.get("exclusions_default", DEFAULT_EXCLUSIONS)


def safe_resolve(path_template):
    """
    Expand a target template and validate it against a whitelist of roots.

    Returns the resolved absolute path or None if the path is missing/unsafe.
    This protects users who edit targets.json from deleting real projects:
    only paths inside TEMP, LOCALAPPDATA, APPDATA, USERPROFILE, PROGRAMDATA
    or whitelisted subpaths of SYSTEMROOT are accepted.
    """
    raw = os.path.expandvars(os.path.expanduser(path_template))
    path = os.path.normpath(os.path.abspath(raw)).lower()
    roots = []
    for var in ("TEMP", "LOCALAPPDATA", "APPDATA", "USERPROFILE", "PROGRAMDATA"):
        value = os.path.expandvars(f"%{var}%")
        if value:
            roots.append(os.path.normpath(value).lower())
    system_roots = [
        os.path.normpath(os.path.expandvars(p)).lower() for p in (
            r"%SYSTEMROOT%\Temp", r"%SYSTEMROOT%\Prefetch",
            r"%SYSTEMROOT%\SoftwareDistribution",
            r"%SYSTEMROOT%\ServiceState\DeliveryOptimization",
        )
    ]
    for root in system_roots:
        if path == root or path.startswith(root + os.sep):
            return path
    for root in roots:
        if path == root or path.startswith(root + os.sep):
            return path
    print(f"        [REFUSED] unsafe path outside allowed roots: {path_template}")
    return None


def resolve_targets(targets):
    """Turn templates into real, validated, existing folder paths."""
    resolved, skipped = [], []
    for target in targets:
        for template in target.get("paths", []):
            path = safe_resolve(template)
            if path and os.path.isdir(path):
                resolved.append((target, path))
            else:
                skipped.append((target["id"], template))
    return resolved, skipped


def is_locked_error(exc):
    """Classify an OSError from a delete as 'in use' vs 'access denied'."""
    winerror = getattr(exc, "winerror", None)
    if winerror == 32:
        # WinError 32: file is in use by another process
        return True
    if isinstance(exc, PermissionError):
        return False  # WinError 5 etc. → genuinely denied
    return False


class Stat:
    """Deletion statistics accumulator (files vs folders counted separately)."""
    __slots__ = ("files", "dirs", "locked", "denied", "other", "bytes")

    def __init__(self):
        self.files = self.dirs = self.locked = self.denied = self.other = 0
        self.bytes = 0

    def add(self, other):
        for key in ("files", "dirs", "locked", "denied", "other", "bytes"):
            setattr(self, key, getattr(self, key) + getattr(other, key))

    @property
    def deleted(self):
        return self.files + self.dirs


def delete_tree(folder, *, min_age_days=0, exclusions=(), keep_root=False,
                dry_run=False, denied_buckets=None):
    """
    Delete the contents (and optionally the root) of a folder, bottom-up.
    Only empty directories are removed with os.rmdir — never shutil.rmtree on
    unknown trees, and junctions/symlinks are never followed.
    """
    cutoff = None
    if min_age_days > 0:
        cutoff = datetime.datetime.now() - datetime.timedelta(days=min_age_days)
    exc_pat = tuple(exclusions or ())
    stat = Stat()
    bucket = denied_buckets if denied_buckets is not None else {"denied": 0}

    def deny(err):
        bucket["denied"] += 1
    for root, dirs, files in os.walk(folder, topdown=False, onerror=deny,
                                     followlinks=False):
        dirs[:] = [d for d in dirs if not any(
            fnmatch.fnmatch(d.lower(), p.lower()) for p in exc_pat)]
        for name in files:
            file_path = os.path.join(root, name)
            try:
                if cutoff is not None:
                    try:
                        mtime = datetime.datetime.fromtimestamp(
                            os.path.getmtime(file_path))
                    except (OSError, ValueError):
                        # unreadable mtime: can't prove it is fresh → try to delete
                        pass
                    else:
                        if mtime >= cutoff:
                            continue
                size = os.path.getsize(file_path)
                if not dry_run:
                    os.remove(file_path)
                stat.files += 1
                stat.bytes += size
            except FileNotFoundError:
                pass
            except OSError as exc:
                if is_locked_error(exc):
                    stat.locked += 1
                elif isinstance(exc, PermissionError):
                    stat.denied += 1
                else:
                    stat.other += 1
        for name in dirs:
            dir_path = os.path.join(root, name)
            try:
                is_link = os.path.islink(dir_path) or (
                    hasattr(os.path, "isjunction") and os.path.isjunction(dir_path))
                if is_link:
                    continue
                if dry_run:
                    # only count dirs we could actually remove (read-only check)
                    try:
                        if next(os.scandir(dir_path), None) is not None:
                            continue  # not empty → rmdir would fail
                    except OSError:
                        continue
                else:
                    os.rmdir(dir_path)  # only removes empty dirs
                stat.dirs += 1
            except FileNotFoundError:
                pass
            except OSError:
                pass  # not empty anymore, locked, or junction — leave it
    return stat


def clean_jetbrains(root, *, min_age_days=0, dry_run=False):
    """Only remove per-product caches/index/LocalHistory subfolders."""
    stat = Stat()
    prod_cache_names = ("caches", "index", "indexes", "LocalHistory")
    try:
        products = os.listdir(root) if os.path.isdir(root) else []
    except OSError:
        products = []
    for product in products:
        for sub in prod_cache_names:
            sub_path = os.path.join(root, product, sub)
            if os.path.isdir(sub_path):
                sub_stat = delete_tree(sub_path, min_age_days=min_age_days,
                                       dry_run=dry_run, keep_root=False)
                stat.add(sub_stat)
                if not dry_run:
                    try:
                        os.rmdir(sub_path)  # remove the emptied cache folder itself
                        stat.dirs += 1
                    except OSError:
                        pass
    return stat


def clean_target(target, path, dry_run):
    """Clean one resolved target path with its rules. Returns (stat, status)."""
    bucket = {"denied": 0}
    # Dry-run must not promise what permissions will not deliver: if the real
    # run would start denied anyway, report the skip now.
    if dry_run and target.get("requires_admin", False) and not is_admin():
        return Stat(), "SKIPPED — needs Administrator"
    # Probe: can we even list the folder?
    try:
        os.listdir(path)
    except OSError:
        need_admin = target.get("requires_admin", False)
        status = "SKIPPED — needs Administrator" if need_admin else "SKIPPED — access denied"
        return Stat(), status

    if target.get("custom") == "jetbrains":
        stat = clean_jetbrains(path, min_age_days=target.get("min_age_days", 0),
                               dry_run=dry_run)
        stat.denied += bucket["denied"]
        return stat, "OK"

    stat = delete_tree(
        path,
        min_age_days=target.get("min_age_days", 0),
        exclusions=list(DEFAULT_EXCLUSIONS),
        keep_root=target.get("keep_root", False),
        dry_run=dry_run,
        denied_buckets=bucket,
    )
    stat.denied = max(stat.denied, bucket["denied"])
    return stat, "OK"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def append_log(lines):
    """Append run lines to the shared log. One file for every run."""
    try:
        existing = ""
        if os.path.exists(LOG_FILE):
            with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                existing = f.read()
        body = existing.splitlines() + lines
        if len(body) > MAX_LOG_LINES:
            body = body[-MAX_LOG_LINES:]
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(body) + "\n")
    except OSError:
        pass


def log_run(mode, admin, results, note=""):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    out = [f"=== {stamp} | mode={mode} | admin={admin} | {note}"]
    for target, path, stat, status in results:
        ms = fmt_size(stat.bytes)
        out.append(
            f"  {target['id']:<22} {status:<30} files={stat.files} dirs={stat.dirs} "
            f"locked={stat.locked} denied={stat.denied} other={stat.other} freed={ms}"
        )
    out.append("")
    append_log(out)


# ---------------------------------------------------------------------------
# Toast notification
# ---------------------------------------------------------------------------


def show_notification(title, message, duration=10):
    """Show a Windows toast notification."""
    try:
        from winotify import Notification
    except ImportError:
        append_log(["toast failed: winotify not installed"])
        return False
    icon = ""
    supported = (".png", ".jpg", ".jpeg", ".gif", ".bmp")
    if os.path.exists(ICON_PATH) and ICON_PATH.lower().endswith(supported):
        icon = "file:///" + ICON_PATH.replace("\\", "/")
    try:
        toast = Notification(
            app_id="Auto Delete Junk Files",
            title=title,
            msg=message,
            icon=icon,
            duration="long" if duration >= 10 else "short",
        )
        toast.show()
        return True
    except Exception as exc:  # notification must never break cleanup
        append_log([f"toast failed: {exc}"])
        return False


# ---------------------------------------------------------------------------
# Startup installation
# ---------------------------------------------------------------------------


def create_batch_file():
    """Create the silent runner batch file (runs with pythonw, no console)."""
    script_name = os.path.basename(__file__)
    # Pin the absolute pythonw.exe path so the silent launcher never depends
    # on PATH (critical for fresh installs where PATH was just set).
    pythonw = sys.executable.replace("python.exe", "pythonw.exe")
    if not os.path.exists(pythonw):
        pythonw = sys.executable
    # 'start "" /min' - the empty title stops CMD treating the quoted path as a title
    batch_content = f'''@echo off
start "" /min "{pythonw}" "{os.path.join(SCRIPT_DIR, script_name)}"
'''
    with open(BATCH_FILE, "w") as f:
        f.write(batch_content)
    print(f"✅ Batch file created: {BATCH_FILE}")


def create_startup_shortcut():
    """Create a shortcut in the user's Windows startup folder."""
    import winshell
    import win32com.client

    startup_folder = winshell.startup()
    shortcut_path = os.path.join(startup_folder, "AutoDeleteJunkFiles.lnk")
    if not os.path.exists(BATCH_FILE):
        create_batch_file()
    shell = win32com.client.Dispatch("WScript.Shell")
    shortcut = shell.CreateShortCut(shortcut_path)
    shortcut.Targetpath = BATCH_FILE
    shortcut.WorkingDirectory = SCRIPT_DIR
    if os.path.exists(ICON_PATH):
        shortcut.IconLocation = ICON_PATH
    shortcut.save()
    print(f"✅ Startup shortcut created: {shortcut_path}")
    return True


def remove_startup_shortcut():
    """Remove the shortcut from the Windows startup folder if present."""
    import winshell

    startup_folder = winshell.startup()
    shortcut_path = os.path.join(startup_folder, "AutoDeleteJunkFiles.lnk")
    if os.path.exists(shortcut_path):
        os.remove(shortcut_path)
        print(f"✅ Startup shortcut removed: {shortcut_path}")
        return True
    print("ℹ️ No startup shortcut found.")
    return False


# ---------------------------------------------------------------------------
# Scheduling guard
# ---------------------------------------------------------------------------


def install_task(time_str="12:00"):
    """Create a Task Scheduler job that silently runs the cleaner every day."""
    create_batch_file()  # task target must exist and be pinned to this interpreter
    if not os.path.exists(BATCH_FILE):
        print("❌ Could not create run_silent.bat — task not scheduled")
        return False

    if not re.match(r"^\d{1,2}:\d{2}$", time_str or "") or \
            tuple(int(x) for x in (time_str or "99:99").split(":")) > (23, 59):
        print(f"❌ Invalid time '{time_str}' — use 24h HH:MM, e.g. 12:00")
        return False

    # /TR needs embedded quotes so the action survives folders with spaces
    result = subprocess.run(
        ["schtasks", "/Create", "/F", "/TN", TASK_NAME,
         "/TR", f'"{BATCH_FILE}"', "/SC", "DAILY", "/ST", time_str],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode == 0:
        print(f"✅ Scheduled task '{TASK_NAME}' created (daily {time_str})")
        print("   If the PC is on but you have not logged in, it still cleans.")
        return True
    print(f"❌ Could not create scheduled task (exit {result.returncode})")
    print("   " + (result.stderr or result.stdout or "").strip())
    return False


def uninstall_task():
    """Delete the scheduled task if it exists (locale-safe pre-check)."""
    q = subprocess.run(
        ["schtasks", "/Query", "/TN", TASK_NAME],
        capture_output=True, text=True, timeout=60,
    )
    if q.returncode != 0:
        print(f"ℹ️ No scheduled task '{TASK_NAME}' found — nothing to remove")
        return True
    result = subprocess.run(
        ["schtasks", "/Delete", "/F", "/TN", TASK_NAME],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode == 0:
        print(f"✅ Scheduled task '{TASK_NAME}' removed")
        return True
    print(f"❌ Could not remove scheduled task (exit {result.returncode})")
    print("   " + (result.stderr or result.stdout or "").strip())
    return False


def should_run_today():
    """True if the script has not completed a cleanup today."""
    today = datetime.date.today()
    try:
        if os.path.exists(LAST_RUN_FILE):
            with open(LAST_RUN_FILE, "r") as f:
                data = json.load(f)
            last_date = datetime.datetime.strptime(data["date"], "%Y-%m-%d").date()
            if last_date == today:
                return False, data.get("files_deleted", 0)
    except Exception:
        pass
    return True, 0


def update_last_run(files_deleted, bytes_freed=0):
    data = {
        "date": datetime.date.today().strftime("%Y-%m-%d"),
        "files_deleted": files_deleted,
        "bytes_freed": bytes_freed,
    }
    with open(LAST_RUN_FILE, "w") as f:
        json.dump(data, f)


def acquire_lock():
    """Prevent two concurrent runs (startup + manual)."""
    import msvcrt
    lock = open(LOCK_FILE, "w")
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        return lock
    except OSError:
        append_log(["[skip] another instance holds the lock"])
        print("Another cleanup run is already in progress.")
        return None


def release_lock(lock):
    try:
        import msvcrt
        msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        lock.close()
        os.remove(LOCK_FILE)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Main cleanup pipeline
# ---------------------------------------------------------------------------


def select_targets(targets, deep=False, with_high_risk=False):
    """Normal run → default_enabled targets; --deep adds opt-in (med) targets;
    --with-high-risk additionally allows danger='high' targets."""
    chosen, excluded = [], 0
    for target in targets:
        if target.get("danger") == "high" and not with_high_risk:
            excluded += 1
            continue
        if target.get("default_enabled", False) or deep:
            chosen.append(target)
        else:
            excluded += 1
    return chosen, excluded


def category_label(category):
    return {
        "system": "Windows/system",
        "os": "OS",
        "python": "Python",
        "node": "Node/JS",
        "dotnet": ".NET",
        "jvm": "JVM",
        "golang": "Go",
        "rust": "Rust",
        "editor": "Editor",
    }.get(category, category)


def derive_status(stat, target):
    """Human status line for one target, derived from its merged statistics."""
    if stat.denied and (stat.files + stat.dirs) == 0:
        return "NEEDS ADMINISTRATOR" if target.get("requires_admin") else "ACCESS DENIED"
    bits = []
    if stat.files + stat.dirs:
        bits.append(f"{stat.files} files + {stat.dirs} folders freed, {fmt_size(stat.bytes)}")
    if stat.locked:
        bits.append(f"{stat.locked} locked skipped")
    if stat.denied:
        bits.append(f"{stat.denied} denied" +
                    (" — needs Administrator" if target.get("requires_admin") else ""))
    if stat.other:
        bits.append(f"{stat.other} other errors")
    if not bits:
        return "nothing to clean"
    return "; ".join(bits)


def run_cleanup(dry_run=False, deep=False, with_high_risk=False, only=None):
    """Main cleanup: iterate all enabled targets, delete, log, notify."""
    admin = is_admin()
    targets, _excl = load_targets()
    mode = ("DRY-RUN" if dry_run else "DELETE") + ("+DEEP" if deep else "")

    chosen, _excluded = select_targets(targets, deep, with_high_risk)
    if only:
        chosen = [t for t in chosen if t["id"] == only] or \
                 [t for t in targets if t["id"] == only]
        if not chosen:
            print(f"Unknown target id: {only}. Use --list-targets.")
            return

    resolved, not_found = [], []
    for target in chosen:
        for template in target.get("paths", []):
            try:
                path = safe_resolve(template)
            except Exception as exc:  # malformed template must not kill the run
                print(f"   ⚠ [{target['id']}] unusable path {template!r}: {exc}")
                append_log([f"[error] {target['id']}: bad path template "
                            f"{template!r}: {exc}"])
                continue
            if path and os.path.isdir(path):
                resolved.append((target, path))
            elif path:
                not_found.append((target["id"], template))

    print(f"\n🧽 Auto Delete Junk Files — "
          f"{'DRY RUN (nothing deleted)' if dry_run else 'Cleaning...'}")
    print(f"   Mode: {mode} | Admin: {admin} | Targets: {len(resolved)} paths\n")

    # group resolved paths by target id (one summary line per target)
    groups = {}
    for target, path in resolved:
        g = groups.setdefault(
            target["id"], {"target": target, "stat": Stat(), "paths": []})
        try:
            stat, status = clean_target(target, path, dry_run=dry_run)
        except Exception as exc:
            # one misbehaving target must never abort the whole sweep
            import traceback
            append_log([f"[error] {target['id']}: {path}",
                        "    " + traceback.format_exc().replace("\n", "\n    ")])
            print(f"   ⚠ {target['name']}: unexpected error ({exc}) — skipped")
            status = f"ERROR: {type(exc).__name__} — see cleanup_log.txt"
            stat = Stat()
        g["stat"].add(stat)
        g["paths"].append({"path": path, "status": status, "stat": stat})

    total = Stat()
    results_lines = []
    for key, g in groups.items():
        target = g["target"]
        skip_statuses = [p["status"] for p in g["paths"]
                         if p["status"].startswith("SKIPPED")]
        status = skip_statuses[0] if len(skip_statuses) == len(g["paths"]) \
            else derive_status(g["stat"], target)
        g["status"] = status
        print(f"   {'[TEST] ' if dry_run else ''}"
              f"{target['name']} [{category_label(target.get('category', ''))}]")
        print(f"     └─ {status}")
        for p in g["paths"]:
            results_lines.append((target, p["path"], p["stat"], p["status"]))
        total.add(g["stat"])

    nf_lines = [f"  (not present) {tid}: {tpl}" for tid, tpl in not_found]
    append_log([f"[info] absent target paths: {len(not_found)}"] + nf_lines if nf_lines else
               ["[info] absent target paths: 0"])
    log_run(mode, admin, results_lines)

    if dry_run:
        print(f"\n📊 DRY RUN TOTAL — would delete {total.files} files + {total.dirs} folders | "
              f"{fmt_size(total.bytes)}")
        return

    update_last_run(total.files, total.bytes)
    write_report(admin, deep, groups)

    needs_admin = [g for g in groups.values()
                   if "administrator" in g.get("status", "").lower()]
    msg = (f"Deleted {total.files} files, freed {fmt_size(total.bytes)} from "
           f"{len(groups)} targets.\nLocked skipped: {total.locked}")
    if needs_admin:
        msg += f"\n{len(needs_admin)} targets need Administrator (run with --elevate)"
    print(f"\n✅ Done — {msg}")
    show_notification(
        "Junk Cleanup Complete" if not deep else "Deep Junk Cleanup Done",
        msg,
    )


def write_report(admin, deep, groups):
    """Write a machine-readable summary of the last run."""
    report = {
        "when": datetime.datetime.now().isoformat(timespec="seconds"),
        "admin": admin,
        "deep": deep,
        "targets": [],
    }
    for key, g in groups.items():
        target, stat = g["target"], g["stat"]
        report["targets"].append({
            "id": target["id"],
            "status": g.get("status", derive_status(stat, target)),
            "files_deleted": stat.files,
            "folders_deleted": stat.dirs,
            "locked_skipped": stat.locked,
            "denied_skipped": stat.denied,
            "bytes_freed": stat.bytes,
            "paths": [{"path": p["path"], "status": p["status"],
                       "files": p["stat"].files, "bytes": p["stat"].bytes}
                      for p in g["paths"]],
        })
    report["total_files_deleted"] = sum(t["files_deleted"] for t in report["targets"])
    report["total_bytes_freed"] = sum(t["bytes_freed"] for t in report["targets"])
    try:
        with open(REPORT_FILE, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
    except OSError:
        pass


def run_test():
    """Dependency + permission diagnostics (deletes nothing)."""
    print("=" * 50)
    print("🧪 AUTO DELETE JUNK FILES — TEST MODE")
    print("=" * 50)

    print("\n📦 Checking dependencies...")
    missing, errors = check_dependencies()
    if missing:
        show_troubleshooting(missing, errors)
        return False
    print("✅ All dependencies installed!")

    print("\n🎨 Checking icon file...")
    if os.path.exists(ICON_PATH):
        print(f"✅ Icon found: {ICON_PATH}")
    else:
        print(f"⚠️ Icon not found: {ICON_PATH}")

    admin = is_admin()
    print(f"\n🛡️ Process elevation: {'Administrator ✅' if admin else 'standard user (no admin)'}")

    print("\n📁 Target permission probe (deletes nothing):")
    targets, _ = load_targets()
    for target in targets:
        for template in target.get("paths", []):
            path = safe_resolve(template)
            if not path:
                print(f"   ❌ {target['id']}: refused/invalid: {template}")
                continue
            if not os.path.isdir(path):
                print(f"   ➖ {target['id']}: not present ({path})")
                continue
            try:
                os.listdir(path)
                if target.get("requires_admin") and not admin:
                    print(f"   🔒 {target['id']:<22} {path}  →  listable, but cleaning "
                          "needs Administrator")
                else:
                    print(f"   ✅ {target['id']:<22} {path}  →  cleanable")
            except OSError:
                mark = "⚠️"
                print(f"   {mark} {target['id']:<22} {path}  →  NO ACCESS"
                      + ("  [cleanable only when elevated]" if target.get("requires_admin") else ""))
    print("\n✅ Setup test complete.")
    return True


def check_dependencies():
    """Check if all required dependencies are installed."""
    missing = []
    errors = {}
    try:
        from winotify import Notification
    except ImportError as exc:
        missing.append("winotify")
        errors["winotify"] = str(exc)
    try:
        import winshell
    except ImportError as exc:
        missing.append("winshell")
        errors["winshell"] = str(exc)
    try:
        import win32com.client
    except ImportError as exc:
        missing.append("pywin32")
        errors["pywin32"] = str(exc)
    except Exception as exc:
        missing.append("pywin32")
        errors["pywin32"] = str(exc)
    return missing, errors


def show_troubleshooting(missing, errors):
    """Show detailed troubleshooting steps for missing dependencies."""
    print("\n" + "=" * 60)
    print("❌ INSTALLATION TROUBLESHOOTING")
    print("=" * 60)
    print(f"\n🔍 Missing packages: {', '.join(missing)}")
    fixes = {
        "winotify": {
            "install": "pip install winotify",
            "description": "Windows 10/11 Toast Notifications",
            "troubleshoot": [
                "If installation fails, try: pip install --upgrade pip",
                "Then retry: pip install winotify",
            ],
        },
        "winshell": {
            "install": "pip install winshell",
            "description": "Windows Shell Operations",
            "troubleshoot": [
                "If installation fails, try: pip install --upgrade pip",
                "Then retry: pip install winshell",
            ],
        },
        "pywin32": {
            "install": "pip install pywin32",
            "description": "Windows API (COM, Registry, etc.)",
            "troubleshoot": [
                "After installing, run: python -m pywin32_postinstall -install",
                "If you see DLL errors, try reinstalling:",
                "  pip uninstall pywin32",
                "  pip install pywin32",
                "  python -m pywin32_postinstall -install",
                "You may need to run as Administrator",
            ],
        },
    }
    for pkg in missing:
        if pkg in fixes:
            info = fixes[pkg]
            print(f"\n📦 {pkg} — {info['description']}")
            print(f"   Install: {info['install']}")
            if pkg in errors:
                print(f"   Error: {errors[pkg]}")
            print("   Troubleshooting:")
            for step in info["troubleshoot"]:
                print(f"     • {step}")
    print("\n" + "-" * 60)
    print("💡 QUICK FIX: Run these commands in order:")
    print("-" * 60)
    print("   pip install --upgrade pip")
    print("   pip install -r requirements.txt")
    print("\n   If issues persist, try running Command Prompt as Administrator.")
    print("=" * 60)


def list_targets():
    """Print the rule table."""
    targets, _ = load_targets()
    admin = is_admin()
    print(f"\n📋 Deletion targets (admin process: {admin})\n")
    print(f"{'ON':<4}{'ID':<24}{'CAT':<10}{'DANGER':<7}{'AGE>=':<6}{'ADMIN':<6}PATH")
    print("-" * 110)
    for t in sorted(targets, key=lambda t: (t.get("category", ""), t["id"])):
        enabled = "✔" if t.get("default_enabled") else "deep"
        deep_only = "" if t.get("default_enabled") else "(deep)"
        for i, template in enumerate(t.get("paths", [])):
            if i == 0:
                print(f"{deep_only:<4}{t['id']:<24}{t.get('category', ''):<10}"
                      f"{t.get('danger', ''):<7}{t.get('min_age_days', 0):<6}"
                      f"{'yes' if t.get('requires_admin') else '':<6}"
                      f"   {template}")
            else:
                print(f"{'':<56}{'':<6}   {template}")
    print("\nNote: 'deep' rows only run with --deep (danger=high targets also need --with-high-risk).")


def elevate_and_exit(args):
    """Relaunch this script with Administrator rights and exit."""
    import ctypes

    script = os.path.abspath(__file__)
    params = " ".join(arg if not arg.startswith('"') and " " not in arg
                      else f'"{arg}"' for arg in args)
    ret = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, f'"{script}" {params}', None, 1
    )
    if ret <= 32:  # user cancelled / blocked UAC
        print("⚠️ Elevation was cancelled — only user-level targets were cleaned.")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Auto Delete Junk Files — clean Windows temp files and dev caches automatically"
    )
    parser.add_argument("--test", action="store_true",
                        help="dependency + permission test (no deletion)")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would be deleted without deleting")
    parser.add_argument("--deep", action="store_true",
                        help="include opt-in caches (danger=med); danger=high excluded")
    parser.add_argument("--with-high-risk", action="store_true",
                        help="with --deep, also clean danger='high' targets (e.g. Maven repo)")
    parser.add_argument("--target", dest="only", metavar="ID",
                        help="clean only the target with this id")
    parser.add_argument("--elevate", action="store_true",
                        help="relaunch with Administrator rights for system targets")
    parser.add_argument("--install", action="store_true", help="add to Windows startup")
    parser.add_argument("--uninstall", action="store_true", help="remove from Windows startup")
    parser.add_argument("--install-task", dest="install_task", nargs="?", const="12:00",
                        default=None, metavar="HH:MM",
                        help="create a daily Task Scheduler job (default 12:00; "
                             "optional time, e.g. --install-task 18:30)")
    parser.add_argument("--uninstall-task", dest="uninstall_task", action="store_true",
                        help="remove the daily Task Scheduler job")
    parser.add_argument("--list-targets", action="store_true", help="show cleanup rules table")
    parser.add_argument("--force", action="store_true",
                        help="run even if already cleaned today")
    args = parser.parse_args()

    # task management and --uninstall must work even with broken deps
    if not (args.uninstall or args.uninstall_task or args.install_task):
        missing, errors = check_dependencies()
        if missing:
            show_troubleshooting(missing, errors)
            sys.exit(1)

    if args.test:
        success = run_test()
        sys.exit(0 if success else 1)
    elif args.install:
        create_batch_file()
        create_startup_shortcut()
    elif args.uninstall:
        remove_startup_shortcut()
    elif args.install_task:
        okay = install_task(args.install_task)
        sys.exit(0 if okay else 1)
    elif args.uninstall_task:
        okay = uninstall_task()
        sys.exit(0 if okay else 1)
    elif args.list_targets:
        list_targets()
    else:
        lock = acquire_lock()
        if lock is None:
            sys.exit(0)
        try:
            should_run, last_deleted = should_run_today()
            if should_run is False and not args.force and not args.dry_run \
                    and args.deep is False and not args.with_high_risk:
                print(f"Already cleaned today (deleted {last_deleted} files). Use --force to rerun.")
                return

            # Elevate on request: relaunch (without --elevate) as Administrator
            if args.elevate and not is_admin():
                sys.argv = [a for a in sys.argv if a != "--elevate"]
                if elevate_and_exit(sys.argv[1:]):
                    return  # parent exits; elevated child does the work
                # user refused elevation → fall through, clean user targets

            run_cleanup(
                dry_run=args.dry_run,
                deep=args.deep or args.with_high_risk,
                with_high_risk=args.with_high_risk,
                only=args.only,
            )
        finally:
            release_lock(lock)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except KeyboardInterrupt:
        print("\nInterrupted — nothing else was deleted.")
        append_log(["[info] interrupted by user (Ctrl+C)"])
    except Exception:
        # pythonw runs have no console: a traceback must land in the log file
        import traceback
        append_log(["[fatal] unhandled exception:"] +
                   ["    " + line for line in traceback.format_exc().splitlines()])
        raise

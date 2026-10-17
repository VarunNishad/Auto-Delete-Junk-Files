# Auto Delete Junk Files 🗑️

Automatically clean Windows temp/junk folders **and dev-tool caches**
(pip, npm, yarn, pnpm, electron, Go, Cargo, NuGet, VS Code, ...) at Windows
startup. Runs silently, shows a toast with the amount of space freed, and
logs every run to `cleanup_log.txt`.

![Windows](https://img.shields.io/badge/Platform-Windows-blue)
![Python](https://img.shields.io/badge/Python-3.8+-green)

## Features

- 🧹 **Windows folders + dev-tool caches in one place** — see `targets.json`
- 🔒 **Permission-aware** — access-denied targets are reported
  (`needs Administrator`), never silently "0 files"
- 🛡️ **Path safety** — targets outside allowed roots (temp/AppData/etc.) are refused
- ⏳ **Age filter** — files younger than the target's `min_age_days` are kept
- 🚫 **Exclusions** — directories like `opencode` are never touched; locked
  files are skipped and counted
- 📄 **Logging & report** — `cleanup_log.txt` for every run, `cleanup_report.json` machine-readable summary
- 🔔 **Toast notification** — freed disk space per run
- 🧪 **`--dry-run` / `--test`** — see exactly what would happen, delete nothing
- 🔐 **`--elevate`** — optional one-run Administrator relaunch for system folders
- ⏰ **Daily limit + run lock** — once per day, no overlapping runs

## Target Folders

The default catalog (editable in `targets.json`) includes:

- Windows: user/system temp, Windows Update downloads, error reports,
  INetCache, crash dumps — Prefetch is **opt-in** (Microsoft does not
  recommend cleaning it)
- Python: pip, uv, poetry caches
- Node/JS: npm, yarn, pnpm, electron, cypress, bun caches
- .NET / Go / Rust / JVM: NuGet, go-build, cargo, gradle, maven (opt-in)
- Editors: VS Code caches/logs, JetBrains product caches

Opt-in (`--deep`) targets and high-risk targets (`--with-high-risk`) are
disabled by default. Run `python auto_delete_junk_files.py --list-targets`
for the full table.

## Quick Start

### One-Click Setup (works on a fresh PC, no admin needed)

1. Download or extract the folder somewhere you can find it
2. **Double-click `setup.bat`**
3. Answer the questions with **Y** or **N** — every question is optional

What each question means, in plain words:

| Question | What happens if you answer Y |
|---|---|
| Add to Windows startup? | Cleans junk automatically every time the PC starts |
| Also clean daily at 12:00 even if the PC stays on? | Creates a Windows Task Scheduler job for daily cleaning without a restart |
| Run the first cleanup right now? | Deletes today's junk immediately and tells you how much space was freed |
| Also clean Windows system folders now? | One extra **Yes** click on the blue UAC window, then deeper folders (Windows Update leftovers, etc.) are cleaned too |

A final **Setup Complete!** screen means you are done — cleanup now happens
on its own, and a small toast notification tells you what was freed.

`setup.bat` is fully self-bootstrapping: if **Python is missing** it installs
it automatically — via `winget` (built into Windows 10 and 11); on very old
machines without winget it falls back to downloading the official
[python.org](https://www.python.org/downloads) installer. Both install
silently for your user only: **no Administrator rights needed either way**.
It also survives a broken PATH, bootstraps pip via `ensurepip` if missing,
verifies package imports actually work, and appends every step to
`setup_log.txt` (open it if anything ever looks wrong).

### Manual Installation

```bash
# Install dependencies
pip install -r requirements.txt

# Verify everything works
python auto_delete_junk_files.py --test

# Add to Windows startup
python auto_delete_junk_files.py --install
```

## Usage

| Command | Description |
|---------|-------------|
| `python auto_delete_junk_files.py` | Run cleanup (skips if already ran today) |
| `python auto_delete_junk_files.py --force` | Run even if already ran today |
| `python auto_delete_junk_files.py --dry-run` | Report what would be deleted — deletes nothing |
| `python auto_delete_junk_files.py --deep` | Include opt-in caches (med risk) |
| `python auto_delete_junk_files.py --deep --with-high-risk` | Also high-risk caches (e.g. Maven repo) |
| `python auto_delete_junk_files.py --target npm_cache` | Clean a single target by id |
| `python auto_delete_junk_files.py --elevate` | Re-run as Administrator (UAC prompt) |
| `python auto_delete_junk_files.py --list-targets` | Show every rule, risk and age |
| `python auto_delete_junk_files.py --test` | Dependency + permission test (no deletion) |
| `python auto_delete_junk_files.py --install` | Add to Windows startup |
| `python auto_delete_junk_files.py --uninstall` | Remove from startup |
| `python auto_delete_junk_files.py --install-task` | Create daily Task Scheduler job (12:00, no admin needed) |
| `python auto_delete_junk_files.py --install-task 18:30` | Same, at a custom 24h time |
| `python auto_delete_junk_files.py --uninstall-task` | Remove the daily job |
| `python test_engine.py` | Run the sandbox test suite |

The daily job (`AutoDeleteJunkFilesDaily`) means cleaning happens every day
even when the PC stays on for weeks without a restart. If cleanup already ran
that day, the job exits in under a second and changes nothing.

### Without vs. with administrator

| | Normal run | `--elevate` run |
|---|---|---|
| User temp, dev caches, editor caches | ✅ fully cleaned | ✅ fully cleaned |
| `C:\Windows\Temp`, Windows Update, program-wide WER | ⚠️ reported as needing admin | ✅ cleaned |

The script **never silently skips**: any denied target is shown in the
console summary, `cleanup_log.txt` and the toast (with a
`run with --elevate` hint).

### Editing targets

Open `targets.json` (auto-created on first run). Each target supports:

```jsonc
{
  "id": "npm_cache",                 // unique id (also used by --target)
  "name": "npm cache",
  "category": "node",                // os | system | python | node | dotnet | jvm | golang | rust | editor
  "paths": ["%LOCALAPPDATA%\\npm-cache"],
  "requires_admin": false,
  "min_age_days": 0,                 // keep files newer than this
  "default_enabled": true,           // false = only with --deep
  "danger": "low",                   // low | med | high (high also needs --with-high-risk)
  "keep_root": true,                 // delete contents, keep the root folder
  "exclusions": ["log"]              // never delete dirs matching these globs
}
```

Unsafe paths (outside TEMP/AppData/ProgramData/whitelisted system folders)
are refused at runtime — the tool can never be pointed at your documents,
projects, etc.

## Uninstall

**Option 1:** Double-click `uninstall.bat`

**Option 2:** Run manually:
```bash
python auto_delete_junk_files.py --uninstall
```

## Requirements

- Windows 10/11
- Python 3.8 or higher

## Dependencies

- `winotify` - Windows toast notifications
- `winshell` - Windows shell operations
- `pywin32` - Windows API access

Versions are pinned in `requirements.txt` and installed from there by
`setup.bat` (tested combination: Python 3.14 / Windows 11). Bump a pin only
after re-running `python test_engine.py`.

## Troubleshooting

### Notification not showing?
- Make sure Windows notifications are enabled
- Run the `--test` command to verify setup
- Previous runs are always recorded in `cleanup_log.txt`

### Permission errors?
- Some system files may be locked — they are skipped and counted
  (`locked skipped` / `denied` in every report)
- For `C:\Windows\Temp`, Windows Update etc., run with `--elevate`

### Script opens in IDE instead of running?
- The `setup.bat` creates a batch launcher that uses `pythonw` to run silently
- Make sure to use the `--install` option to set up correctly

## License

MIT License - Feel free to use and modify!

## Author

Created with ❤️ for a cleaner Windows experience.

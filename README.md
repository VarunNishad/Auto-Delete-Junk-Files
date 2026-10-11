# Developer Junk Files Cleaner 🧹

**v3.1.0** - A zero-dependency PowerShell cleaner for Windows developers. It sweeps Windows temp files **plus** the package-manager caches that quietly eat tens of gigabytes (uv, npm, pip, Yarn, pnpm, Bun, NuGet, Cargo, Go, Gradle, Composer, Playwright, Cypress, Electron), browser caches, and project build artefacts (`__pycache__`, `.next/cache`, `.pytest_cache`, `.turbo`).

> **What changed in v3** - v2 shipped the developer-cache module behind the `-CleanDev` flag, but the startup shortcut launched the script with **no flags**, so the daily run only ever cleared `%TEMP%` and the npm cache grew to 16 GB untouched. v3 fixes the wiring, replaces per-file deletion (hours on 500k cache files) with a `robocopy` empty-mirror (seconds), and puts every delete behind an explicit safety gate.

Written natively in **PowerShell**, it runs natively on any Windows computer **without requiring Python, Node.js, or any other virtual machine or library installation!** It features native system toast notifications, a silent daily automation scheduler, and integrates directly into the Windows **Add/Remove Programs** panel for a professional desktop experience.

![Platform](https://img.shields.io/badge/Platform-Windows%207%20%7C%2010%20%7C%2011-blue)
![Language](https://img.shields.io/badge/Language-PowerShell-powershell?color=17a2b8)
![Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen)

---

## ✨ Features

- ⏰ **Elevated scheduled task** - Registers a Windows Scheduled Task at *highest privileges*, daily + at logon. A Startup-folder shortcut can never elevate, which is why `C:\Windows\Temp`, Prefetch, Windows Update downloads, Delivery Optimization and CBS logs used to skip on every automatic run. Falls back to the old shortcut if setup isn't run as admin. Setup copies the script to `C:\Program Files\DeveloperJunkCleaner` (admin-only) and the task runs that copy, so re-run `setup.bat` after editing the script or `targets.json`. A non-elevated run hands the system caches to that task, so the admin-only folders are cleaned with no UAC prompt, and cleans the developer caches itself: `uv`, `pip` and `pnpm` are never started with admin rights. The daily trigger lives on a separate non-elevated task, `DeveloperJunkCleanerDaily`.
- 📉 **Free-space adaptive** - Reads free space before cleaning. Above 25% free it leaves developer caches alone entirely; below 10% it drops every size gate. Cleans only as hard as the disk actually needs. `-NoAdaptive` disables it.
- 🛡️ **Hard safety gate** - Every delete passes `Assert-SafeTarget` first. Documents, Downloads, Desktop, Pictures, Videos, Music, OneDrive, Program Files, ProgramData and the Windows system folders are refused outright. A typo in a path makes the script skip, not wipe.
- ⚡ **Fast wipes** - `robocopy /MIR` from an empty folder clears a 16 GB / 500,000-file npm cache in seconds instead of hours.
- 📏 **Size gates** - A cache is only wiped once it exceeds its threshold (npm/uv 1 GB, pip 512 MB, ...), so small caches survive and your next `npm i` stays fast. `-Force` overrides.
- 🧹 **System & Developer Caches** - Windows temp plus uv, pip, Poetry, npm, Yarn, pnpm, Bun, Deno, NuGet, Cargo, Go, Gradle, Composer, Electron, Cypress, Playwright, Puppeteer and VS Code caches.
- 🚫 **Never touched** - AI models (`.gguf`, HuggingFace), VM disks (`.vhd`/`.vhdx`), installed applications, and your own documents. `node_modules` and `.venv` are **reported, never deleted**.
- 📁 **Recursive Workspace Scans** - Deep-cleans workspace projects by safely deleting compile artifacts (`__pycache__`, `.next/cache`, etc.) while protecting active source code.
- 🐳 **Docker Integration** - Probes if Docker is active and runs native builder/system prunes to reclaim container storage safely.
- 🔔 **Native Toast Notifications** - Shows beautiful system balloon banners on completion using built-in Windows .NET triggers.
- 🔒 **File Lock Guard** - Employs try-catch protection blocks to automatically skip locked or active files without crashing.
- ⏰ **Daily Scheduling** - Runs automatically once per day in the background on startup, preserving resources if already cleaned.
- 📦 **Apps & Features Registration** - Registers natively in Windows Control Panel / Settings Apps list with its own icon for professional Add/Remove and uninstallation support.

---

## 🧼 Scope & Safety Matrix

All cleanup modules are thoroughly validated. Caches are purely transient and are safely rebuilt or re-downloaded when next required:

| Category | Clean-up Targets | Safety Level | Deletion Behavior / Side Effects |
| :--- | :--- | :--- | :--- |
| **System Cache** | `%TEMP%`, `%SYSTEMROOT%\Temp`, CrashDumps, WER, INetCache, Windows Update downloads | **Safe** | Only files older than 1 day are pruned, so installers in flight are left alone. Locked files are skipped. Elevated-only targets are announced and skipped when not running as admin. |
| **Browser Cache** | Chrome / Edge `Cache` and `Code Cache` per profile | **Safe** | Page cache only. Bookmarks, passwords, history, cookies and sessions are never touched. |
| **Global Developer Cache** | uv, pip, Poetry, npm, Yarn, pnpm, Bun, Deno, NuGet, Cargo, Go, Gradle, Composer, Electron, Cypress, Playwright, Puppeteer, VS Code | **Safe** | Re-downloaded on demand. Gated by size so a small cache is left alone. |
| **Never targeted** | `node_modules`, `.venv`, `.gguf` / HuggingFace models, `.vhd`/`.vhdx`, Documents, Downloads, Desktop, Program Files | **Protected** | `node_modules` / `.venv` older than 90 days are listed for you to review; nothing is deleted. Everything else is hard-blocked. |
| **Recursive Workspace Cache** | `__pycache__`, `.next\cache`, `.pytest_cache`, `.mypy_cache`, `.turbo`, `.eslintcache`, `.ipynb_checkpoints` | **100% Safe** | Clears compiled script bytecodes and builder artifacts. Automatically re-compiles on next local build or run. |
| **Docker Containers** | Docker Build Caches & Inactive volumes | **Cautious** | Safe. Executed via native commands (`docker builder prune`) only if Docker Desktop is actively running. |

---

## 🚫 Paths that look like junk but are not

WinDirStat shows these near the top of the tree. Only two of them are safe for a script to delete.

| Path | What it actually is | Verdict |
| :--- | :--- | :--- |
| `C:\pagefile.sys` | Windows virtual-memory swap file, held open by the kernel and recreated at boot. | **Never delete.** Hard-blocked. Shrink it in *System Properties → Advanced → Performance → Virtual memory*, or move it to another drive. |
| `C:\Windows\WinSxS` | The component store. Most of its apparent size is hard links that WinDirStat counts more than once, so it is smaller on disk than it looks. Microsoft: deleting from it "may severely damage your system so that your PC might not boot and make it impossible to update." | **Never delete files.** Hard-blocked. Use `-DeepClean`, which runs the supported `DISM /Cleanup-Image /StartComponentCleanup`. |
| `...\Local\uv\cache` | uv's Python wheel cache. Rebuilt on demand. | **Safe.** Already a target (1 GB gate). Largest single win on this machine. |
| `...\Local\npm-cache\_cacache` | npm's content-addressable package cache. Rebuilt on demand. | **Safe.** Already a target (1 GB gate). |
| `...\Chrome\User Data\OptGuideOnDeviceModel\...\weights.bin` | Chrome's Gemini Nano on-device AI model, about 4 GB. Regenerable. | **Safe, but it comes back.** Now a target. Run `-BlockChromeAIModel` once as admin to set the `GenAILocalFoundationalModelSettings` policy so Chrome stops re-downloading it. |

## 🚀 Quick Start

### One-Click Installation

1. Download or clone this repository to your computer.
2. **Double-click `setup.bat`**.
3. Follow the prompts (e.g. choose if you want to run a safe dry-run test).

**That's it!** The program is now natively registered under your Windows Startup directory and added to the official Windows Apps list.

### Native Uninstallation

- **Option A**: Search for **"Developer Junk Cleaner"** in your Windows **Settings -> Apps -> Installed Apps** (or Control Panel -> Programs and Features) and click **Uninstall**.
- **Option B**: Double-click **`uninstall.bat`** in the program folder.

Both options cleanly wipe all startup shortcuts, scheduled tasks, local run logs, and registry integrations.

---

## ⚙️ PowerShell CLI Commands

The core script `auto_delete_junk_files.ps1` supports powerful parameter switches for advanced terminal users:

| Argument | Type | Description |
| :--- | :--- | :--- |
| `-Report` | Switch | **Read-only.** Prints the current size of every cache location and the total reclaimable. Deletes nothing, ignores gates. Start here. |
| `-Test` | Switch | **Dry run.** Applies the real gates and shows exactly what would be removed, without removing it. |
| `-CleanSystem` | Switch | Windows temp, crash dumps, update leftovers and browser caches only. |
| `-CleanDev` | Switch | Global developer package-manager caches only. |
| `-CleanProjects [Path]` | String | Recursively prunes project build artefacts under a path, and reports stale `node_modules` / `.venv`. |
| `-All` | Switch | System + developer caches. This is what the daily startup run now uses. |
| `-Force` | Switch | Ignores the size gates **and** the once-per-day lock. Use for a one-off deep clean. |
| `-DeepClean` | Switch | **Admin.** Runs `DISM /Online /Cleanup-Image /StartComponentCleanup` to shrink WinSxS the supported way. Takes 10-30 minutes, so it is opt-in and never part of the daily run. With `-Report` it only *analyses* the store. |
| `-BlockChromeAIModel` | Switch | **Admin.** One-time fix: writes the Chrome policy that stops the 4 GB on-device AI model from being downloaded, then deletes the copy already on disk. |
| `-EmptyRecycleBin` | Switch | Opt-in, never automatic — it holds files you deleted on purpose. Emptied through the shell API, never by deleting from `$Recycle.Bin`. |
| `-CompactVHD` | Switch | **Admin.** Shuts down WSL, then `diskpart compact vdisk` on every WSL/Docker `.vhdx`. These grow when the VM writes and never shrink again when files inside are deleted. |
| `-NoAdaptive` | Switch | Ignore free space and always use the fixed per-target gates. |
| `-NoGates` | Switch | System caches are cleaned whatever their size. The daily task uses this. Developer caches keep their gates; `uv` and `pnpm` are pruned (unused entries only) instead of wiped. |
| `-DockerPrune` | Switch | Opt-in `docker builder prune` + `docker system prune`. Deletes every stopped container, so it is never automatic. |
| `-Maintenance` | Switch | **Admin.** `-DeepClean` + `-CompactVHD` only, no cache cleaning. Run every 4 weeks by the `DeveloperJunkCleanerMonthly` task; skips disk compaction while WSL or Docker is running. |
| `-UnusedApps` | Switch | Lists installed programs not started in 90+ days, from the Prefetch launch history (needs the elevated task). A recommendation only - nothing is uninstalled. Also part of `-Report`. |
| `-UpdateApps` | Switch | Runs `winget upgrade --all`. |
| `-ExportTargets` | Switch | Writes the current gate values to `targets.json` so you can retune them without editing the script. |
| `-Install` | Switch | Programmatically registers startup files and registry uninstall keys. |
| `-Uninstall` | Switch | Programmatically wipes startup files, registry uninstall keys, and logs. |

### Example CLI Queries:
```powershell
# 1. See where the space actually is (read-only, deletes nothing):
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -Report

# 2. Dry run with the real gates applied:
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -Test -All

# 3. Clean everything, ignoring the size gates and the daily lock:
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -All -Force

# C:\Windows\Temp and Windows Update leftovers need admin: run setup.bat once,
#   after that every run is handed to the elevated task with no UAC prompt.

# Check the delete gate (deletes nothing):
powershell -ExecutionPolicy Bypass -File .\tests\safety_check.ps1

# One-time: kill Chrome's 4 GB AI model for good (elevated PowerShell):
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -BlockChromeAIModel

# Shrink WinSxS the supported way (elevated, 10-30 min):
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -DeepClean

# Prune project build artefacts under your projects folder:
powershell -ExecutionPolicy Bypass -File .\auto_delete_junk_files.ps1 -CleanProjects "C:\Users\user\Documents\Python Projects"
```

---

## 🎛️ Tuning without editing code

`-ExportTargets` writes `targets.json` next to the script. Edit it and every later run picks it up:

```json
{
  "gates":    { "npm cache": 4096, "Playwright browsers": 0 },
  "disabled": [ "VS Code logs" ],
  "extra":    [ { "Name": "My tool cache", "Path": "C:\\Users\\user\\AppData\\Local\\mytool\\cache", "GateMB": 512 } ]
}
```

`gates` retunes a threshold in MB, `disabled` switches a target off, `extra` adds your own. Added paths still pass the same safety gate — the config file cannot unlock a protected location.

Every clean appends a row to `cleaner_history.csv` (timestamp, mode, bytes reclaimed, free space before), so the trend is visible without opening WinDirStat.

---

## 🔎 Reported, never deleted

`-Report` and `-Test` also surface things the script deliberately refuses to touch on its own:

- **`Windows.old`** — 20–30 GB after a feature update. Owned by TrustedInstaller; removing it by hand breaks rollback. Use Settings → Storage → Temporary files, or just wait, Windows clears it after ~10 days.
- **Large or long-untouched files in Downloads and Desktop** — over 100 MB, or untouched for 180+ days. Listed with size and age so you can decide. These are your files.
- **Recycle Bin size** — emptied only with `-EmptyRecycleBin`.
- **WSL / Docker `.vhdx` disks** — reclaimable only with `-CompactVHD`.

---

## 🛠️ Dynamic Discovery Algorithm

To prevent failures or blind execution across different computers, the cleaner works through a three-stage validation pipeline:
1. **Environment-Aware Mapping**: Resolves every path from environment variables for the current user.
2. **Safety Gate**: `Assert-SafeTarget` rejects drive roots, profile roots, and anything inside a protected user or system folder before a single byte is removed. Project build caches go through the narrower `Assert-SafeProjectTarget`, which additionally requires the folder to be *named* after a known build cache.
3. **Size Probe**: `robocopy /L` measures each folder without materialising half a million PowerShell objects.
4. **Size Gate**: Folders under their threshold are reported as `[KEEP]` and left alone.
5. **Cleaner Selection**: Under 2 GB the native CLI runs first (`uv cache clean`, `pip cache purge`, `go clean -cache`) with a 90-second timeout; above that, or on failure, `robocopy /MIR` from an empty directory does the wipe.
6. **Active Service Probing**: Docker prunes only run when the daemon actually answers.

Every run appends to `cleaner.log` next to the script, so you can see exactly what was removed and when.

---

## 📝 License

This project is licensed under the MIT License - feel free to customize and redistribute!

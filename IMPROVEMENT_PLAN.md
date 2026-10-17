# Auto Delete Junk Files — Analysis & Improvement Plan

Date: 2026-10-17 · Analysed on: Windows 11, Python 3.14.7, running **without** administrator rights

---

## 1. Verification Results (current script, no admin)

### What actually gets cleaned

| Target folder | Without admin | Evidence |
|---|---|---|
| `%TEMP%` (user temp) | ✅ Fully cleanable | Real run: **555 of 559 items deleted**; 8 skipped = 6 files in use (WinError 32, correctly skipped) + 2 locked Bun runtime files (WinError 5) |
| `C:\Windows\Temp` | ❌ Not cleaned, **silently** | Directory **cannot be listed** without admin (`Access denied` on enumeration). The script's `os.walk()` swallows the error → reports "0 files", does nothing |
| `C:\Windows\Prefetch` | ❌ Not cleaned, **silently** | No list access, no create access without admin → silently skipped |

**Key finding:** without admin, only **1 of 3** configured targets is actually cleaned, and the script
reports success either way. The user has no way to know two targets were skipped.

### Dev-tool junk found on this machine

| Cache | Size | Cleanable without admin? |
|---|---|---|
| `C:\Windows\SoftwareDistribution\Download` (Windows Update leftovers) | **735 MB** | ❌ Needs admin |
| `npm-cache` (%LOCALAPPDATA%) | **247.5 MB** | ✅ Yes |
| VS Code `CachedData` + `Cache` | 38 MB | ✅ Yes |
| `pip\Cache` | 8.2 MB | ✅ Yes |
| `Microsoft\Windows\INetCache` | 0.1 MB | ✅ Yes |
| Not present (but supported in plan): uv, yarn, pnpm, electron, playwright, cypress, gradle, maven, nuget, go-build, cargo, JetBrains, CrashDumps, WER | 0 MB | ✅ Yes (paths already detected/probed) |

**~1 GB reclaimable right now** — 735 MB needs the elevation feature (Phase 3), 295 MB can be freed today with no admin.

---

## 2. Bugs / Gaps found in the current script

| # | Issue | Impact |
|---|---|---|
| 1 | `os.walk()` silently ignores `PermissionError` | Reports "0 files" for `C:\Windows\Temp` / `Prefetch` — **false success** |
| 2 | No admin detection, no elevation option | System folders can never be cleaned |
| 3 | No logging — script runs via `pythonw` (no console) | All `print()` output, including every "Failed to delete" line, is **lost forever** |
| 4 | No byte reporting | User never sees "freed 312 MB" |
| 5 | No age filter | Deletes files an installer may be writing **right now** (locked files are skipped, but stale-but-active files are risky) |
| 6 | No exclusion list | Wipes *any* temp data of running apps (e.g. `Temp\opencode` gets deleted mid-session at every logon) |
| 7 | `run_cleanup(test_mode=True)` is dead code | `--test` only checks dependencies; no way to dry-run a cleanup |
| 8 | Prefetch is cleaned by default | Microsoft advises against it (slower boot while Windows rebuilds it), **and** it needs admin anyway → contradictory default |
| 9 | Counter mixes files and folders | "1212 files deleted" actually counts files + folders |
| 10 | Runs only at logon | If the PC stays on for a week, it only cleans once |

---

## 3. Proposed Target Catalog

Legend: **A** = needs admin · **U** = no admin needed · *(opt-in)* = default OFF, enabled by flag
Danger levels: `low` = pure junk · `med` = regenerable but costs re-download/rebuild time

### A. System junk (admin required — Phase 3)

| Path | Notes | Default |
|---|---|---|
| `%SYSTEMROOT%\SoftwareDistribution\Download` | Windows Update installers (735 MB found) — `low` | ON (with admin) |
| `%SYSTEMROOT%\Temp` | System temp (low) | ON (with admin) |
| `%PROGRAMDATA%\Microsoft\Windows\WER` | Windows Error Reporting (low) | ON (with admin) |
| `%SYSTEMROOT%\SoftwareDistribution\DeliveryOptimization` | Delivery cache (low) | ON (with admin) |
| `%SYSTEMROOT%\Prefetch` | Boot-performance trade-off — `med` | **OFF (opt-in)** |

### B. User OS junk (no admin)

| Path | Notes | Default |
|---|---|---|
| `%TEMP%` | Existing target + **age filter (≥1 day)** + exclusions | ON |
| `%LOCALAPPDATA%\Microsoft\Windows\WER` | User error reports (low) | ON |
| `%LOCALAPPDATA%\Microsoft\Windows\INetCache` | IE/WebView cache (low) | ON |
| `%LOCALAPPDATA%\CrashDumps` | App crash dumps (low) | ON |
| Recycle Bin | Via `SHEmptyRecycleBin` (low) | *(opt-in)* |
| Explorer `thumbcache_*.db` | Needs Explorer closed — `med` | *(opt-in)* |
| Browser caches (Chrome/Edge/Firefox profile `Cache`) | Browser must be closed — `med` | *(opt-in)* |

### C. Python dev junk (no admin)

| Path | Notes | Default |
|---|---|---|
| `%LOCALAPPDATA%\pip\Cache` | `pip cache purge` equivalent (low) | ON |
| `%LOCALAPPDATA%\uv\cache` | uv package cache (low) | ON |
| `%LOCALAPPDATA%\pypoetry\Cache` | Poetry cache (low) | ON |
| `%USERPROFILE%\.cache\pip` | Older pip layouts (low) | ON |

### D. Node/JS dev junk (no admin)

| Path | Notes | Default |
|---|---|---|
| `%LOCALAPPDATA%\npm-cache` | 247 MB found (low) | ON |
| `%USERPROFILE%\.npm` | npm logs + old cache layout (low) | ON |
| `%LOCALAPPDATA%\Yarn\Cache` | Yarn cache (low) | ON |
| `%LOCALAPPDATA%\pnpm\store` | pnpm content store (low) | ON |
| `%LOCALAPPDATA%\electron\Cache` | Electron binaries (low) | ON |
| `%LOCALAPPDATA%\electron-builder\Cache` | (low) | ON |
| `%LOCALAPPDATA%\Cypress\Cache` | (low) | ON |
| `%LOCALAPPDATA%\ms-playwright` | Playwright browsers — big re-download — `med` | *(opt-in)* |
| `%USERPROFILE%\.bun\install\cache` | Bun package cache (med) | *(opt-in)* |

### E. .NET / JVM / Go / Rust (no admin, mostly opt-in)

| Path | Notes | Default |
|---|---|---|
| `%LOCALAPPDATA%\NuGet\v3-cache` | Metadata only, cheap refresh (low) | ON |
| `%LOCALAPPDATA%\go-build` | Build cache — rebuilds are fast (low) | ON |
| `%USERPROFILE%\.gradle\caches` | Re-download cost — `med` | *(opt-in)* |
| `%USERPROFILE%\.m2\repository` | Full re-download — `high` | *(opt-in, explicit warning)* |
| `%USERPROFILE%\.nuget\packages` | Full re-download — `med` | *(opt-in)* |
| `%USERPROFILE%\.cargo\registry\cache` | Re-download — `med` | *(opt-in)* |
| `%USERPROFILE%\go\pkg\mod\cache` | Re-download — `med` | *(opt-in)* |

### F. Editors / IDEs (no admin)

| Path | Notes | Default |
|---|---|---|
| `%APPDATA%\Code\Cache`, `CachedData`, `CachedExtensionVSIXs`, `logs`, `Service Worker\CacheStorage` | VS Code (low) — also `Code - Insiders`, `VSCodium` variants | ON |
| `%LOCALAPPDATA%\JetBrains\<product>\caches` and `\index` | **Per-product subfolders only** — never the whole `JetBrains` dir (would delete settings!) — `med` | *(opt-in)* |

**Hard safety rule:** the script refuses any configured path that does not resolve inside
`%TEMP%`, `%LOCALAPPDATA%`, `%APPDATA%`, `%USERPROFILE%`, `%PROGRAMDATA%` or
`%SYSTEMROOT%\SoftwareDistribution` — protects against a bad `targets.json` wiping a real project.
Package *stores* (`.m2\repository`, `.nuget\packages`, cargo/go module caches) and anything
matching the exclusion list are never deleted unless the corresponding opt-in flag is passed.

---

## 4. Script Architecture Changes

1. **Config-driven targets** — new `targets.json` (id, path with env vars, category, `requires_admin`,
   `default_enabled`, `min_age_days`, `danger`). Users add/remove targets without touching Python code.
2. **Permission awareness**
   - Detect elevation with `ctypes.windll.shell32.IsUserAnAdmin()`.
   - Per target: probe list access first → report `SKIPPED — needs Administrator` instead of a fake "0 files".
   - `--elevate` relaunches itself via `ShellExecuteW("runas")` to clean system targets.
3. **Logging** — always append to `cleanup_log.txt` (rotated, keep last ~20 runs): per-target deleted
   count, locked skipped, access-denied skipped, MB freed, duration. Essential because `pythonw` has no console.
4. **Dry-run** — wire the existing (currently dead) `test_mode` to a real `--dry-run` flag; `--test`
   keeps doing dependency checks but also prints a permission status for every target.
5. **Age filter** — delete only files with `LastWriteTime` older than `min_age_days` (default 1 for
   `%TEMP%`, 0 for caches). Protects running installers.
6. **Exclusions** — glob list (`exclusions` in `targets.json`), e.g. keep `Temp\opencode` etc. intact.
7. **Freed-space reporting** — sum `st_size` before deletion; toast + log show "Freed 312 MB from 6 targets".
8. **Structured results** — `delete_files()` returns `{deleted_files, deleted_dirs, failed_locked,
   failed_denied, bytes_freed}` instead of a single int (fixes the mixed counter).
9. **Concurrency lock** — lock file so a slow run can't overlap the next trigger.
10. **Scheduler** — `--install` optionally registers a Task Scheduler daily task (plus logon trigger),
    fixing the "runs only once per boot" limitation.

---

## 5. Implementation Phases

**Phase 1 — Correctness & visibility (highest value)**
Permission probe + honest per-target status · log file · `--dry-run` CLI · bytes-freed reporting ·
`os.walk(onerror=...)` denied-counting · files-vs-folders counter fix · Prefetch default OFF.

**Phase 2 — Dev-tool caches**
`targets.json` loader + path-safety validation · Python/Node/VS Code/.NET targets from the catalog ·
age filter · exclusions · `--deep` flag for opt-in categories.

**Phase 3 — Admin / system targets**
Admin detection + `--elevate` relaunch · `SoftwareDistribution\Download`, system Temp, WER ·
elevation-aware summary in the toast ("735 MB needs Administrator — run with --elevate").

**Phase 4 — Polish**
Task Scheduler daily trigger · Recycle Bin · browser caches (opt-in) · JetBrains per-product cleanup ·
JSON report output · `setup.bat` gains "run elevated" option for full system cleaning.

## 6. Testing Plan

- Sandbox test: create nested temp tree incl. one locked file → assert exact deleted/failed counts.
- Non-admin vs admin comparison run on the same machine (expect: `SoftwareDistribution\Download` 735 MB only cleans with admin).
- Per new target: verify deletion, then verify the tool still works afterwards (e.g. `npm`/`pip` after cache clean — caches rebuild transparently).
- `--dry-run` must report **exactly** what a real run would delete.
- Toast + `cleanup_log.txt` verification when launched via `run_silent.bat` (pythonw, no console).

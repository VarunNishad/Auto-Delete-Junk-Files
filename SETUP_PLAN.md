# Setup Automation Plan — One-Click for Non-Tech Users

Date: 2026-10-17 · Goal: `setup.bat` succeeds on **any** Windows 10/11 PC, even with no
Python installed and zero user interaction beyond Y/N prompts.

---

## 0. Current state (verified today)

| Fact | Evidence |
|---|---|
| `setup.bat` already runs the **new v2 engine** end-to-end | Full run passed (exit 0): deps → `--test` → startup install |
| Python missing → **manual instructions + abort** | Step 1 prints help text and `exit /b 1` — the exact non-user pain point |
| `winget` available on this machine | v1.29.380, `WindowsApps\winget.exe` |
| Python here is a **per-user install** | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` → pip installs need no admin |
| `run_silent.bat` is PATH-dependent | Contains bare `pythonw ...` — must pin the absolute interpreter path |
| Started via `startup shortcut → run_silent.bat` | Works (verified launch + clean exit) |

## 1. Gap analysis — why a non-tech user's first run can fail today

| # | Failure scenario | What happens today | Required behavior |
|---|---|---|---|
| G1 | Python not installed | Hard abort with manual instructions | **Auto-install** (winget → direct-download fallback), then continue |
| G2 | Python installed but PATH broken (fresh install in same cmd session) | `where python` fails → abort | Detect via `py -3` launcher + refresh PATH from registry in-session |
| G3 | Microsoft Store `python` **stub alias** shadows real python | `python --version` prints nothing useful; some steps hang → confusing "Python found" with garbage version | Validate version output matches `Python 3.x`; treat stub as missing; fall back to `py -3` |
| G4 | No winget (older Win10/LTSC builds) | — | Fallback: download official installer from python.org and run **silent per-user install** |
| G5 | System-wide Python without admin → `pip install` permission error | Fail mid-setup | Retry with `--user`, continue |
| G6 | `pywin32_postinstall` fails without admin (system Python) | Silently ignored | Keep tolerated + honest note |
| G7 | `run_silent.bat` uses bare `pythonw` | Wrong interpreter picked if PATH changes | Pin absolute `pythonw.exe` path (engine change) |
| G8 | Non-tech user confusion about state | Raw [OK]/[FAILED] lines | Numbered friendlier screens + `setup_log.txt`, one plain-language final screen |

## 2. Proposed `setup.bat` v2 flow

```
STEP 1/5  Ensure Python
  1a  if python --version matches "Python 3."      -> PYEXE = python      [OK]
  1b  else if py -3 --version matches              -> PYEXE = py -3       [OK]
  1c  else if winget exists                        -> winget install --id Python.Python.3.14
        (--exact --scope user --silent --accept-package-agreements
         --accept-source-agreements --disable-interactivity)
        fallback id Python.Python.3 if 3.14 pkg is not found
  1d  else (no winget)                             -> PowerShell download of
        https://www.python.org/ftp/python/{VER}/python-{VER}-amd64.exe
        (pinned VER at top of script) then:
        installer /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_pip=1
  1e  After any install: refresh PATH from HKCU\Environment (+ HKLM), re-detect,
      up to 3 attempts with short delay. Never proceed with an unverified interpreter.
STEP 2/5  Upgrade pip (%PYEXE% -m pip install --upgrade pip)   [failure tolerated, retried with --user]
STEP 3/5  Install deps (winotify, winshell, pywin32)          [default install, --user retry,
                                                               then verify each import]
STEP 4/5  Verify (python auto_delete_junk_files.py --test)    [exit must be 0]
STEP 5/5  Integrate
      --install (startup shortcut; run_silent.bat now pinned to the real interpreter)
      Prompt A: "Run the first cleanup now? (Y/N)"          [runs normal profile]
      Prompt B: "Also clean system folders (needs admin UAC click)? (Y/N)"   [--elevate]
      Prompt C: "Also run daily at 12:00 even if PC stays on? (Y/N)"         [schtasks, Phase 3]
FINAL     summary screen + setup_log.txt (per-step [OK]/[FAIL]/[SKIPPED])
```

## 3. Engine (Python) changes required

| ID | Change | Why |
|---|---|---|
| E1 | `create_batch_file()` writes **absolute** `pythonw.exe` path: exchange `python.exe`→`pythonw.exe` in `sys.executable`, quoted | G7 — silent launcher can't depend on PATH |
| E2 | New flags `--install-task` / `--uninstall-task` via `schtasks /create /tn AutoDeleteJunkFilesDaily /tr <run_silent.bat> /sc daily /st 12:00 /f` (+ clean delete on uninstall.bat) | Phase 3 (Prompt C) — true daily run even if PC stays on |
| E3 | setup.bat passes nothing special; engine already self-checks deps | — |

## 4. Robustness rules for the batch

- One resolution point `%PYEXE%` used everywhere (`%PYEXE% -m pip ...`); never bare `python` after step 1.
- Winget flags include `--disable-interactivity` so a UAC prompt can never freeze an unattended run (per-user install needs no admin).
- Direct-download fallback saves installer to `%TEMP%\python-setup\`; verifies download size > 20 MB before spawning; cleans up after.
- Every step writes to `setup_log.txt`; failures show one friendly screen, not a stack of internals.
- Re-running setup is safe/idempotent (pip is idempotent; shortcut & task use `/f` overwrite).
- If auto-install ultimately fails: single screen with two buttons' worth of instructions (download link + "tick Add to PATH"), then pause+exit.

## 5. Verification plan

| ID | Test | How |
|---|---|---|
| T1 | Happy path re-run (Python present) | non-interactive `setup.bat < input(Y,A,B answers)`, expect exit 0 |
| T2 | PATH-broken python (G2) | run cmd with PATH stripped of Python dirs → must resolve via `py -3` + registry refresh |
| T3 | Missing Python + winget present (G1/G4) | verify `winget show Python.Python.3.14` availability & substitute command; full auto-install only on a disposable VM (never installed on the user's machine as a test!) |
| T4 | run_silent.bat pinning | inspect file: absolute quoted pythonw path; launch and confirm clean exit |
| T5 | Task scheduler round-trip (E2) | `--install-task` → `schtasks /query` → `--uninstall-task` → confirm gone |
| T6 | Idempotency | run setup twice: no duplicate shortcuts, no stale tasks, exit 0 both times |

## 6. Phasing

- **Phase 1 (the user's ask):** `ensure_python` (winget + direct-download fallback), `%PYEXE%` pipeline, G2/G3 detection logic, E1 pinning, setup_log.txt. — **DONE 2026-10-17**
- **Phase 2:** `--user` fallback retries + per-package import verification + friendlier failure screens. — **DONE 2026-10-17** (also ensurepip bootstrap if pip itself is missing)
- **Phase 3:** Task Scheduler flags (E2) + setup Prompts A/B/C. — **DONE 2026-10-17** (`--install-task [HH:MM]` / `--uninstall-task`, locale-safe remove via pre-query, invalid-time guard, uninstall.bat removes the task even when Python is gone; setup prompts A/B/C in step 5)
- **Phase 4:** pin dependency versions in `requirements.txt`, README "for non-tech users" quickstart, winget-availability reminder in README. — **DONE 2026-10-17**

**Not testable on this machine without danger:** G1's actual winget *install* of Python (we won't uninstall/reinstall the user's Python); T3's direct-download path (same reason). Both branches get dry-verified (command construction, URL check, PATH-refresh logic) and the winget path is validated with `winget show`. The T3 URL was live-verified in Phase 4 (HEAD → HTTP 200, 31.7 MB).

## 9. Phase 4 implementation record (2026-10-17)

| Check | Result |
|---|---|
| `requirements.txt` pinned: `winotify==1.1.0`, `winshell==0.6`, `pywin32==312` (versions proven on this machine) with bump instructions | ✅ |
| `pip install -r requirements.txt --dry-run` resolves all pins | ✅ exit 0 |
| **Batch gotcha found:** `call :package %%R` silently split at `=` — pip got the unpinned name! Fix: `call :package "%%R"`. | ✅ fixed + re-logged: `Installing winotify==1.1.0... [OK]` |
| Full `setup.bat` re-run after step 3 → pinned install + imports + verify + prompts, exit 0 | ✅ (T8) |
| python.org direct-download URL `python-3.14.7-amd64.exe` HEAD check | ✅ HTTP 200, 31.7 MB (clears setup's 20 MB sanity gate) |
| README: plain-words quickstart table for the 4 setup prompts, winget/no-winget fallback explanation, pinned-dependency note | ✅ |
| Plan closure: all phases 1–4 complete | ✅ |

## 7. Phase 1–2 implementation record (2026-10-17)

| Step | Result |
|---|---|
| Rewrite `setup.bat` (5-step flow, `%PYEXE%` everywhere, CRLF restored after an LF-only rewrite made `call :label` fail) | ✅ |
| `:detect_python` — `py -3` → `python` → common-dirs scan (`:locate_installed`) → winget → direct download | ✅ |
| Engine E1: `run_silent.bat` pins absolute `pythonw.exe` + `start "" /min` | ✅ content verified + clean spawn/exit |
| **T1** happy path full run | ✅ exit 0, 12 s |
| **T2** Python present but PATH stripped to `System32` | ✅ exit 0, 12 s (would have been a hard abort before) |
| `python test_engine.py` sandbox suite | ✅ 14/14 |

### Bugs found & fixed during implementation

1. **CMD deadlock** (would make setup hang forever on machines where `py`/`python`
   are missing *and* stdin is redirected): a pipeline whose left command does not
   exist (`py -3 --version 2>&1 | findstr ...`) never completes. Fix: every
   pipeline is now guarded by `where` first, so a not-found command is never
   executed; plus the Microsoft Store `python` stub in `WindowsApps` is detected
   via path check and skipped (it used to be "runnable" but prints nothing).
2. **LF-only line endings** in the rewritten `.bat` made `call :detect_python`
   fail with "cannot find the batch label" on the first label — fixed by writing
   the file with CRLF.
3. Engine hardening (user request: "add error handling"):
   - one target's unexpected exception no longer aborts the sweep — it is logged
     with traceback into `cleanup_log.txt`, shown as `ERROR: ... — see cleanup_log.txt`;
   - unreadable `getmtime` no longer crashes an aged-file sweep (treated as
     deletable-candidate; removal still classifies locked/denied honestly);
   - `__main__` wraps everything: unhandled exceptions are logged (vital for
     `pythonw` runs with no console), `Ctrl+C` prints a clean "nothing else was
     deleted" and logs;
   - malformed `paths` template in `targets.json` is skipped with a printed
     warning instead of killing the run.

## 8. Phase 3 implementation record (2026-10-17)

| Check | Result |
|---|---|
| `--uninstall-task` on a machine with no task → friendly "nothing to remove", exit 0 | ✅ |
| `--install-task` (default 12:00) → task `AutoDeleteJunkFilesDaily` created, Status Ready, runs as current user (no admin), Logon Mode: Interactive only | ✅ |
| `--install-task 18:30` → `/F` overwrite at custom time | ✅ New Run Time shows 18:30 |
| `schtasks /Run` → `Last Result: 0`, `Last Run Time` updated | ✅ quoting survives the space in "Python Auto delete script" |
| `--install-task 99:05` → rejected, exit 1, no task touched | ✅ |
| `--uninstall-task` → removed; follow-up query fails (gone) | ✅ |
| Full `setup.bat` with answers Y,Y,N,N → startup ✅, task ✅, first-cleanup N, elevate N, exit 0, all logged in `setup_log.txt` | ✅ |
| `python test_engine.py` after all engine edits | ✅ 14/14 |

"""
Sandbox tests for the rewritten cleanup engine.
Uses %TEMP%\\opencode\\junktest\\... only. Real system targets are untouched:
module path constants are redirected to the sandbox before any cleanup runs.
"""
import importlib.util
import os
import sys
import datetime
import json

SANDBOX = os.path.join(os.path.expandvars(r"%TEMP%"), "opencode", "junktest")
RES = []

# ---------------------------------------------------------------- helpers


def make(path, size=10, mtime_days_ago=0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"x" * size)
    if mtime_days_ago:
        old = (datetime.datetime.now() - datetime.timedelta(days=mtime_days_ago)).timestamp()
        os.utime(path, (old, old))


def check(name, got, want):
    ok = got == want
    RES.append((name, ok, got, want))
    print(("PASS" if ok else "FAIL") + f"  {name}  (got {got!r}, want {want!r})")


# ---------------------------------------------------------------- imports the module
spec = importlib.util.spec_from_file_location(
    "engine", os.path.join(os.path.dirname(os.path.abspath(__file__)), "auto_delete_junk_files.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# redirect all state to the sandbox
os.makedirs(SANDBOX, exist_ok=True)
m.SCRIPT_DIR = SANDBOX
m.LAST_RUN_FILE = os.path.join(SANDBOX, "last_run.txt")
m.LOG_FILE = os.path.join(SANDBOX, "cleanup_log.txt")
m.REPORT_FILE = os.path.join(SANDBOX, "cleanup_report.json")
m.CONFIG_FILE = os.path.join(SANDBOX, "targets.json")
m.BATCH_FILE = os.path.join(SANDBOX, "run_silent.bat")
m.show_notification = lambda *a, **k: True          # don't spam toasts in tests

# ---------------------------------------------------------------- sandbox fixtures
root = os.path.join(SANDBOX, "targetA")
make(os.path.join(root, "old.bin"), 100, mtime_days_ago=5)      # deletable
make(os.path.join(root, "fresh.bin"), 50)                       # protected by min_age_days=1
os.makedirs(os.path.join(root, "opencode"), exist_ok=True)      # excluded by default
make(os.path.join(root, "opencode", "keep.txt"), 10)
sub = os.path.join(root, "old_folder")
make(os.path.join(sub, "junk.log"), 30, mtime_days_ago=9)

root_locked = os.path.join(SANDBOX, "targetB")                  # pins locked-file handling
make(os.path.join(root_locked, "locked.tmp"), 10, mtime_days_ago=2)
locked = open(os.path.join(root_locked, "locked.tmp"), "rb")

root_keep = os.path.join(SANDBOX, "store_root")                 # keep_root test
make(os.path.join(root_keep, "blob.dat"), 500, mtime_days_ago=40)

jb = os.path.join(SANDBOX, "jetbrains")                         # custom jetbrains test
make(os.path.join(jb, "PyCharm2026.3", "caches", "i"), 20, mtime_days_ago=10)
make(os.path.join(jb, "PyCharm2026.3", "log", "idea.log"), 10, mtime_days_ago=10)
make(os.path.join(jb, "PyCharm2026.3", "options", "settings.xml"), 10, mtime_days_ago=10)

# ---------------------------------------------------------------- unit tests
S = m.delete_tree(root, min_age_days=1, exclusions=("opencode",))
check("files deleted (age/excl filtered)", S.files, 2)          # old.bin + junk.log
check("bytes freed", S.bytes, 130)
check("fresh file survives", os.path.exists(os.path.join(root, "fresh.bin")), True)
check("excluded dir survives", os.path.exists(os.path.join(root, "opencode", "keep.txt")), True)

S2 = m.delete_tree(root_locked)
check("locked file survives", os.path.exists(os.path.join(root_locked, "locked.tmp")), True)
check("locked counted", S2.locked, 1)

S3 = m.delete_tree(root_keep, keep_root=True)
check("package-store root kept", os.path.isdir(root_keep), True)
check("store contents gone", os.path.exists(os.path.join(root_keep, "blob.dat")), False)

if not all(r[1] for r in RES):
    sys.exit(1)

# ---------------------------------------------------------------- integration: full pipeline
# Fake catalog with TWO sandbox entries, one of them requires_admin-ish probe fail
cfg = {"exclusions_default": ["opencode"], "targets": [
    {"id": "store_root", "name": "Sandbox package store", "category": "python",
     "paths": [root_keep], "requires_admin": False, "min_age_days": 0,
     "default_enabled": True, "danger": "low", "keep_root": True},
    {"id": "jetbrains", "name": "JetBrains caches", "category": "editor",
     "paths": [jb], "requires_admin": False, "min_age_days": 7,
     "default_enabled": True, "danger": "med", "keep_root": True, "custom": "jetbrains"},
    {"id": "unsafe_root", "name": "Unsafe (must be refused)", "category": "test",
     "paths": [r"C:\\Windows\\System32"], "requires_admin": True, "min_age_days": 0,
     "default_enabled": True, "danger": "low"},
]}
with open(m.CONFIG_FILE, "w", encoding="utf-8") as f:
    json.dump(cfg, f)

print("\n--- dry run (nothing may be deleted) ---")
m.run_cleanup(dry_run=True, deep=False)
check("dry-run kept log", os.path.exists(m.LOG_FILE), True)

print("\n--- real run ---")
m.run_cleanup(dry_run=False, deep=False)

check("jetbrains caches gone",
      os.path.exists(os.path.join(jb, "PyCharm2026.3", "caches")), False)
check("jetbrains settings safe",
      os.path.exists(os.path.join(jb, "PyCharm2026.3", "options", "settings.xml")), True)
check("jetbrains log untouched",
      os.path.exists(os.path.join(jb, "PyCharm2026.3", "log", "idea.log")), True)

report = json.loads(open(m.REPORT_FILE, encoding="utf-8").read())
check("report exists", os.path.exists(m.REPORT_FILE), True)
unsafe_targets = [t for t in report["targets"] if t["id"] == "unsafe_root"]
check("unsafe path refused (not in report)", len(unsafe_targets), 0)

print("\n--- log tail ---")
print(open(m.LOG_FILE, encoding="utf-8", errors="replace").read()[-800:])
fails = [r for r in RES if not r[1]]
print(f"\nRESULT: {len(RES) - len(fails)}/{len(RES)} checks passed", )
sys.exit(1 if fails else 0)


"""
Auto Delete Junk Files
======================
Automatically deletes temporary and junk files from Windows system folders.
Runs once per day and shows a notification with the count of deleted files.

Usage:
    python auto_delete_junk_files.py           # Run cleanup
    python auto_delete_junk_files.py --test    # Test mode (no deletion)
    python auto_delete_junk_files.py --install # Add to Windows startup
    python auto_delete_junk_files.py --uninstall # Remove from startup
"""

import os
import shutil
import sys
import datetime
import json
import argparse

# Get the directory where this script is located
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ICON_PATH = os.path.join(SCRIPT_DIR, "Icon", "Autodeleteicon.ico")
LAST_RUN_FILE = os.path.join(SCRIPT_DIR, "last_run.txt")
BATCH_FILE = os.path.join(SCRIPT_DIR, "run_silent.bat")


def check_dependencies():
    """Check if all required dependencies are installed."""
    missing = []
    errors = {}
    
    try:
        from win10toast import ToastNotifier
    except ImportError as e:
        missing.append("win10toast")
        errors["win10toast"] = str(e)
    
    try:
        import winshell
    except ImportError as e:
        missing.append("winshell")
        errors["winshell"] = str(e)
    
    try:
        import win32com.client
    except ImportError as e:
        missing.append("pywin32")
        errors["pywin32"] = str(e)
    except Exception as e:
        # pywin32 can sometimes have DLL issues
        missing.append("pywin32")
        errors["pywin32"] = str(e)
    
    return missing, errors


def show_troubleshooting(missing, errors):
    """Show detailed troubleshooting steps for missing dependencies."""
    print("\n" + "=" * 60)
    print("❌ INSTALLATION TROUBLESHOOTING")
    print("=" * 60)
    
    print(f"\n🔍 Missing packages: {', '.join(missing)}")
    
    # Show specific fixes for each package
    fixes = {
        "win10toast": {
            "install": "pip install win10toast",
            "description": "Windows 10 Toast Notifications",
            "troubleshoot": [
                "If installation fails, try: pip install --upgrade pip",
                "Then retry: pip install win10toast"
            ]
        },
        "winshell": {
            "install": "pip install winshell",
            "description": "Windows Shell Operations",
            "troubleshoot": [
                "If installation fails, try: pip install --upgrade pip",
                "Then retry: pip install winshell"
            ]
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
                "You may need to run as Administrator"
            ]
        }
    }
    
    for pkg in missing:
        if pkg in fixes:
            info = fixes[pkg]
            print(f"\n📦 {pkg} - {info['description']}")
            print(f"   Install: {info['install']}")
            if pkg in errors:
                print(f"   Error: {errors[pkg]}")
            print("   Troubleshooting:")
            for step in info['troubleshoot']:
                print(f"     • {step}")
    
    print("\n" + "-" * 60)
    print("💡 QUICK FIX: Run these commands in order:")
    print("-" * 60)
    print("   pip install --upgrade pip")
    print("   pip install -r requirements.txt")
    if "pywin32" in missing:
        print("   python -m pywin32_postinstall -install")
    print("\n   If issues persist, try running Command Prompt as Administrator.")
    print("=" * 60)


def show_notification(title, message, duration=10):
    """Show a Windows toast notification."""
    from win10toast import ToastNotifier
    
    toaster = ToastNotifier()
    icon = ICON_PATH if os.path.exists(ICON_PATH) else None
    toaster.show_toast(title, message, icon_path=icon, duration=duration)


def create_startup_shortcut():
    """Create a shortcut in Windows startup folder."""
    import winshell
    import win32com.client
    
    startup_folder = winshell.startup()
    shortcut_path = os.path.join(startup_folder, "AutoDeleteJunkFiles.lnk")
    
    # Create batch file if it doesn't exist
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
    """Remove the shortcut from Windows startup folder."""
    import winshell
    
    startup_folder = winshell.startup()
    shortcut_path = os.path.join(startup_folder, "AutoDeleteJunkFiles.lnk")
    
    if os.path.exists(shortcut_path):
        os.remove(shortcut_path)
        print(f"✅ Startup shortcut removed: {shortcut_path}")
        return True
    else:
        print("ℹ️ No startup shortcut found.")
        return False


def create_batch_file():
    """Create the silent runner batch file."""
    script_name = os.path.basename(__file__)
    batch_content = f'''@echo off
start /min pythonw "{os.path.join(SCRIPT_DIR, script_name)}"
'''
    with open(BATCH_FILE, 'w') as f:
        f.write(batch_content)
    print(f"✅ Batch file created: {BATCH_FILE}")


def delete_files(folder_path, test_mode=False):
    """Delete files and folders from the specified path."""
    deleted_count = 0
    
    if not os.path.exists(folder_path):
        return 0
    
    for root, dirs, files in os.walk(folder_path, topdown=False):
        for file in files:
            file_path = os.path.join(root, file)
            try:
                if test_mode:
                    print(f"  [TEST] Would delete: {file_path}")
                else:
                    os.remove(file_path)
                deleted_count += 1
            except Exception as e:
                if not test_mode:
                    print(f"  Failed to delete {file_path}: {e}")
        
        for dir_name in dirs:
            dir_path = os.path.join(root, dir_name)
            try:
                if test_mode:
                    print(f"  [TEST] Would delete folder: {dir_path}")
                else:
                    shutil.rmtree(dir_path)
                deleted_count += 1
            except Exception as e:
                if not test_mode:
                    print(f"  Failed to delete {dir_path}: {e}")
    
    return deleted_count


def should_run_today():
    """Check if the script already ran today."""
    today = datetime.date.today()
    
    try:
        if os.path.exists(LAST_RUN_FILE):
            with open(LAST_RUN_FILE, "r") as f:
                data = json.load(f)
                last_run_date = datetime.datetime.strptime(data["date"], "%Y-%m-%d").date()
                if last_run_date == today:
                    return False, data.get("files_deleted", 0)
    except Exception:
        pass
    
    return True, 0


def update_last_run(files_deleted):
    """Update the last run file with today's date."""
    today = datetime.date.today()
    data = {
        "date": today.strftime("%Y-%m-%d"),
        "files_deleted": files_deleted
    }
    with open(LAST_RUN_FILE, "w") as f:
        json.dump(data, f)


def run_test():
    """Run in test mode to verify setup without deleting files."""
    print("=" * 50)
    print("🧪 AUTO DELETE JUNK FILES - TEST MODE")
    print("=" * 50)
    
    # Check dependencies
    print("\n📦 Checking dependencies...")
    missing, errors = check_dependencies()
    if missing:
        show_troubleshooting(missing, errors)
        return False
    print("✅ All dependencies installed!")
    
    # Check icon
    print("\n🎨 Checking icon file...")
    if os.path.exists(ICON_PATH):
        print(f"✅ Icon found: {ICON_PATH}")
    else:
        print(f"⚠️ Icon not found: {ICON_PATH}")
        print("   Notifications will work without an icon.")
    
    # Show target folders
    print("\n📁 Target folders for cleanup:")
    folders = [
        os.path.expandvars(r"%TEMP%"),
        os.path.expandvars(r"%SYSTEMROOT%\Temp"),
        os.path.expandvars(r"%SYSTEMROOT%\Prefetch")
    ]
    for folder in folders:
        if os.path.exists(folder):
            file_count = sum(len(files) for _, _, files in os.walk(folder))
            print(f"   ✅ {folder} ({file_count} files)")
        else:
            print(f"   ⚠️ {folder} (not found)")
    
    # Show test notification
    print("\n🔔 Showing test notification...")
    try:
        show_notification(
            "Test Notification",
            "Auto Delete Junk Files is set up correctly!",
            duration=5
        )
        print("✅ Notification sent successfully!")
    except Exception as e:
        print(f"❌ Notification failed: {e}")
        return False
    
    print("\n" + "=" * 50)
    print("✅ ALL TESTS PASSED! Setup is complete.")
    print("=" * 50)
    return True


def run_cleanup(test_mode=False):
    """Main cleanup function."""
    should_run, last_deleted = should_run_today()
    
    if not should_run and not test_mode:
        print(f"Script already ran today. Deleted {last_deleted} files. Exiting.")
        return
    
    folders = [
        os.path.expandvars(r"%TEMP%"),
        os.path.expandvars(r"%SYSTEMROOT%\Temp"),
        os.path.expandvars(r"%SYSTEMROOT%\Prefetch")
    ]
    
    total_deleted = 0
    for folder in folders:
        if test_mode:
            print(f"\n📁 Scanning: {folder}")
        deleted = delete_files(folder, test_mode)
        total_deleted += deleted
        if test_mode:
            print(f"   Found {deleted} items")
    
    if not test_mode:
        update_last_run(total_deleted)
        show_notification(
            "Junk Files Deleted",
            f"Total junk files deleted: {total_deleted}"
        )
    else:
        print(f"\n📊 Total items that would be deleted: {total_deleted}")


def main():
    parser = argparse.ArgumentParser(
        description="Auto Delete Junk Files - Clean up Windows temp files automatically"
    )
    parser.add_argument(
        "--test", 
        action="store_true", 
        help="Run in test mode (verify setup, no deletion)"
    )
    parser.add_argument(
        "--install", 
        action="store_true", 
        help="Add to Windows startup"
    )
    parser.add_argument(
        "--uninstall", 
        action="store_true", 
        help="Remove from Windows startup"
    )
    
    args = parser.parse_args()
    
    # Check dependencies first (except for uninstall)
    if not args.uninstall:
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
    else:
        run_cleanup()


if __name__ == "__main__":
    main()

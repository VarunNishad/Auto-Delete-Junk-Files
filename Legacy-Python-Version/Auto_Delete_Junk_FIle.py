import os
import shutil
from win10toast import ToastNotifier
import winshell
import win32com.client
import sys
import datetime
import json

def create_shortcut_in_startup():
    startup_folder = winshell.startup()
    # Use the batch file instead of the .py file to avoid IDE opening the script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    batch_path = os.path.join(script_dir, "AutoDeleteJunkFiles.bat")
    shortcut_path = os.path.join(startup_folder, "AutoDeleteJunkFiles.lnk")
    icon_path = r"C:\Users\user\Documents\Python Projects\Auto Delete Junk Files\Icon\Autodeleteicon.ico"
    
    if not os.path.exists(shortcut_path):
        shell = win32com.client.Dispatch("WScript.Shell")
        shortcut = shell.CreateShortCut(shortcut_path)
        shortcut.Targetpath = batch_path
        shortcut.WorkingDirectory = script_dir
        shortcut.IconLocation = icon_path
        shortcut.save()

def delete_files(folder_path):
    deleted_files_count = 0
    for root, dirs, files in os.walk(folder_path, topdown=False):
        for file in files:
            file_path = os.path.join(root, file)
            try:
                os.remove(file_path)
                deleted_files_count += 1
            except Exception as e:
                print(f"Failed to delete {file_path}: {e}")
        
        for dir in dirs:
            dir_path = os.path.join(root, dir)
            try:
                shutil.rmtree(dir_path)
                deleted_files_count += 1
            except Exception as e:
                print(f"Failed to delete {dir_path}: {e}")
    
    return deleted_files_count

def should_run_today():
    last_run_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "last_run.txt")
    today = datetime.date.today()
    
    try:
        if os.path.exists(last_run_file):
            with open(last_run_file, "r") as f:
                data = json.load(f)
                last_run_date = datetime.datetime.strptime(data["date"], "%Y-%m-%d").date()
                if last_run_date == today:
                    return False, data.get("files_deleted", 0)
    except:
        # If there's any error reading the file, assume we should run
        pass
    
    return True, 0

def update_last_run(files_deleted):
    last_run_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "last_run.txt")
    today = datetime.date.today()
    
    data = {
        "date": today.strftime("%Y-%m-%d"),
        "files_deleted": files_deleted
    }
    
    with open(last_run_file, "w") as f:
        json.dump(data, f)

def main():
    should_run, last_deleted_count = should_run_today()
    if not should_run:
        print(f"Script already ran today. Last run deleted {last_deleted_count} files. Exiting.")
        return

    folders = [
        os.path.expandvars(r"%TEMP%"),
        os.path.expandvars(r"%SYSTEMROOT%\Temp"),
        os.path.expandvars(r"%SYSTEMROOT%\Prefetch")
    ]
    
    total_deleted_files = 0
    for folder in folders:
        total_deleted_files += delete_files(folder)
    
    # Update the last run file with today's date and deleted files count
    update_last_run(total_deleted_files)
    
    toaster = ToastNotifier()
    toaster.show_toast(
        "Junk Files Deleted",
        f"Total junk files deleted: {total_deleted_files}",
        duration=10
    )

    # Create a shortcut in the startup folder
    create_shortcut_in_startup()

if __name__ == "__main__":
    main()
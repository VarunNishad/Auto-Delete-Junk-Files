# Auto Delete Junk Files 🗑️

Automatically clean up Windows temporary and junk files on startup. Runs silently and shows a notification with the count of deleted files.

![Windows](https://img.shields.io/badge/Platform-Windows-blue)
![Python](https://img.shields.io/badge/Python-3.7+-green)

## Features

- 🧹 **Automatic Cleanup** - Deletes temp files from Windows system folders
- 🔔 **Notifications** - Shows toast notification with deletion count
- ⏰ **Daily Limit** - Runs only once per day to save resources
- 🚀 **Startup Integration** - One-click setup to run on Windows startup
- ✅ **Test Mode** - Verify setup without deleting any files

## Target Folders

The script cleans these Windows folders:
- `%TEMP%` - User temporary files
- `%SYSTEMROOT%\Temp` - System temporary files
- `%SYSTEMROOT%\Prefetch` - Windows prefetch cache

## Quick Start

### One-Click Setup

1. Download or clone this repository
2. **Double-click `setup.bat`**
3. Follow the prompts

That's it! The script will now run automatically when you start Windows.

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
| `python auto_delete_junk_files.py` | Run cleanup now |
| `python auto_delete_junk_files.py --test` | Test mode (no deletion) |
| `python auto_delete_junk_files.py --install` | Add to Windows startup |
| `python auto_delete_junk_files.py --uninstall` | Remove from startup |

## Uninstall

**Option 1:** Double-click `uninstall.bat`

**Option 2:** Run manually:
```bash
python auto_delete_junk_files.py --uninstall
```

## Requirements

- Windows 10/11
- Python 3.7 or higher
- Administrator privileges (for cleaning system folders)

## Dependencies

- `win10toast` - Windows toast notifications
- `winshell` - Windows shell operations
- `pywin32` - Windows API access

## Troubleshooting

### Notification not showing?
- Make sure Windows notifications are enabled
- Run the `--test` command to verify setup

### Permission errors?
- Some system files may be locked
- The script will skip files it can't delete

### Script opens in IDE instead of running?
- The `setup.bat` creates a batch launcher that uses `pythonw` to run silently
- Make sure to use the `--install` option to set up correctly

## License

MIT License - Feel free to use and modify!

## Author

Created with ❤️ for a cleaner Windows experience.

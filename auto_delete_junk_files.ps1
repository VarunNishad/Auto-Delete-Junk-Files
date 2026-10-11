# ==============================================================================
# Developer Junk Files Cleaner  -  v3.0.0
# ==============================================================================
# Zero-dependency Windows cleaner for temp files, developer package caches and
# local project build artefacts.
#
# SAFETY CONTRACT (read this before editing target lists):
#   * Every delete goes through Assert-SafeTarget. Documents, Downloads,
#     Desktop, Pictures, Videos, Music, OneDrive, Program Files, ProgramData
#     and the Windows system folders are hard-blocked. A typo in a path makes
#     the script refuse, not wipe your files.
#   * Only regenerable cache/temp data is targeted. Installed software, models
#     (.gguf / HuggingFace), VM disks (.vhd/.vhdx) and source code are never
#     touched.
#   * node_modules / .venv are REPORTED ONLY, never deleted automatically.
# ==============================================================================

[CmdletBinding()]
param (
    [switch]$Test,          # dry run - show what would be removed
    [switch]$Report,        # size report only, no gates, no deletes
    [switch]$CleanDev,      # developer caches only
    [switch]$CleanSystem,   # windows temp only
    [string]$CleanProjects, # recursive project build-cache scan under this path
    [switch]$All,           # everything (default for the daily run)
    [switch]$Force,         # ignore the size gates and the once-per-day gate
    [switch]$DeepClean,     # admin: DISM component-store cleanup (WinSxS) - slow, opt-in
    [switch]$BlockChromeAIModel, # admin: stop Chrome re-downloading the 4 GB Gemini Nano model
    [switch]$EmptyRecycleBin,    # opt-in: your deleted files, so never automatic
    [switch]$CompactVHD,         # admin: shrink WSL / Docker virtual disks that never shrink themselves
    [switch]$NoAdaptive,         # disable free-space-aware gate scaling
    [switch]$NoGates,            # system caches are cleaned whatever their size (the daily run uses this)
    [switch]$DockerPrune,        # opt-in: docker system prune deletes every stopped container
    [switch]$Maintenance,        # admin: -DeepClean + -CompactVHD only, no cache cleaning (the 4-weekly task)
    [switch]$UnusedApps,         # list installed programs not started in 90+ days - never uninstalls
    [switch]$UpdateApps,         # winget upgrade --all
    [switch]$ExportTargets,
    [switch]$Install,
    [switch]$Uninstall
)

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------
$AppName      = "Developer Junk Cleaner"
$Version      = "3.2.0"
$TargetsFile = Join-Path -Path $PSScriptRoot -ChildPath "targets.json"
$IconPath     = Join-Path -Path $PSScriptRoot -ChildPath "Icon\Autodeleteicon.ico"

# A cache is only wiped when it is at least this big, so a normal day does not
# force npm/pip/uv to re-download everything. -Force overrides this.
$DefaultGateMB    = 1024
$TempFileAgeDays  = 1      # temp files newer than this are left alone (installers in flight)
$NativeMaxGB      = 2      # above this size skip the package-manager CLI and use robocopy
$NativeTimeoutSec = 90

$script:IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# setup.bat copies the script to $InstallDir, which only administrators can
# write, so nothing running as the plain user can edit what the elevated task
# executes. State files sit next to the script; the one case that cannot write
# there (installed copy, not elevated) uses the per-user folder instead.
$InstallDir  = Join-Path -Path $env:ProgramFiles -ChildPath "DeveloperJunkCleaner"
$UserDataDir = Join-Path -Path $env:LocalAppData -ChildPath "DeveloperJunkCleaner"
[void][System.IO.Directory]::CreateDirectory($UserDataDir)
$DataDir     = if (($PSScriptRoot -ieq $InstallDir) -and -not $script:IsAdmin) { $UserDataDir } else { $PSScriptRoot }
$LastRunFile = Join-Path -Path $DataDir -ChildPath "last_run.json"
$LogFile     = Join-Path -Path $DataDir -ChildPath "cleaner.log"
$HistoryFile = Join-Path -Path $DataDir -ChildPath "cleaner_history.csv"

# A non-elevated run cannot open Windows\Temp or the update caches, so it hands its
# switches to the elevated scheduled task through this file (see
# Invoke-ElevatedHandoff) and prints what the task echoes back.
$HandoffFile      = Join-Path -Path $UserDataDir -ChildPath "handoff_args.json"
$HandoffOut       = Join-Path -Path $DataDir -ChildPath "handoff_output.log"
$script:BoundArgs = $PSBoundParameters
$script:Echo      = $null
if (Test-Path -LiteralPath $HandoffFile) {
    try {
        # a stale file must not steer a later scheduled run
        if ((Get-Item -LiteralPath $HandoffFile).LastWriteTime -gt (Get-Date).AddMinutes(-5)) {
            foreach ($p in (Get-Content -Raw -LiteralPath $HandoffFile | ConvertFrom-Json).PSObject.Properties) {
                # switches only: this file is user-writable, so it must never carry a path
                if ($MyInvocation.MyCommand.Parameters.ContainsKey($p.Name) -and $p.Value -is [bool]) {
                    Set-Variable -Name $p.Name -Value $p.Value -Scope Script
                }
            }
            $script:Echo = $HandoffOut
            Set-Content -LiteralPath $HandoffOut -Value "" -ErrorAction SilentlyContinue
        }
    } catch { }
    Remove-Item -LiteralPath $HandoffFile -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
function Write-Color ([string]$Text, [string]$Color = "White") {
    if ($script:Echo) { Add-Content -LiteralPath $script:Echo -Value $Text -ErrorAction SilentlyContinue }
    switch ($Color) {
        "Green"  { Write-Host $Text -ForegroundColor Green }
        "Cyan"   { Write-Host $Text -ForegroundColor Cyan }
        "Yellow" { Write-Host $Text -ForegroundColor Yellow }
        "Red"    { Write-Host $Text -ForegroundColor Red }
        "Gray"   { Write-Host $Text -ForegroundColor DarkGray }
        default  { Write-Host $Text }
    }
}

function Write-Log ([string]$Text) {
    try {
        # Rotate at 1 MB so the log cannot become junk of its own
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
            Move-Item -Path $LogFile -Destination "$LogFile.1" -Force -ErrorAction SilentlyContinue
        }
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $LogFile -Value "$stamp  $Text" -ErrorAction SilentlyContinue
    } catch { }
}

function Format-Size ([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

$script:Results = New-Object System.Collections.ArrayList

function Add-Result ([string]$Name, [string]$Path, [int64]$Bytes, [string]$Action) {
    [void]$script:Results.Add([pscustomobject]@{
        Name = $Name; Path = $Path; Bytes = $Bytes; Action = $Action
    })
}

# ------------------------------------------------------------------------------
# Free-space aware gate scaling
#   >= 25% free  -> disk is comfortable, leave developer caches alone entirely
#   10% - 25%    -> normal per-target gates
#   <  10% free  -> disk is tight, drop every gate and clean hard
# ------------------------------------------------------------------------------
function Get-FreeSpaceInfo {
    $drive = ($env:SystemDrive).TrimEnd('\')
    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
        if ($d -and $d.Size -gt 0) {
            return @{ Free = [int64]$d.FreeSpace; Total = [int64]$d.Size
                      Percent = [Math]::Round(($d.FreeSpace / $d.Size) * 100, 1) }
        }
    } catch { }
    return @{ Free = 0; Total = 0; Percent = -1 }
}

function Get-AdaptivePolicy ([bool]$Disabled, [bool]$Forced) {
    $info = Get-FreeSpaceInfo
    $policy = @{ Info = $info; SkipDev = $false; GateScale = 1.0; Label = "normal gates" }

    if ($Forced)   { $policy.GateScale = 0.0; $policy.Label = "-Force: all gates off"; return $policy }
    if ($Disabled) { $policy.Label = "adaptive scaling disabled"; return $policy }
    if ($info.Percent -lt 0) { $policy.Label = "free space unknown, normal gates"; return $policy }

    if ($info.Percent -ge 25) {
        $policy.SkipDev = $true
        $policy.Label   = "disk comfortable, developer caches left intact"
    } elseif ($info.Percent -lt 10) {
        $policy.GateScale = 0.0
        $policy.Label     = "disk tight, all size gates dropped"
    }
    return $policy
}

function Show-ToastNotification ([string]$Title, [string]$Message) {
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.BalloonTipTitle = $Title
        $n.BalloonTipText  = $Message
        $n.Visible = $true
        $n.ShowBalloonTip(10000)
        Start-Sleep -Milliseconds 800
        $n.Dispose()
    } catch { }
}

# ------------------------------------------------------------------------------
# SAFETY: nothing is deleted unless it clears this gate
# ------------------------------------------------------------------------------
function Get-ProtectedPaths {
    $p = @()
    foreach ($f in 'MyDocuments','Desktop','MyPictures','MyVideos','MyMusic','Favorites') {
        try { $v = [Environment]::GetFolderPath($f); if ($v) { $p += $v } } catch { }
    }
    # Explicit profile-relative copies too: folder redirection (OneDrive) can make
    # GetFolderPath return a different path than the one on disk.
    foreach ($leaf in 'Downloads','OneDrive','Documents','Desktop','Pictures','Videos','Music','Source','Contacts','Links','Saved Games','Searches') {
        $p += (Join-Path $env:UserProfile $leaf)
    }
    $p += $env:ProgramFiles
    $p += ${env:ProgramFiles(x86)}
    $p += $env:ProgramData
    $p += (Join-Path $env:SystemRoot 'System32')
    $p += (Join-Path $env:SystemRoot 'SysWOW64')
    return ($p | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
}

# Locations this script must NEVER remove files from, at any depth, under any
# flag. These are not caches:
#   pagefile.sys / hiberfil.sys / swapfile.sys - live OS memory files, locked
#     by the kernel and recreated at boot. Managed from System Properties, not
#     by deletion.
#   WinSxS - the Windows component store. Most of its apparent size is hard
#     links that WinDirStat counts more than once. Microsoft: "Deleting files
#     from the WinSxS folder or deleting the entire WinSxS folder may severely
#     damage your system so that your PC might not boot and make it impossible
#     to update." Use -DeepClean, which calls the supported DISM cleanup.
function Get-NeverTouchPaths {
    $d = $env:SystemDrive
    return @(
        "$env:SystemRoot\WinSxS",
        "$env:SystemRoot\servicing",
        "$env:SystemRoot\assembly",
        "$env:SystemRoot\System32",
        "$env:SystemRoot\SysWOW64",
        "$d\pagefile.sys",
        "$d\hiberfil.sys",
        "$d\swapfile.sys",
        "$d\System Volume Information",
        "$d\Recovery",
        "$d\Boot",
        "$d\EFI",
        (Join-Path $d '$Recycle.Bin')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
}

# Exact folders that may never be the delete target even though they are roots
function Get-ExactBlockedPaths {
    return @($env:UserProfile, $env:SystemRoot, $env:LocalAppData, $env:AppData,
             "$env:UserProfile\AppData", "C:\", "C:\Users") |
           Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
}

# Project build caches live inside the user's own source folders, which the
# rule above blocks on purpose. They get a narrower gate instead: the folder
# being removed must literally be named after a known build cache.
function Assert-SafeProjectTarget ([string]$Path, [string[]]$AllowedLeafNames) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.Length -le 3 -or $full -notmatch '^[A-Za-z]:\\') { return $false }
    if (($full -split '\\').Count -lt 4) { return $false }

    $leaf = Split-Path -Path $full -Leaf
    if ($AllowedLeafNames -notcontains $leaf) {
        Write-Color "[BLOCKED] Not a recognised build cache, skipping: $full" "Red"
        Write-Log   "BLOCKED-PROJECT $full"
        return $false
    }
    foreach ($never in (Get-NeverTouchPaths)) {
        if ($full -ieq $never -or $full.StartsWith($never + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Color "[BLOCKED] Never-touch OS location: $full" "Red"
            return $false
        }
    }
    foreach ($sys in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot)) {
        if ($sys -and $full.StartsWith($sys.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Color "[BLOCKED] System location, skipping: $full" "Red"
            return $false
        }
    }
    return $true
}

function Assert-SafeTarget ([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }

    # Drive roots and absurdly short paths
    if ($full.Length -le 3) { return $false }
    if ($full -notmatch '^[A-Za-z]:\\') { return $false }

    foreach ($never in (Get-NeverTouchPaths)) {
        if ($full -ieq $never -or $full.StartsWith($never + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Color "[BLOCKED] Never-touch OS location: $full" "Red"
            Write-Log   "BLOCKED-NEVER $full"
            return $false
        }
    }

    foreach ($blocked in (Get-ExactBlockedPaths)) {
        if ($full -ieq $blocked) {
            Write-Color "[BLOCKED] Refusing to touch root path: $full" "Red"
            return $false
        }
    }

    foreach ($prot in (Get-ProtectedPaths)) {
        # target inside a protected folder, or a parent of one
        if ($full -ieq $prot -or
            $full.StartsWith($prot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $prot.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Color "[BLOCKED] Protected location, skipping: $full" "Red"
            Write-Log   "BLOCKED $full (protected: $prot)"
            return $false
        }
    }
    return $true
}

# ------------------------------------------------------------------------------
# Fast size probe (robocopy list mode - no per-file PowerShell object cost)
# ------------------------------------------------------------------------------
function Get-FolderSizeBytes ([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $probe = Join-Path $env:TEMP ("__djc_probe_" + [guid]::NewGuid().ToString("N"))
        $out = & robocopy.exe $Path $probe /L /E /NFL /NDL /NJH /BYTES /R:0 /W:0 /XJ 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*Bytes\s*:\s+(\d+)') { return [int64]$Matches[1] }
        }
    } catch { }
    # Fallback for non-English robocopy output
    try {
        $sum = 0
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, '*', 'AllDirectories')) {
            try { $sum += (New-Object System.IO.FileInfo $f).Length } catch { }
        }
        return $sum
    } catch { return 0 }
}

# ------------------------------------------------------------------------------
# Fast wipe (robocopy empty-mirror - seconds instead of hours on 500k files)
# ------------------------------------------------------------------------------
# robocopy /MIR empties the TARGET of any junction it finds in the folder being
# wiped (/XJ does not stop that), so every link is unlinked first. Deleting a
# link this way removes only the link, never what it points at.
function Remove-ReparsePoints ([string]$Path) {
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        try {
            foreach ($e in $stack.Pop().EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $e.Delete() }
                elseif ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e) }
            }
        } catch { return $false }
    }
    return $true
}

function Clear-FolderFast ([string]$Path, [bool]$RemoveRoot = $false, [bool]$PreVerified = $false) {
    if (-not $PreVerified -and -not (Assert-SafeTarget $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
    if (-not (Remove-ReparsePoints $Path)) {
        Write-Color "  [WARN] Could not clear the links inside $Path - left untouched." "Yellow"
        return $false
    }

    $empty = Join-Path $env:TEMP ("__djc_empty_" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & robocopy.exe $empty $Path /MIR /NFL /NDL /NJH /NJS /NC /NS /R:0 /W:0 /MT:16 /XJ | Out-Null
        # robocopy exit codes: 0-7 are success//informational, 8+ are real failures
        if ($LASTEXITCODE -ge 8) {
            Write-Color "  [WARN] robocopy reported failures (exit $LASTEXITCODE) on $Path" "Yellow"
            Write-Log   "ROBOCOPY-FAIL exit=$LASTEXITCODE :: $Path"
        }
    } catch {
        Write-Color "  [WARN] robocopy failed on $Path - $($_.Exception.Message)" "Yellow"
        return $false
    } finally {
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($RemoveRoot) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ------------------------------------------------------------------------------
# Age-aware temp pruning (leaves files still in use by running installers)
# ------------------------------------------------------------------------------
function Clear-TempFolder ([string]$Path, [int]$AgeDays, [bool]$TestMode) {
    $result = @{ Bytes = 0; Files = 0 }
    if (-not (Assert-SafeTarget $Path)) { return $result }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $cutoff = (Get-Date).AddDays(-1 * $AgeDays)

    # Walked by hand so a junction or symlink is never followed: a link dropped in
    # Temp that points at Documents or System32 must not get its target emptied.
    $files = New-Object System.Collections.ArrayList
    $dirs  = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        try {
            foreach ($e in $stack.Pop().EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e); [void]$dirs.Add($e.FullName) }
                else { [void]$files.Add($e) }
            }
        } catch { }
    }

    try {
        foreach ($fi in $files) {
            try {
                if ($fi.LastWriteTime -gt $cutoff) { continue }
                $size = $fi.Length
                if ($TestMode) {
                    $result.Bytes += $size; $result.Files++
                } else {
                    $fi.Delete()
                    $result.Bytes += $size; $result.Files++
                }
            } catch { }
        }
    } catch { }

    if (-not $TestMode) {
        # bottom-up removal of the directories that are now empty
        try {
            # Deepest first, so a parent is only visited once its children are gone
            foreach ($d in ($dirs | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)) {
                try {
                    if (-not [System.IO.Directory]::EnumerateFileSystemEntries($d).GetEnumerator().MoveNext()) {
                        [System.IO.Directory]::Delete($d)
                    }
                } catch { }
            }
        } catch { }
    }
    return $result
}

# ------------------------------------------------------------------------------
# Optional native package-manager cleaners (used only for small caches)
# ------------------------------------------------------------------------------
function Invoke-NativeCleaner ([string]$Exe, [string]$Arguments, [int]$TimeoutSec = $NativeTimeoutSec) {
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        $so = [System.IO.Path]::GetTempFileName()
        $se = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
                           -RedirectStandardOutput $so -RedirectStandardError $se
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return $false
        }
        return ($p.ExitCode -eq 0)
    } catch { return $false }
    finally {
        foreach ($f in @($so, $se)) {
            if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ------------------------------------------------------------------------------
# Target catalogue
#   Kind : Temp   -> age-filtered file prune
#          Cache  -> robocopy empty-mirror (with optional native cleaner first)
#          Glob   -> wildcard expansion, then Cache handling on each match
#   GateMB : only cleaned when at least this large (0 = always)
# ------------------------------------------------------------------------------
function Get-Targets ([string]$Group) {
    $t = @()

    if ($Group -eq 'System') {
        $t += [pscustomobject]@{ Name='User Temp';              Path=$env:TEMP;                                             Kind='Temp';  GateMB=0;    Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Windows Temp';           Path="$env:SystemRoot\Temp";                                Kind='Temp';  GateMB=0;    Admin=$true;  Exe=$null;  Args=$null }
        # Prefetch is deliberately not a target: it is a few MB, clearing it slows
        # app launches, and it is the launch history that -UnusedApps reads.
        $t += [pscustomobject]@{ Name='Crash Dumps';            Path="$env:LocalAppData\CrashDumps";                        Kind='Cache'; GateMB=0;    Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Windows Error Reports';  Path="$env:LocalAppData\Microsoft\Windows\WER";             Kind='Cache'; GateMB=0;    Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='IE/Edge INetCache';      Path="$env:LocalAppData\Microsoft\Windows\INetCache";       Kind='Cache'; GateMB=0;    Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Explorer thumb cache';   Path="$env:LocalAppData\Microsoft\Windows\Explorer";        Kind='Cache'; GateMB=256;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Windows Update download';Path="$env:SystemRoot\SoftwareDistribution\Download";       Kind='Cache'; GateMB=512;  Admin=$true;  Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Delivery Optimization';  Path="$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"; Kind='Cache'; GateMB=512; Admin=$true; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='CBS logs';               Path="$env:SystemRoot\Logs\CBS";                            Kind='Cache'; GateMB=128;  Admin=$true;  Exe=$null;  Args=$null }
        # Browsers - locked files are skipped automatically while the browser runs
        # Gemini Nano on-device model. ~4 GB of weights.bin. Safe to delete, but
        # Chrome re-downloads it while the feature is on - see -BlockChromeAIModel.
        $t += [pscustomobject]@{ Name='Chrome on-device AI model'; Path="$env:LocalAppData\Google\Chrome\User Data\OptGuideOnDeviceModel";   Kind='Cache'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Edge on-device AI model';   Path="$env:LocalAppData\Microsoft\Edge\User Data\OptGuideOnDeviceModel";  Kind='Cache'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Claude desktop cache';   Path="$env:AppData\Claude\Cache";                              Kind='Cache'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Claude code cache';      Path="$env:AppData\Claude\Code Cache";                         Kind='Cache'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Chrome cache';         Path="$env:LocalAppData\Google\Chrome\User Data\*\Cache";      Kind='Glob'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Chrome code cache';      Path="$env:LocalAppData\Google\Chrome\User Data\*\Code Cache"; Kind='Glob'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Edge cache';             Path="$env:LocalAppData\Microsoft\Edge\User Data\*\Cache";     Kind='Glob'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='Edge code cache';        Path="$env:LocalAppData\Microsoft\Edge\User Data\*\Code Cache";Kind='Glob'; GateMB=256; Admin=$false; Exe=$null; Args=$null }
    }

    if ($Group -eq 'Dev') {
        # --- Python -----------------------------------------------------------
        $t += [pscustomobject]@{ Name='uv cache';           Path="$env:LocalAppData\uv\cache";              Kind='Cache'; GateMB=1024; Admin=$false; Exe='uv';   Args='cache clean'; Prune='cache prune' }
        $t += [pscustomobject]@{ Name='uv cache (home)';    Path="$env:UserProfile\.cache\uv";              Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='pip cache';          Path="$env:LocalAppData\pip\cache";             Kind='Cache'; GateMB=512;  Admin=$false; Exe='pip';  Args='cache purge' }
        $t += [pscustomobject]@{ Name='Poetry cache';       Path="$env:LocalAppData\pypoetry\Cache";        Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        # --- Node -------------------------------------------------------------
        $t += [pscustomobject]@{ Name='npm cache';          Path="$env:LocalAppData\npm-cache\_cacache";    Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='npm cache (home)';   Path="$env:UserProfile\.npm\_cacache";          Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Yarn cache';         Path="$env:LocalAppData\Yarn\Cache";            Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='npm npx cache';      Path="$env:LocalAppData\npm-cache\_npx";        Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='node-gyp headers';   Path="$env:LocalAppData\node-gyp";              Kind='Cache'; GateMB=128;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='pnpm store';         Path="$env:LocalAppData\pnpm-store";            Kind='Cache'; GateMB=1024; Admin=$false; Exe='pnpm'; Args='store prune'; Prune='store prune' }
        $t += [pscustomobject]@{ Name='pnpm cache';         Path="$env:LocalAppData\pnpm-cache";            Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Bun install cache';  Path="$env:LocalAppData\bun\install\cache";     Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Deno cache';         Path="$env:LocalAppData\deno";                  Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        # --- Build tool browsers / binaries (re-downloaded on demand) ----------
        $t += [pscustomobject]@{ Name='Electron cache';     Path="$env:LocalAppData\electron\Cache";        Kind='Cache'; GateMB=256;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='electron-builder';   Path="$env:LocalAppData\electron-builder\Cache";Kind='Cache'; GateMB=256;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Cypress cache';      Path="$env:LocalAppData\Cypress\Cache";         Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Playwright browsers';Path="$env:LocalAppData\ms-playwright";         Kind='Cache'; GateMB=2048; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Puppeteer cache';    Path="$env:UserProfile\.cache\puppeteer";       Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        # --- Other ecosystems -------------------------------------------------
        $t += [pscustomobject]@{ Name='NuGet http cache';   Path="$env:LocalAppData\NuGet\v3-cache";        Kind='Cache'; GateMB=256;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='NuGet plugin cache'; Path="$env:LocalAppData\NuGet\plugins-cache";   Kind='Cache'; GateMB=128;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Cargo registry cache';Path="$env:UserProfile\.cargo\registry\cache"; Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Cargo registry src'; Path="$env:UserProfile\.cargo\registry\src";    Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Go build cache';     Path="$env:LocalAppData\go-build";              Kind='Cache'; GateMB=512;  Admin=$false; Exe='go';   Args='clean -cache' }
        $t += [pscustomobject]@{ Name='Gradle caches';      Path="$env:UserProfile\.gradle\caches";         Kind='Cache'; GateMB=1024; Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Gradle wrapper dists';Path="$env:UserProfile\.gradle\wrapper\dists";  Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='Composer cache';    Path="$env:LocalAppData\Composer";              Kind='Cache'; GateMB=512;  Admin=$false; Exe=$null;  Args=$null }
        # --- Editors ----------------------------------------------------------
        $t += [pscustomobject]@{ Name='VS Code CachedData'; Path="$env:AppData\Code\CachedData";            Kind='Cache'; GateMB=256;  Admin=$false; Exe=$null;  Args=$null }
        $t += [pscustomobject]@{ Name='VS Code extension VSIX'; Path="$env:AppData\Code\CachedExtensionVSIXs"; Kind='Cache'; GateMB=128; Admin=$false; Exe=$null; Args=$null }
        $t += [pscustomobject]@{ Name='VS Code logs';       Path="$env:AppData\Code\logs";                  Kind='Cache'; GateMB=128;  Admin=$false; Exe=$null;  Args=$null }
    }

    return $t
}

# ------------------------------------------------------------------------------
# Target processing
# ------------------------------------------------------------------------------
function Invoke-Target ($Target, [bool]$TestMode, [bool]$ReportMode, [bool]$IgnoreGate, [double]$GateScale = 1.0) {
    $out = @{ Bytes = 0; Cleaned = $false }

    # Expand wildcard targets into concrete folders
    if ($Target.Kind -eq 'Glob') {
        $globHits = @()
        try { $globHits = Get-ChildItem -Path $Target.Path -Directory -Force -ErrorAction SilentlyContinue } catch { }
        foreach ($m in $globHits) {
            $sub = $Target.PSObject.Copy()
            $sub.Path = $m.FullName
            $sub.Kind = 'Cache'
            $r = Invoke-Target -Target $sub -TestMode $TestMode -ReportMode $ReportMode -IgnoreGate $IgnoreGate -GateScale $GateScale
            $out.Bytes += $r.Bytes
            if ($r.Cleaned) { $out.Cleaned = $true }
        }
        return $out
    }

    # admin check first: Test-Path on an ACL-locked system folder throws instead of returning false
    if ($Target.Admin -and -not $script:IsAdmin) {
        Write-Color ("  [SKIP]  {0,-24} needs administrator" -f $Target.Name) "Gray"
        return $out
    }
    if (-not (Test-Path -LiteralPath $Target.Path)) { return $out }
    if (-not (Assert-SafeTarget $Target.Path)) { return $out }

    $size   = Get-FolderSizeBytes $Target.Path
    $sizeMB = [Math]::Round($size / 1MB, 0)

    if ($ReportMode) {
        # Collected and printed sorted by size at the end, not in catalogue order
        if ($size -gt 0) { Add-Result -Name $Target.Name -Path $Target.Path -Bytes $size -Action 'reclaimable' }
        $out.Bytes = $size
        return $out
    }

    $gate = if ($IgnoreGate) { 0 } else { [int][Math]::Round($Target.GateMB * $GateScale) }
    if ($size -eq 0) { return $out }

    # Prune removes only what no project references, so nothing in use is downloaded
    # again. The full wipe below stays for a tight disk or -Force (gate 0), or when
    # the tool is not installed.
    if ($Target.Prune -and $gate -gt 0 -and (Get-Command $Target.Exe -ErrorAction SilentlyContinue)) {
        $how = "$($Target.Exe) $($Target.Prune)"
        if ($TestMode) {
            Write-Color ("  [DRY]   {0,-24} {1,10}  would prune unused entries  ({2})" -f $Target.Name, (Format-Size $size), $how) "Yellow"
            return $out
        }
        if (Invoke-NativeCleaner -Exe $Target.Exe -Arguments $Target.Prune -TimeoutSec 900) {
            $out.Bytes   = [Math]::Max(0, $size - (Get-FolderSizeBytes $Target.Path))
            $out.Cleaned = $true
            Write-Color ("  [PRUNE] {0,-24} {1,10}  reclaimed  ({2})" -f $Target.Name, (Format-Size $out.Bytes), $how) "Green"
            Write-Log ("PRUNE {0} {1} bytes via {2} :: {3}" -f $Target.Name, $out.Bytes, $how, $Target.Path)
            Add-Result -Name $Target.Name -Path $Target.Path -Bytes $out.Bytes -Action 'cleaned'
            return $out
        }
    }

    if ($sizeMB -lt $gate) {
        Write-Color ("  [KEEP]  {0,-24} {1,10}  (under {2} MB gate)" -f $Target.Name, (Format-Size $size), $gate) "Gray"
        Add-Result -Name $Target.Name -Path $Target.Path -Bytes $size -Action 'kept'
        return $out
    }

    if ($TestMode) {
        Write-Color ("  [DRY]   {0,-24} {1,10}  would be reclaimed" -f $Target.Name, (Format-Size $size)) "Yellow"
        Add-Result -Name $Target.Name -Path $Target.Path -Bytes $size -Action 'would clean'
        $out.Bytes = $size
        return $out
    }

    # Native cleaner first for small caches, robocopy for anything big
    $usedNative = $false
    if ($Target.Exe -and ($size -lt ($NativeMaxGB * 1GB))) {
        $usedNative = Invoke-NativeCleaner -Exe $Target.Exe -Arguments $Target.Args
    }
    if (-not $usedNative) {
        [void](Clear-FolderFast -Path $Target.Path -RemoveRoot:$false)
    }

    $after      = Get-FolderSizeBytes $Target.Path
    $reclaimed  = [Math]::Max(0, $size - $after)
    $out.Bytes  = $reclaimed
    $out.Cleaned = $true

    $how = if ($usedNative) { $Target.Exe } else { "robocopy" }
    Write-Color ("  [CLEAN] {0,-24} {1,10}  reclaimed  ({2})" -f $Target.Name, (Format-Size $reclaimed), $how) "Green"
    Write-Log ("CLEAN {0} {1} bytes via {2} :: {3}" -f $Target.Name, $reclaimed, $how, $Target.Path)
    Add-Result -Name $Target.Name -Path $Target.Path -Bytes $reclaimed -Action 'cleaned'
    if ($Target.Name -like '*on-device AI model*') {
        Write-Color "          ^ the browser will re-download this. Run -BlockChromeAIModel once (as admin) to stop it." "Gray"
    }
    return $out
}

function Invoke-Group ([string]$Group, [bool]$TestMode, [bool]$ReportMode, [bool]$IgnoreGate, [double]$GateScale = 1.0) {
    $total = 0
    $label = if ($Group -eq 'System') { "Windows temp and system caches" } else { "Developer package caches" }
    Write-Color "" ; Write-Color "[$($Group.ToUpper())] $label" "Cyan"

    foreach ($t in (Import-TargetOverrides (Get-Targets $Group))) {
        if ($t.Kind -eq 'Temp' -and -not $ReportMode) {
            if ($t.Admin -and -not $script:IsAdmin) {
                Write-Color ("  [SKIP]  {0,-24} needs administrator" -f $t.Name) "Gray"
                continue
            }
            if (-not (Test-Path -LiteralPath $t.Path)) { continue }
            $r = Clear-TempFolder -Path $t.Path -AgeDays $TempFileAgeDays -TestMode $TestMode
            if ($r.Bytes -gt 0) {
                Add-Result -Name $t.Name -Path $t.Path -Bytes $r.Bytes -Action $(if ($TestMode) { 'would clean' } else { 'cleaned' })
            }
            if ($r.Files -gt 0) {
                $verb = if ($TestMode) { "would free" } else { "reclaimed" }
                Write-Color ("  [CLEAN] {0,-24} {1,10}  $verb ({2} files)" -f $t.Name, (Format-Size $r.Bytes), $r.Files) "Green"
                Write-Log ("TEMP {0} {1} bytes {2} files" -f $t.Name, $r.Bytes, $r.Files)
            }
            $total += $r.Bytes
            continue
        }
        $res = Invoke-Target -Target $t -TestMode $TestMode -ReportMode $ReportMode -IgnoreGate $IgnoreGate -GateScale $GateScale
        $total += $res.Bytes
    }
    return $total
}

# ------------------------------------------------------------------------------
# Project workspace scanner (build artefacts only - never source, never deps)
# ------------------------------------------------------------------------------
function Clean-DeveloperProjects ([string]$RootDir, [bool]$TestMode) {
    $total = 0
    if (-not (Test-Path -LiteralPath $RootDir)) {
        Write-Color "[ERROR] Project directory not found: $RootDir" "Red"
        return 0
    }

    Write-Color "" ; Write-Color "[PROJECTS] Scanning build artefacts under: $RootDir" "Cyan"

    $wipeNames  = @('__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache',
                    '.turbo', '.ipynb_checkpoints', '.parcel-cache', '.nx')
    $reportOnly = @('node_modules', '.venv', 'venv', 'env')
    $stale      = @()

    $dirs = Get-ChildItem -Path $RootDir -Recurse -Directory -Force -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        $name = $dir.Name

        # Never descend into things we only report on
        if ($reportOnly -contains $name) {
            if ($dir.LastWriteTime -lt (Get-Date).AddDays(-90)) {
                $stale += [pscustomobject]@{ Path = $dir.FullName; Age = [int]((Get-Date) - $dir.LastWriteTime).TotalDays }
            }
            continue
        }

        $target = $null
        if ($wipeNames -contains $name) {
            $target = $dir.FullName
        } elseif ($name -eq '.next' -or $name -eq '.nuxt') {
            $sub = Join-Path $dir.FullName 'cache'
            if (Test-Path -LiteralPath $sub) { $target = $sub }
        }
        if (-not $target) { continue }
        if (-not (Assert-SafeProjectTarget -Path $target -AllowedLeafNames ($wipeNames + @('cache')))) { continue }

        $size = Get-FolderSizeBytes $target
        if ($size -eq 0) { continue }

        if ($TestMode) {
            Write-Color ("  [DRY]   {0,10}  {1}" -f (Format-Size $size), $target) "Yellow"
        } else {
            $removeRoot = ($wipeNames -contains $name)
            [void](Clear-FolderFast -Path $target -RemoveRoot:$removeRoot -PreVerified:$true)
            Write-Color ("  [CLEAN] {0,10}  {1}" -f (Format-Size $size), $target) "Green"
            Write-Log  ("PROJECT {0} {1} bytes" -f $target, $size)
        }
        $total += $size
    }

    if ($stale.Count -gt 0) {
        Write-Color "" ; Write-Color "[REVIEW] Dependency folders untouched for 90+ days (NOT deleted):" "Yellow"
        foreach ($s in ($stale | Select-Object -First 25)) {
            Write-Color ("  {0,4} days  {1}" -f $s.Age, $s.Path) "Gray"
        }
        Write-Color "  Delete any you no longer need by hand." "Gray"
    }

    return $total
}

# ------------------------------------------------------------------------------
# Install / uninstall
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Report-only findings. Nothing here is ever deleted automatically.
# ------------------------------------------------------------------------------
function Show-WindowsOld {
    $path = Join-Path $env:SystemDrive 'Windows.old'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $size = Get-FolderSizeBytes $path
    Write-Color ""
    Write-Color "[FOUND] Previous Windows installation: $(Format-Size $size)" "Yellow"
    Write-Color "  $path" "Gray"
    Write-Color "  This script will not touch it - the files are owned by TrustedInstaller and" "Gray"
    Write-Color "  removing them by hand breaks the ability to roll back a feature update." "Gray"
    Write-Color "  Remove it properly: Settings > System > Storage > Temporary files >" "Gray"
    Write-Color "  'Previous Windows installation(s)', or run cleanmgr.exe as administrator." "Gray"
    Write-Color "  Windows deletes it on its own about 10 days after the update." "Gray"
    return $size
}

function Show-LargeUserFiles {
    $folders = @((Join-Path $env:UserProfile 'Downloads'), (Join-Path $env:UserProfile 'Desktop'))
    $hits = @()
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $hits += Get-ChildItem -Path $f -File -Recurse -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -gt 100MB -or $_.LastWriteTime -lt (Get-Date).AddDays(-180) } |
                     Where-Object { $_.Length -gt 20MB }
        } catch { }
    }
    if ($hits.Count -eq 0) { return }

    $sum = ($hits | Measure-Object -Property Length -Sum).Sum
    Write-Color ""
    Write-Color "[REVIEW] Large or long-untouched files in Downloads and Desktop: $(Format-Size $sum) across $($hits.Count) files" "Yellow"
    Write-Color "  These are YOUR files. Nothing here is deleted, ever - listed so you can decide." "Gray"
    foreach ($h in ($hits | Sort-Object Length -Descending | Select-Object -First 15)) {
        $age = [int]((Get-Date) - $h.LastWriteTime).TotalDays
        Write-Color ("  {0,10}  {1,5}d  {2}" -f (Format-Size $h.Length), $age, $h.FullName) "Gray"
    }
}

# ------------------------------------------------------------------------------
# Unused software - a recommendation, never an uninstall.
# Prefetch is the launch history: Windows rewrites NAME.EXE-HASH.pf each time
# that exe starts. It holds about 1024 programs, so "no record" can also mean
# the record aged out. The folder is admin-only, hence the elevated task.
# ------------------------------------------------------------------------------
function Get-UnusedApps ([int]$Days = 90, [string]$PrefetchDir = "$env:SystemRoot\Prefetch") {
    $lastRun = @{}
    try {
        foreach ($pf in [System.IO.Directory]::EnumerateFiles($PrefetchDir, '*.pf')) {
            $fi  = New-Object System.IO.FileInfo $pf
            $exe = ($fi.Name -replace '-[0-9A-F]{8}\.pf$', '').ToUpper()
            if (-not $lastRun.ContainsKey($exe) -or $lastRun[$exe] -lt $fi.LastWriteTime) { $lastRun[$exe] = $fi.LastWriteTime }
        }
    } catch { return $null }
    # not elevated, the folder just reads as empty: no history means no verdict, not "unused"
    if ($lastRun.Count -eq 0) { return $null }

    $cutoff  = (Get-Date).AddDays(-1 * $Days)
    # uninstallers and background updaters run on their own and would make an unused program look used
    $helpers = 'unins|update|crash|helper|setup|install|elevat|notif|report'
    $keys    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $out = @()
    foreach ($a in (Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)) {
        if (-not $a.DisplayName -or $a.SystemComponent -eq 1 -or -not $a.UninstallString) { continue }
        # other programs depend on these; they are never started by hand
        if ($a.DisplayName -match 'Redistributable|Runtime|Driver|SDK|Bonjour') { continue }
        # installed inside the window: too new to judge
        if ("$($a.InstallDate)" -match '^\d{8}$' -and "$($a.InstallDate)" -gt $cutoff.ToString('yyyyMMdd')) { continue }

        $loc = "$($a.InstallLocation)".Trim('"').TrimEnd('\')
        if (-not $loc -and $a.DisplayIcon) {
            try { $loc = Split-Path -Parent (("$($a.DisplayIcon)" -replace ',-?\d+$', '').Trim('"')) } catch { }
        }
        # a shallow or system path would claim every program's exe as its own
        if (-not $loc -or ($loc -split '\\').Count -lt 3 -or
            $loc.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $loc)) { continue }

        $exes = @(Get-ChildItem -LiteralPath $loc -Filter *.exe -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch $helpers })
        if ($exes.Count -eq 0) { continue }   # driver or runtime: nothing to launch, cannot be judged

        $last = $null
        foreach ($e in $exes) {
            $k = $e.Name.ToUpper()
            if ($k.Length -gt 29) { $k = $k.Substring(0, 29) }   # Prefetch truncates long names
            if ($lastRun.ContainsKey($k) -and (-not $last -or $lastRun[$k] -gt $last)) { $last = $lastRun[$k] }
        }
        if ($last -and $last -gt $cutoff) { continue }
        $out += [pscustomobject]@{ Name = [string]$a.DisplayName; LastRun = $last; Bytes = [int64]$a.EstimatedSize * 1KB; Path = $loc }
    }
    return ,@($out | Sort-Object -Property Name -Unique)
}

function Show-UnusedApps {
    Write-Color ""
    $apps = Get-UnusedApps
    if ($null -eq $apps) {
        Write-Color "[APPS]  The unused-software check reads Prefetch, which needs the elevated task. Run setup.bat once." "Yellow"
        return
    }
    if ($apps.Count -eq 0) {
        Write-Color "[APPS]  Every trackable program was started in the last 90 days. Keep them all." "Green"
        return
    }
    Write-Color "[APPS]  $($apps.Count) installed program(s) not started in 90+ days. Recommendation only - nothing is uninstalled." "Yellow"
    Write-Color "  Check each one first: a tool that only runs in the background can look unused." "Gray"
    Write-Color ("  {0,-10} {1,10}   {2}" -f "LAST RUN", "SIZE", "PROGRAM") "Cyan"
    foreach ($a in ($apps | Sort-Object -Property Bytes -Descending)) {
        $when = if ($a.LastRun) { "{0}d ago" -f [int]((Get-Date) - $a.LastRun).TotalDays } else { "no record" }
        Write-Color ("  {0,-10} {1,10}   {2}" -f $when, (Format-Size $a.Bytes), $a.Name) "Gray"
    }
    Write-Color "  Uninstall what you do not need from Settings > Apps > Installed apps. Everything not listed: keep." "Gray"
}

# ------------------------------------------------------------------------------
# Recycle Bin - opt-in only, because it holds files you deleted on purpose.
# Emptied through the shell API, never by deleting from $Recycle.Bin directly.
# ------------------------------------------------------------------------------
function Get-RecycleBinSize {
    try {
        $p = Join-Path $env:SystemDrive '$Recycle.Bin'
        if (Test-Path -LiteralPath $p) { return (Get-FolderSizeBytes $p) }
    } catch { }
    return 0
}

function Clear-RecycleBinSafely ([bool]$TestMode) {
    $size = Get-RecycleBinSize
    if ($size -le 0) { Write-Color "[INFO] Recycle Bin is already empty." "Gray"; return 0 }
    if ($TestMode) {
        Write-Color "  [DRY]   Recycle Bin              $(Format-Size $size)  would be emptied" "Yellow"
        return $size
    }
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Color "  [CLEAN] Recycle Bin              $(Format-Size $size)  emptied" "Green"
        Write-Log ("RECYCLEBIN {0} bytes" -f $size)
        return $size
    } catch {
        Write-Color "  [WARN] Could not empty the Recycle Bin: $($_.Exception.Message)" "Yellow"
        return 0
    }
}

# ------------------------------------------------------------------------------
# WSL / Docker virtual disks. A .vhdx grows when the VM writes and never shrinks
# again when files inside are deleted, so the space stays claimed on the host.
# diskpart's "compact vdisk" is the supported way to give it back.
# ------------------------------------------------------------------------------
function Get-VirtualDiskCandidates {
    $found = @()
    $roots = @("$env:LocalAppData\Packages", "$env:LocalAppData\Docker\wsl", "$env:UserProfile\AppData\Local\Docker\wsl")
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        try {
            $found += Get-ChildItem -Path $r -Filter '*.vhdx' -Recurse -File -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    return ($found | Sort-Object -Property FullName -Unique)
}

function Invoke-CompactVHD ([bool]$TestMode, [bool]$Unattended = $false) {
    $disks = Get-VirtualDiskCandidates
    if ($disks.Count -eq 0) { Write-Color "[INFO] No WSL or Docker virtual disks found." "Gray"; return 0 }

    Write-Color ""
    Write-Color "[VHDX]  Found $($disks.Count) virtual disk(s):" "Cyan"
    foreach ($d in $disks) { Write-Color ("  {0,10}  {1}" -f (Format-Size $d.Length), $d.FullName) "Gray" }

    if ($TestMode) {
        Write-Color "  [DRY] Would shut down WSL and compact each disk. Actual reclaim depends on free space inside." "Yellow"
        return 0
    }
    if (-not $script:IsAdmin) {
        Write-Color "[SKIP]  Compacting virtual disks needs an elevated PowerShell." "Yellow"
        return 0
    }

    # wsl --shutdown kills every running distro and container, so a scheduled run never does it under you
    if ($Unattended -and (Get-Process -Name vmmem, vmmemWSL -ErrorAction SilentlyContinue)) {
        Write-Color "[SKIP]  WSL or Docker is running - a scheduled run will not shut it down." "Yellow"
        Write-Log   "VHDX skipped, WSL/Docker running"
        return 0
    }

    Write-Color "[VHDX]  Shutting down WSL and Docker's WSL backend first..." "Yellow"
    if (Get-Command wsl -ErrorAction SilentlyContinue) { & wsl.exe --shutdown 2>$null | Out-Null }
    Start-Sleep -Seconds 5

    $reclaimed = 0
    foreach ($d in $disks) {
        $before = $d.Length
        $script  = Join-Path $env:TEMP ("__djc_dp_" + [guid]::NewGuid().ToString("N") + ".txt")
        @(
            "select vdisk file=`"$($d.FullName)`""
            "attach vdisk readonly"
            "compact vdisk"
            "detach vdisk"
            "exit"
        ) | Set-Content -Path $script -Encoding ASCII -Force
        try {
            & diskpart.exe /s $script 2>$null | Out-Null
        } catch {
            Write-Color "  [WARN] diskpart failed on $($d.Name): $($_.Exception.Message)" "Yellow"
        } finally {
            Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
        }
        $after = 0
        try { $after = (Get-Item -LiteralPath $d.FullName -ErrorAction Stop).Length } catch { $after = $before }
        $saved = [Math]::Max(0, $before - $after)
        $reclaimed += $saved
        Write-Color ("  [CLEAN] {0,10}  reclaimed from {1}" -f (Format-Size $saved), $d.Name) "Green"
        Write-Log ("VHDX {0} {1} bytes" -f $d.FullName, $saved)
    }
    return $reclaimed
}

# Supported way to shrink WinSxS. Never deletes files from it directly.
function Invoke-ComponentStoreCleanup ([bool]$AnalyzeOnly) {
    if (-not $script:IsAdmin) {
        Write-Color "[SKIP]  Component store (WinSxS) needs an elevated PowerShell." "Yellow"
        return
    }
    if ($AnalyzeOnly) {
        Write-Color "[DISM]  Analysing the component store (WinSxS)..." "Cyan"
        $out = & dism.exe /online /Cleanup-Image /AnalyzeComponentStore 2>&1
        foreach ($line in $out) {
            if ($line -match 'Actual Size|Shared with Windows|Reclaimable|Component Store Cleanup Recommended') {
                Write-Color ("  " + $line.Trim()) "Gray"
            }
        }
        return
    }
    Write-Color "[DISM]  Cleaning the component store. This can take 10-30 minutes..." "Cyan"
    & dism.exe /online /Cleanup-Image /StartComponentCleanup | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Color "[DISM]  Component store cleanup finished." "Green"
        Write-Log  "DISM StartComponentCleanup ok"
    } else {
        Write-Color "[DISM]  Cleanup returned exit code $LASTEXITCODE." "Yellow"
    }
    Write-Color "        (Add /ResetBase by hand for maximum reclaim - it makes installed" "Gray"
    Write-Color "         Windows updates permanently un-uninstallable.)" "Gray"
}

# One-time policy so Chrome stops re-downloading the ~4 GB Gemini Nano model
function Block-ChromeAIModel {
    if (-not $script:IsAdmin) {
        Write-Color "[ERROR] -BlockChromeAIModel writes an HKLM policy. Run PowerShell as Administrator." "Red"
        return
    }
    $key = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name "GenAILocalFoundationalModelSettings" -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Color "[SUCCESS] Chrome policy set - the on-device AI model will not be downloaded again." "Green"
    } catch {
        Write-Color "[ERROR] Could not write the Chrome policy: $_" "Red"
        return
    }
    foreach ($m in @("$env:LocalAppData\Google\Chrome\User Data\OptGuideOnDeviceModel",
                     "$env:LocalAppData\Microsoft\Edge\User Data\OptGuideOnDeviceModel")) {
        if (Test-Path -LiteralPath $m) {
            $size = Get-FolderSizeBytes $m
            [void](Clear-FolderFast -Path $m -RemoveRoot:$true)
            Write-Color ("[SUCCESS] Removed on-device model: {0}" -f (Format-Size $size)) "Green"
        }
    }
    Write-Color "        Restart Chrome for the policy to take effect." "Gray"
}

$TaskName = "DeveloperJunkCleaner"

# A Startup-folder shortcut can never elevate, so the admin-only targets
# (C:\Windows\Temp, Windows Update downloads, Delivery Optimization,
# CBS logs) skip on every automatic run. A scheduled task registered at
# RunLevel Highest fixes that, and fires daily instead of only at logon.
function Install-ScheduledTask ([string]$Root) {
    if (-not $script:IsAdmin) { return $false }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { return $false }
    try {
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                                                -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                                  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        $jobs = @(
            # no -All: the default run already equals it, and a handoff can then narrow it
            @{ Name = $TaskName; Args = '-NoGates'; Desc = 'daily temp and developer cache cleanup'
               Triggers = @((New-ScheduledTaskTrigger -Daily -At 12pm), (New-ScheduledTaskTrigger -AtLogOn)) },
            # New-ScheduledTaskTrigger has no monthly option, so every 4 weeks
            @{ Name = "${TaskName}Monthly"; Args = '-Maintenance'; Desc = '4-weekly WinSxS cleanup and WSL/Docker disk compaction'
               Triggers = @(New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 1pm) }
        )
        foreach ($j in $jobs) {
            $psArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\auto_delete_junk_files.ps1`" $($j.Args)"
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs -WorkingDirectory $Root
            Register-ScheduledTask -TaskName $j.Name -Action $action -Trigger $j.Triggers `
                                   -Principal $principal -Settings $settings `
                                   -Description "$AppName v$Version - $($j.Desc)" `
                                   -Force -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        Write-Color "[WARN] Scheduled task registration failed: $($_.Exception.Message)" "Yellow"
        return $false
    }
}

# Starting your own task needs no UAC prompt, and the task runs elevated, so a
# plain double-click still cleans the admin-only targets. Returns $false when
# there is no task (setup.bat never ran elevated) so the caller cleans what it can.
function Invoke-ElevatedHandoff {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $false }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $false }

    $a = @{}
    foreach ($k in $script:BoundArgs.Keys) {
        $v = $script:BoundArgs[$k]
        if ($v -is [switch]) { $a[$k] = [bool]$v }
    }
    # the task itself carries -NoGates for the daily run; a manual run keeps its own choice
    $a['NoGates'] = [bool]$NoGates

    try {
        $a | ConvertTo-Json | Out-File -FilePath $HandoffFile -Encoding utf8 -Force
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        # the elevated instance deletes the file as soon as it has read it
        for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath $HandoffFile); $i++) { Start-Sleep -Milliseconds 500 }
        if (Test-Path -LiteralPath $HandoffFile) { throw "the task did not pick up the job" }
    } catch {
        Remove-Item -LiteralPath $HandoffFile -Force -ErrorAction SilentlyContinue
        Write-Color "[WARN] Elevated handoff failed ($($_.Exception.Message)), cleaning without admin rights." "Yellow"
        return $false
    }

    Write-Color "Running elevated through the '$TaskName' scheduled task..." "Gray"
    while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running') { Start-Sleep -Seconds 1 }
    # the task writes its echo next to its own copy of the script
    Get-Content -LiteralPath (Join-Path $task.Actions[0].WorkingDirectory "handoff_output.log") -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host $_ }
    return $true
}

function Uninstall-ScheduledTask {
    try {
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            foreach ($n in @($TaskName, "${TaskName}Monthly")) {
                if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
                    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop
                    Write-Color "[SUCCESS] Scheduled task '$n' removed." "Green"
                }
            }
        }
    } catch { }
}

function Install-Application {
    Write-Color "[INSTALL] Registering $AppName v$Version..." "Cyan"

    # The task runs elevated, so it must point at a copy only administrators can edit.
    $root = $PSScriptRoot
    if ($script:IsAdmin -and $env:ProgramFiles) {
        try {
            if ($PSScriptRoot -ine $InstallDir) {
                New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
                foreach ($f in 'auto_delete_junk_files.ps1', 'uninstall.bat', 'targets.json', 'Icon') {
                    $src = Join-Path -Path $PSScriptRoot -ChildPath $f
                    if (Test-Path -LiteralPath $src) {
                        Copy-Item -LiteralPath $src -Destination $InstallDir -Recurse -Force -ErrorAction Stop
                    }
                }
            }
            $root = $InstallDir
            Write-Color "[SUCCESS] Installed to $InstallDir (re-run setup.bat after editing the script)." "Green"
        } catch {
            Write-Color "[WARN] Copy to Program Files failed ($($_.Exception.Message)), installing from this folder." "Yellow"
        }
    }
    $IconPath = Join-Path -Path $root -ChildPath "Icon\Autodeleteicon.ico"

    $startupDir  = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    $shortcutPath = Join-Path -Path $startupDir -ChildPath "AutoDeleteJunkFiles.lnk"
    $launcherBat  = Join-Path -Path $PSScriptRoot -ChildPath "run_silent.bat"
    $shortcutOk   = $false
    $psArgs       = "-WindowStyle Hidden -ExecutionPolicy Bypass -File ""$root\auto_delete_junk_files.ps1"" -All -NoGates"

    $batContent = "@echo off`r`nstart /min powershell.exe $psArgs`r`n"
    Set-Content -Path $launcherBat -Value $batContent -Force

    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        $Shortcut.TargetPath       = "powershell.exe"
        $Shortcut.Arguments        = $psArgs
        $Shortcut.WorkingDirectory = $root
        if (Test-Path $IconPath) { $Shortcut.IconLocation = $IconPath }
        $Shortcut.Save()
        $shortcutOk = $true
    } catch {
        Write-Color "[ERROR] Startup shortcut creation failed: $_" "Red"
    }

    # Preferred path: an elevated scheduled task. Falls back to the shortcut.
    if (Install-ScheduledTask -Root $root) {
        # The task supersedes the shortcut - having both would clean twice per login
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue }
        Write-Color "[SUCCESS] Scheduled task '$TaskName' registered: daily at 12:00 and at logon," "Green"
        Write-Color "          running elevated, so Windows Temp, Windows Update and" "Green"
        Write-Color "          Delivery Optimization are cleaned too." "Green"
        Write-Color "[SUCCESS] Scheduled task '${TaskName}Monthly' registered: every 4 weeks," "Green"
        Write-Color "          WinSxS cleanup and WSL/Docker disk compaction." "Green"
    } elseif ($shortcutOk) {
        Write-Color "[SUCCESS] Startup shortcut registered, running with -All." "Green"
        if (-not $script:IsAdmin) {
            Write-Color "[NOTE]    Not elevated, so 4 system targets (Windows Temp," "Yellow"
            Write-Color "          Windows Update, Delivery Optimization, CBS logs) will be skipped" "Yellow"
            Write-Color "          on every run. Re-run setup.bat as Administrator to register the" "Yellow"
            Write-Color "          scheduled task instead and clean those too." "Yellow"
        }
    }

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeveloperJunkCleaner"
    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        New-ItemProperty -Path $regPath -Name "DisplayName"     -Value $AppName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "DisplayVersion"  -Value $Version -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "Publisher"       -Value "Developer Cleaner Team" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "UninstallString" -Value """$root\uninstall.bat""" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "DisplayIcon"     -Value $IconPath -PropertyType String -Force | Out-Null
        Write-Color "[SUCCESS] Registered in the Windows Apps list." "Green"
    } catch {
        Write-Color "[ERROR] Registry integration failed: $_" "Red"
    }
}

function Uninstall-Application {
    Write-Color "[UNINSTALL] Removing $AppName..." "Cyan"
    Uninstall-ScheduledTask
    $startupDir   = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    $shortcutPath = Join-Path -Path $startupDir -ChildPath "AutoDeleteJunkFiles.lnk"
    if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force; Write-Color "[SUCCESS] Startup shortcut removed." "Green" }

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeveloperJunkCleaner"
    if (Test-Path $regPath) { Remove-Item $regPath -Recurse -Force; Write-Color "[SUCCESS] Registry entry removed." "Green" }

    foreach ($f in @((Join-Path $PSScriptRoot "run_silent.bat"), $LastRunFile, $HandoffFile, $HandoffOut)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    foreach ($dir in @($UserDataDir, $InstallDir)) {
        if ($env:ProgramFiles -and $env:LocalAppData -and (Test-Path -LiteralPath $dir)) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Color "[SUCCESS] Uninstall complete. This folder can be deleted." "Green"
}

# ------------------------------------------------------------------------------
# Once-per-day gate
# ------------------------------------------------------------------------------
function Should-Run-Today {
    if (Test-Path $LastRunFile) {
        try {
            $data    = Get-Content -Raw $LastRunFile | ConvertFrom-Json
            $lastRun = [datetime]::ParseExact($data.date, "yyyy-MM-dd", $null)
            if ($lastRun -eq [datetime]::Today) {
                $freed = if ($data.PSObject.Properties.Name -contains 'freed') { $data.freed } else { "$($data.files_deleted) items" }
                return @{ ShouldRun = $false; LastFreed = $freed }
            }
        } catch { }
    }
    return @{ ShouldRun = $true; LastFreed = "0 B" }
}

function Update-Last-Run ([int64]$Bytes) {
    ([PSCustomObject]@{
        date  = (Get-Date).ToString("yyyy-MM-dd")
        freed = (Format-Size $Bytes)
        bytes = $Bytes
    }) | ConvertTo-Json | Out-File -FilePath $LastRunFile -Encoding utf8 -Force
}

# ------------------------------------------------------------------------------
# External configuration: targets.json lets you retune gates or add and disable
# targets without editing this script. Anything it does not mention keeps the
# built-in default. Paths still pass the same safety gate - the config file
# cannot unlock a protected location.
#   { "gates": { "npm cache": 4096, "Playwright browsers": 0 },
#     "disabled": ["VS Code logs"],
#     "extra": [ { "Name":"Foo", "Path":"C:\\...\\cache", "GateMB":512 } ] }
# ------------------------------------------------------------------------------
function Import-TargetOverrides ($Targets) {
    if (-not (Test-Path -LiteralPath $TargetsFile)) { return $Targets }
    try { $cfg = Get-Content -Raw $TargetsFile | ConvertFrom-Json } catch {
        Write-Color "[WARN] targets.json is not valid JSON, ignoring it." "Yellow"
        return $Targets
    }

    $out = @()
    foreach ($t in $Targets) {
        if ($cfg.disabled -and ($cfg.disabled -contains $t.Name)) { continue }
        if ($cfg.gates) {
            $g = $cfg.gates.PSObject.Properties | Where-Object { $_.Name -eq $t.Name }
            if ($g) { $t.GateMB = [int]$g.Value }
        }
        $out += $t
    }
    foreach ($e in @($cfg.extra)) {
        if (-not $e -or -not $e.Path) { continue }
        $out += [pscustomobject]@{
            Name   = $(if ($e.Name) { $e.Name } else { Split-Path $e.Path -Leaf })
            Path   = [string]$e.Path
            Kind   = $(if ($e.Kind) { $e.Kind } else { 'Cache' })
            GateMB = $(if ($null -ne $e.GateMB) { [int]$e.GateMB } else { $DefaultGateMB })
            Admin  = [bool]$e.Admin
            Exe    = $null; Args = $null
        }
    }
    return $out
}

function Export-TargetTemplate {
    $gates = [ordered]@{}
    foreach ($g in 'System','Dev') { foreach ($t in (Get-Targets $g)) { $gates[$t.Name] = $t.GateMB } }
    ([PSCustomObject]@{ gates = $gates; disabled = @(); extra = @() } |
        ConvertTo-Json -Depth 4) | Out-File -FilePath $TargetsFile -Encoding utf8 -Force
    Write-Color "[SUCCESS] Wrote the current gates to targets.json - edit it and re-run." "Green"
    Write-Color "  $TargetsFile" "Gray"
}

function Write-History ([string]$Mode, [int64]$Bytes, $FreeInfo) {
    try {
        if (-not (Test-Path $HistoryFile)) {
            "timestamp,mode,reclaimed_bytes,reclaimed_human,free_percent_before" |
                Out-File -FilePath $HistoryFile -Encoding utf8 -Force
        }
        $row = "{0},{1},{2},{3},{4}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Mode,
                                        $Bytes, (Format-Size $Bytes), $FreeInfo.Percent
        Add-Content -Path $HistoryFile -Value $row -ErrorAction SilentlyContinue
    } catch { }
}

function Show-SortedReport {
    $rows = @($script:Results | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending)
    if ($rows.Count -eq 0) { Write-Color "  Nothing reclaimable found." "Gray"; return }
    Write-Color ""
    Write-Color ("  {0,-28} {1,12}   {2}" -f "TARGET", "SIZE", "PATH") "Cyan"
    Write-Color ("  " + ("-" * 100)) "Gray"
    foreach ($r in ($rows | Select-Object -First 25)) {
        Write-Color ("  {0,-28} {1,12}   {2}" -f $r.Name, (Format-Size $r.Bytes), $r.Path) "Gray"
    }
    if ($rows.Count -gt 25) { Write-Color ("  ... and {0} more" -f ($rows.Count - 25)) "Gray" }
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
function Main {
    if ($Install)   { Install-Application;   exit 0 }
    if ($Uninstall) { Uninstall-Application; exit 0 }
    if ($BlockChromeAIModel) { Block-ChromeAIModel; exit 0 }
    if ($ExportTargets)      { Export-TargetTemplate; exit 0 }

    # winget asks its own questions and raises its own UAC prompts, so it runs here, visibly
    if ($UpdateApps) {
        if (Get-Command winget -ErrorAction SilentlyContinue) { & winget upgrade --all }
        else { Write-Color "[ERROR] winget was not found." "Red" }
        exit 0
    }

    # -CleanProjects takes a path and project folders need no admin, so it stays non-elevated
    if (-not $script:IsAdmin -and -not $script:Echo -and -not $CleanProjects -and (Invoke-ElevatedHandoff)) { exit 0 }

    if ($UnusedApps) { Show-UnusedApps; exit 0 }

    $doSystem = $All -or $CleanSystem -or (-not $CleanDev -and -not $CleanProjects -and -not $CleanSystem)
    $doDev    = $All -or $CleanDev    -or (-not $CleanSystem -and -not $CleanProjects -and -not $CleanDev)

    if ($Maintenance) { $DeepClean = $true; $CompactVHD = $true; $doSystem = $false; $doDev = $false }

    $mode = if ($Report) { "SIZE REPORT" } elseif ($Test) { "DRY RUN" } else { "CLEANING" }
    Write-Color "==================================================" "Cyan"
    Write-Color "  $AppName v$Version  -  $mode" "Cyan"
    Write-Color "==================================================" "Cyan"

    # ---- disk pressure decides how hard we clean -----------------------------
    $policy = Get-AdaptivePolicy -Disabled $NoAdaptive -Forced $Force
    # Developer caches keep their gates: wiping them daily only buys a re-download
    $sysScale = $policy.GateScale
    if ($NoGates -and $sysScale -ne 0.0) { $sysScale = 0.0; $policy.Label += ", system size gates off" }
    $free   = $policy.Info
    if ($free.Percent -ge 0) {
        Write-Color ("  Free on {0}  {1} of {2}  ({3}%)  -  {4}" -f $env:SystemDrive,
            (Format-Size $free.Free), (Format-Size $free.Total), $free.Percent, $policy.Label) "Gray"
    }
    if (-not $script:IsAdmin) {
        Write-Color "  Not elevated: Windows Temp, Windows Update, Delivery" "Gray"
        Write-Color "  Optimization and CBS logs will be skipped this run." "Gray"
        Write-Color "  Run setup.bat once (one UAC prompt) and every later run cleans them too." "Yellow"
    }

    # An explicit -CleanDev is the user asking for it, so adaptive skip does not apply
    if ($policy.SkipDev -and -not $CleanDev -and -not $Report -and -not $Test) {
        if ($doDev) { Write-Color "  Skipping developer caches: plenty of free space. -Force overrides." "Gray" }
        $doDev = $false
    }

    if (-not $Test -and -not $Report -and -not $Force -and -not $Maintenance) {
        $s = Should-Run-Today
        if (-not $s.ShouldRun) {
            Write-Color "[INFO] Already ran today (freed $($s.LastFreed)). Use -Force to run again." "Gray"
            exit 0
        }
    }

    $total = 0
    if ($doSystem) { $total += Invoke-Group -Group 'System' -TestMode $Test -ReportMode $Report -IgnoreGate $Force -GateScale $sysScale }
    if ($doDev)   { $total += Invoke-Group -Group 'Dev'    -TestMode $Test -ReportMode $Report -IgnoreGate $Force -GateScale $policy.GateScale }

    if ($DockerPrune -and -not $Report -and -not $Test) {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            docker info -f "{{.Name}}" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Color "  [CLEAN] Docker builder/system prune..." "Green"
                docker builder prune -f 2>$null | Out-Null
                docker system prune  -f 2>$null | Out-Null
            }
        }
    }

    if ($CleanProjects) { $total += Clean-DeveloperProjects -RootDir $CleanProjects -TestMode ($Test -or $Report) }

    # ---- opt-in extras -------------------------------------------------------
    if ($EmptyRecycleBin) { $total += Clear-RecycleBinSafely -TestMode ($Test -or $Report) }
    if ($CompactVHD)      { $total += Invoke-CompactVHD      -TestMode ($Test -or $Report) -Unattended $Maintenance }

    if ($DeepClean) {
        Write-Color ""
        Invoke-ComponentStoreCleanup -AnalyzeOnly ($Report -or $Test)
    } elseif ($Report -and $script:IsAdmin) {
        Write-Color ""
        Invoke-ComponentStoreCleanup -AnalyzeOnly $true
    }

    # ---- report-only findings: never deleted, only surfaced ------------------
    if ($Report -or $Test) {
        [void](Show-WindowsOld)
        Show-LargeUserFiles
        if ($Report) { Show-UnusedApps }
        if (-not $EmptyRecycleBin) {
            $rb = Get-RecycleBinSize
            if ($rb -gt 0) {
                Write-Color ""
                Write-Color "[FOUND] Recycle Bin holds $(Format-Size $rb). Empty it with -EmptyRecycleBin." "Yellow"
            }
        }
        if (-not $CompactVHD) {
            $vd = @(Get-VirtualDiskCandidates)
            if ($vd.Count -gt 0) {
                $vsum = ($vd | Measure-Object -Property Length -Sum).Sum
                Write-Color ""
                Write-Color "[FOUND] $($vd.Count) WSL/Docker virtual disk(s) occupying $(Format-Size $vsum)." "Yellow"
                Write-Color "  These never shrink on their own. Reclaim with -CompactVHD (elevated)." "Gray"
            }
        }
    }

    # ---- summary -------------------------------------------------------------
    Write-Color ""
    Write-Color "==================================================" "Cyan"
    if ($Report) {
        Show-SortedReport
        Write-Color ""
        Write-Color "  Total reclaimable right now: $(Format-Size $total)" "Green"
        Write-Color "  Run without -Report to clean." "Gray"
    } elseif ($Test) {
        Show-SortedReport
        Write-Color ""
        Write-Color "  Dry run complete - $(Format-Size $total) would be reclaimed." "Green"
    } else {
        if (-not $Maintenance) { Update-Last-Run -Bytes $total }   # must not use up the daily run
        Write-History -Mode "clean" -Bytes $total -FreeInfo $free
        Write-Color "  Cleanup complete - $(Format-Size $total) reclaimed." "Green"
        $after = Get-FreeSpaceInfo
        if ($after.Percent -ge 0) {
            Write-Color ("  Free on {0} now {1} ({2}%)" -f $env:SystemDrive, (Format-Size $after.Free), $after.Percent) "Gray"
        }
        Write-Log ("RUN TOTAL {0} bytes" -f $total)
        if ($total -gt 0) {
            Show-ToastNotification -Title "Junk Cleaner" -Message "Reclaimed $(Format-Size $total) of disk space."
        }
    }
    Write-Color "==================================================" "Cyan"
}

# dot-sourcing (tests\safety_check.ps1) loads the functions without running a clean
if ($MyInvocation.InvocationName -ne '.') { Main }

# Self-check for the delete gate. Deletes nothing.
#   powershell -ExecutionPolicy Bypass -File tests\safety_check.ps1
. "$PSScriptRoot\..\auto_delete_junk_files.ps1"
$LogFile = Join-Path $env:TEMP "djc_safety_check.log"   # keep BLOCKED lines out of the real log

$script:fail = 0
function Check ([string]$Path, [bool]$Expect) {
    $got = [bool](Assert-SafeTarget $Path 6>$null)
    if ($got -ne $Expect) { $script:fail++; Write-Host "FAIL  expected $Expect, got $got :: '$Path'" -ForegroundColor Red }
}

# Personal files and system locations must always be refused
$u = $env:UserProfile
foreach ($p in @(
    "$u\Downloads", "$u\Downloads\Editing course", "$u\Documents", "$u\Documents\Python Projects\x\__pycache__",
    "$u\Desktop\a", "$u\Pictures", "$u\Videos\clip", "$u\Music", "$u\OneDrive\x", "$u\Saved Games",
    $u, "$u\AppData", $env:LocalAppData, $env:AppData, "C:\", "C:\Users",
    $env:SystemRoot, "$env:SystemRoot\System32\drivers", "$env:SystemRoot\SysWOW64", "$env:SystemRoot\WinSxS\x",
    "$env:ProgramFiles\App", "${env:ProgramFiles(x86)}\App", "$env:ProgramData\App",
    "C:\pagefile.sys", "C:\System Volume Information", 'C:\$Recycle.Bin\S-1-5', "", "   ", "\\server\share\x"
)) { Check $p $false }

# Real cache locations must pass
foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp", "$env:LocalAppData\npm-cache\_cacache", "$env:AppData\Code\CachedData")) { Check $p $true }

# Every built-in target must pass the gate, i.e. none sits in a protected place
$n = 0
foreach ($g in 'System', 'Dev') {
    foreach ($t in (Get-Targets $g)) {
        if ($t.Kind -ne 'Glob') { Check $t.Path $true; $n++ }
    }
}

Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
if ($script:fail) { Write-Host "$($script:fail) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "safety gate OK ($n built-in targets checked)" -ForegroundColor Green

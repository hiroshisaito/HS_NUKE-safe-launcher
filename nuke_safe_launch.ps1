<#
  nuke_safe_launch.ps1
  ------------------------------------------------------------------
  Prevents the ~/.nuke/uistate.ini "audio device name" (and any other
  non-ASCII value) from self-doubling into a giant blob that hangs
  Nuke at the splash screen.

  Root cause (confirmed): Qt QSettings (uistate.ini is IniFormat) reads a
  non-ASCII value back under a mismatched codec (UTF-8 written / Latin-1
  read), so the byte length DOUBLES every launch. On Japanese Windows the
  seed is the localized default audio endpoint name ("スピーカー") stored
  under [audio] device=. Alternating Nuke 15 (Qt5) and Nuke 16 (Qt6),
  which SHARE one ~/.nuke/uistate.ini, accelerates it. ~24 launches -> 240MB.

  This launcher runs while Nuke is NOT running and, BEFORE each launch,
  removes any pathologically long line from uistate.ini (the runaway
  value), then starts Nuke. Because it resets every launch, the value can
  never accumulate across launches. Everything else in uistate (window
  layout, browser history, prefs) is preserved byte-for-byte.

  It is deliberately generic: it keys off LINE LENGTH, not the [audio]
  section, so a future non-ASCII seed (e.g. a Japanese project path in
  [FileBrowser]) is caught the same way, on any platform.

  Usage:
    nuke_safe_launch.ps1 -Major 16 -Mode nukex
    nuke_safe_launch.ps1 -Exe "D:\Program Files\Nuke16.0v6\Nuke16.0.exe" -Mode studio
    nuke_safe_launch.ps1 -Major 15 -NoLaunch      # sanitize only (test)

  Encoding safety: the file is read/written as ISO-8859-1 (Latin-1), a
  bijective byte<->char mapping, so untouched lines are preserved exactly
  and this script never itself re-encodes content. When nothing is
  oversized, the file is NOT rewritten at all; when it is, the rewrite is
  atomic (temp + File.Replace) and the original is kept as *.presanitize.bak.
  It cleans the .nuke\uistate.ini under HOME / HOMEDRIVE+HOMEPATH / USERPROFILE
  (whichever exist) so it also works on machines where Nuke's HOME is set.
#>
# PositionalBinding = $false: without it a trailing unnamed argument binds to the
# first free typed parameter instead of reaching $ExtraArgs. Measured 2026-09-29 -
#   ... -Major 16 "C:/comp.nk"   bound the .nk to -Exe and refused to start
#   ... -Exe <path> "C:/comp.nk" bound the .nk to -Major and died on the int cast,
# and that second one is the pass-through example printed in BOTH READMEs.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Major = 0,                 # 15 / 16 / 17 ; ignored if -Exe is given
    [string]$Exe = '',               # explicit Nuke exe path (overrides -Major)
    [ValidateSet('nukex','studio','assist','nuke')]
    [string]$Mode = 'nukex',         # launch mode flag
    [int]$MaxLineChars = 1048576,    # lines longer than this (1 MB) are treated as runaway bloat
    [string]$Version = '',           # exact build to launch, e.g. '16.1v2'; overrides the pinned default
    [switch]$ListVersions,           # list the builds installed for -Major, then exit
    [switch]$SetDefault,             # remember -Version for this -Major (written to ~/.nuke) and launch it
    [string]$SearchRoot = '',        # scan here instead of Start Menu + Program Files - for the tests
    [int]$AbortLaunchOverMB = 16,    # if sanitize FAILED and uistate is still bigger than this, abort the launch (it would hang)
    [string]$UiStatePath = '',       # override uistate.ini path (default: ~/.nuke/uistate.ini) - mainly for testing
    [switch]$NoLaunch,               # sanitize only, do not start Nuke (for testing)
    [Parameter(ValueFromRemainingArguments = $true)]
    $ExtraArgs
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) { Write-Host "[nuke-safe-launch] $msg" }

# --------------------------------------------------------------------
# 1. Sanitize uistate.ini  (Nuke must NOT be running)
# --------------------------------------------------------------------
function Invoke-SanitizeUiState {
    param([string]$Path, [int]$MaxLineChars)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "uistate not found (fresh profile) -> nothing to sanitize."
        return
    }

    $item   = Get-Item -LiteralPath $Path
    $sizeMB = [math]::Round($item.Length / 1MB, 2)

    # Latin-1 (ISO-8859-1, codepage 28591): every byte 0x00-0xFF maps 1:1 to a
    # char and back. Reading/writing through it is byte-lossless and never
    # reinterprets UTF-8 / binary content. This is what makes the surgery safe.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text  = $latin1.GetString($bytes)

    # Split on LF only; any CR of a CRLF stays attached to its segment, so
    # rejoining with LF reproduces the original line endings exactly.
    $lines = $text.Split([char]10)

    $kept    = New-Object System.Collections.Generic.List[string]
    $removed = 0
    [long]$freedChars = 0
    foreach ($ln in $lines) {
        if ($ln.Length -gt $MaxLineChars) {
            $removed++
            $freedChars += $ln.Length
        }
        else {
            $kept.Add($ln)
        }
    }

    if ($removed -eq 0) {
        Write-Log ("uistate OK ({0} MB, no line over {1} chars) -> no change." -f $sizeMB, $MaxLineChars)
        return
    }

    # Write the cleaned bytes atomically: build a temp file, then File.Replace so the
    # original is moved to the rolling backup and the new content swaps in as one
    # operation. A mid-write failure therefore never leaves uistate.ini truncated.
    $backup = "$Path.presanitize.bak"
    $tmp    = "$Path.sanitize.tmp"
    $out    = [string]::Join([char]10, $kept)
    [System.IO.File]::WriteAllBytes($tmp, $latin1.GetBytes($out))
    try {
        [System.IO.File]::Replace($tmp, $Path, $backup)
    }
    catch {
        # Same-volume Replace should always work (temp sits beside the target); if it
        # somehow does not, fall back to copy-backup + overwrite so we still recover.
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        [System.IO.File]::WriteAllBytes($Path, $latin1.GetBytes($out))
        if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
    }

    $newMB = [math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 2)
    Write-Log ("SANITIZED: removed {0} runaway line(s) (~{1} MB). {2} MB -> {3} MB. Backup: {4}" -f `
        $removed, [math]::Round($freedChars / 1MB, 2), $sizeMB, $newMB, $backup)
}

# Warn (do not block) if a Nuke is already running - the cleanup would be undone when
# it exits, so the user should close open Nuke instances first for it to stick.
$runningNuke = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Nuke*' })
if (-not $ListVersions -and $runningNuke.Count -gt 0) {
    Write-Log ("NOTE: {0} Nuke process(es) already running - the uistate cleanup may be overwritten on their exit. Close all Nuke instances first for it to take effect." -f $runningNuke.Count)
}

# Resolve which uistate.ini to clean. Nuke on Windows resolves its .nuke dir from HOME
# first (then HOMEDRIVE+HOMEPATH, then USERPROFILE), so cleaning only USERPROFILE would
# silently miss the real file on facility machines where HOME is set. Clean every
# candidate that exists - sanitizing a healthy one is a no-op, so this is always safe.
$targets = @()
if ($UiStatePath -ne '') {
    $targets += $UiStatePath
}
else {
    $homeBases = @()
    if ($env:HOME) { $homeBases += $env:HOME }
    if ($env:HOMEDRIVE -and $env:HOMEPATH) { $homeBases += ($env:HOMEDRIVE + $env:HOMEPATH) }
    if ($env:USERPROFILE) { $homeBases += $env:USERPROFILE }
    $seen = @{}
    foreach ($base in $homeBases) {
        $p = Join-Path $base ".nuke\uistate.ini"
        $key = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $targets += $p }
    }
}
# -ListVersions only answers "what is installed". Nothing about that question
# justifies rewriting uistate.ini, leaving a .presanitize.bak, or exiting 2 on a
# file that is too big - all of which this block would otherwise do before the
# list is ever printed. Emptying $targets skips the sanitize AND the size gate.
if ($ListVersions) { $targets = @() }

$failedTargets = @()
foreach ($t in $targets) {
    try {
        Invoke-SanitizeUiState -Path $t -MaxLineChars $MaxLineChars
    }
    catch {
        # A transient hiccup on a HEALTHY file should not block the launch; the
        # still-bloated case is re-checked right below and DOES block.
        Write-Log "WARNING: sanitize step failed for ${t}: $($_.Exception.Message)"
        $failedTargets += $t
    }
}

# External review #3 + self-review: if uistate is STILL pathologically large
# after the sanitize pass - whether sanitize threw (locked file), or it ran but
# found no single runaway line to remove (a multi-line bloat variant the
# per-line threshold cannot catch) - launching would run straight into the
# splash-screen hang this tool exists to prevent. Refuse to launch
# (exit 2 -> the .bat pauses with this text).
foreach ($t in $targets) {
    if ((Test-Path -LiteralPath $t) -and ((Get-Item -LiteralPath $t).Length -gt ($AbortLaunchOverMB * 1MB))) {
        $mb = [math]::Round((Get-Item -LiteralPath $t).Length / 1MB, 1)
        if ($failedTargets -contains $t) {
            Write-Log ("ERROR: could not sanitize {0} and it is still {1} MB (limit {2} MB). Launching Nuke now would very likely hang at the splash screen." -f $t, $mb, $AbortLaunchOverMB)
            Write-Log "       Close ALL Nuke windows (or reboot), then run this launcher again."
        }
        else {
            Write-Log ("ERROR: {0} is still {1} MB (limit {2} MB) after sanitizing - no single line exceeded {3} chars, so this looks like a different bloat pattern this tool cannot trim safely." -f $t, $mb, $AbortLaunchOverMB, $MaxLineChars)
        }
        Write-Log "       If it keeps failing, rename the file away manually - Nuke will recreate it: "
        Write-Log ("       {0}  ->  {0}.bloated_backup" -f $t)
        Write-Log "NOT launching Nuke."
        exit 2
    }
}

# -NoLaunch used to return here, before the exe was resolved, so it could only
# ever exercise the sanitizer. It now reports the exe it WOULD start (see the
# end of this script) - that is the part worth checking without a licence.
if ($NoLaunch -and $Major -le 0 -and -not $Exe) {
    Write-Log 'NoLaunch set and no version given -> sanitize only, done.'
    return
}

# --------------------------------------------------------------------
#  Pinned version preference (per user, per machine)
# --------------------------------------------------------------------
#  Kept in ~/.nuke next to hs_nkbrowser_config.json rather than beside this
#  script. The launchers folder is copied from the repo, or run straight off the
#  share, so a setting stored there would be shared between machines and
#  overwritten by the next deploy.
function Get-LauncherSettingsPath {
    $userHome = $env:HOME
    if (-not $userHome) { $userHome = $env:USERPROFILE }
    if (-not $userHome) { return '' }
    return (Join-Path $userHome '.nuke\hs_nuke_launcher.json')
}

function Get-PinnedVersion([int]$Major) {
    $path = Get-LauncherSettingsPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $data = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    }
    catch {
        # A hand-edited file with a stray comma must not stop Nuke starting.
        Write-Log "ignoring unreadable settings file ($path): $($_.Exception.Message)"
        return ''
    }
    if (-not $data -or -not $data.pinned) { return '' }
    $value = $data.pinned."$Major"
    if ($value) { return ([string]$value).Trim() }
    return ''
}

function Set-PinnedVersion([int]$Major, [string]$Version) {
    $path = Get-LauncherSettingsPath
    if (-not $path) { Write-Log 'cannot locate a home directory; not saving the default'; return }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $pinned = @{}
    $other  = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($existing) {
                # Carry over every top-level key except the one being rewritten.
                # Only "pinned" exists today, but a newer launcher's setting must
                # not be silently dropped just because an older copy of this
                # script - off the share, say - saved a default over it.
                $existing.PSObject.Properties | ForEach-Object {
                    if ($_.Name -ne 'pinned') { $other[$_.Name] = $_.Value }
                }
            }
            if ($existing -and $existing.pinned) {
                $existing.pinned.PSObject.Properties | ForEach-Object { $pinned[$_.Name] = $_.Value }
            }
        }
        catch {
            # Keep going with an empty map rather than refusing to save; the old
            # file is unreadable anyway and is about to be replaced.
            Write-Log "previous settings file was unreadable, starting a fresh one"
        }
    }
    $pinned["$Major"] = $Version
    $other['pinned'] = [pscustomobject]$pinned
    $json = ([pscustomobject]$other | ConvertTo-Json -Depth 5)
    # Saving is a convenience; launching is the job. A read-only profile or a
    # roaming-home hiccup must not leave the artist with no Nuke, so the write
    # is allowed to fail loudly and the script carries on to the launch.
    # WriteAllText with an explicit no-BOM encoder: Set-Content -Encoding UTF8
    # writes a BOM on Windows PowerShell 5.1, and a BOM in a JSON file is
    # something a stricter reader (python's json.load, say) refuses outright.
    try {
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "saved: Nuke $Major now launches $Version by default ($path)"
    }
    catch {
        Write-Log "could not save the default to ${path}: $($_.Exception.Message)"
        Write-Log "carrying on and launching anyway; the choice was not remembered."
    }
}

# --------------------------------------------------------------------
# 2. Resolve the Nuke executable
# --------------------------------------------------------------------
function Get-NukeCandidates {
    param([int]$Major)

    $cands = @()

    # (1) Authoritative source: the Foundry installer's Start Menu shortcuts. These
    #     point at the canonical install on THIS machine (what the user actually
    #     launches), so a manually-cloned duplicate on another drive is ignored.
    $sh = $null
    if (-not $SearchRoot) {
        try { $sh = New-Object -ComObject WScript.Shell } catch { $sh = $null }
    }
    if ($sh) {
        $menuRoots = @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\The Foundry'),
            (Join-Path $env:AppData    'Microsoft\Windows\Start Menu\Programs\The Foundry')
        )
        foreach ($mr in $menuRoots) {
            if (Test-Path -LiteralPath $mr) {
                Get-ChildItem -LiteralPath $mr -Directory -Filter "Nuke $Major.*" -ErrorAction SilentlyContinue | ForEach-Object {
                    $verFolder = $_.Name
                    Get-ChildItem -LiteralPath $_.FullName -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                        $tgt = ''
                        try { $tgt = $sh.CreateShortcut($_.FullName).TargetPath } catch { $tgt = '' }
                        if ($tgt -and ($tgt -match "\\Nuke$Major\.\d+\.exe$") -and (Test-Path -LiteralPath $tgt)) {
                            $minor = 0; $build = 0
                            if ($verFolder -match "Nuke $Major\.(\d+)v(\d+)") { $minor = [int]$Matches[1]; $build = [int]$Matches[2] }
                            $cands += [pscustomobject]@{ Path = $tgt; Minor = $minor; Build = $build; FromStartMenu = $true }
                        }
                    }
                }
            }
        }
    }

    # (2) Program Files on every fixed drive. This used to run ONLY when the Start
    #     Menu found nothing, which made any build without a shortcut invisible
    #     whenever some other build of the same major had one - measured on this
    #     machine, Nuke 15.1v10 exists on C: and D: and only C: was ever offered.
    #     Fine while the only question was "which one do we launch"; not fine now
    #     that the user picks. Both sources always run and are merged; the Start
    #     Menu still wins ties, so the default pick is unchanged.
    # -SearchRoot exists for the tests, the same way -UiStatePath does: a machine
    # rarely has two real builds of one major, so the choice this feature is FOR
    # cannot otherwise be exercised.
    $bases = @()
    if ($SearchRoot) {
        $bases += $SearchRoot
    }
    else {
        $fixed = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
        foreach ($d in $fixed) {
            foreach ($pf in @('Program Files', 'Program Files (x86)')) {
                $bases += (Join-Path $d.RootDirectory.FullName $pf)
            }
        }
    }
    foreach ($base in $bases) {
        if (Test-Path -LiteralPath $base) {
            Get-ChildItem -LiteralPath $base -Directory -Filter "Nuke$Major.*" -ErrorAction SilentlyContinue | ForEach-Object {
                $verFolder = $_.Name
                Get-ChildItem -LiteralPath $_.FullName -Filter "Nuke$Major.*.exe" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^Nuke$Major\.\d+\.exe$" } | ForEach-Object {
                        $minor = 0; $build = 0
                        if ($verFolder -match "^Nuke$Major\.(\d+)v(\d+)") { $minor = [int]$Matches[1]; $build = [int]$Matches[2] }
                        $cands += [pscustomobject]@{ Path = $_.FullName; Minor = $minor; Build = $build; FromStartMenu = $false }
                    }
            }
        }
    }

    # One entry per executable. A Foundry Start Menu folder holds four shortcuts
    # - Nuke, NukeX, NukeAssist, NukeStudio - all pointing at the SAME exe, so
    # the loop above finds each install four times. Harmless while the only
    # consumer took [0]; not harmless now that -ListVersions prints the list.
    $byPath = @{}
    $unique = @()
    foreach ($c in $cands) {
        $key = ([string]$c.Path).ToLowerInvariant()
        if (-not $byPath.ContainsKey($key)) { $byPath[$key] = $true; $unique += $c }
    }
    $cands = $unique

    # Deterministic order: highest version first, then lowest path (prefers
    # C: < D: < E:) so the choice never flip-flops between duplicate copies on
    # different drives. Every caller below relies on [0] being "the newest".
    $sorted = @($cands | Sort-Object `
        @{ Expression = 'Minor';         Descending = $true }, `
        @{ Expression = 'Build';         Descending = $true }, `
        @{ Expression = 'FromStartMenu'; Descending = $true }, `
        @{ Expression = 'Path';          Descending = $false })
    foreach ($c in $sorted) {
        Add-Member -InputObject $c -NotePropertyName 'Version' `
            -NotePropertyValue ("{0}.{1}v{2}" -f $Major, $c.Minor, $c.Build) -Force
    }
    return $sorted
}

function Resolve-NukeExe {
    param([int]$Major, [string]$Exe, [string]$Version)

    if ($Exe -ne '') {
        if (Test-Path -LiteralPath $Exe) { return $Exe }
        throw "Given -Exe not found: $Exe"
    }
    if ($Major -le 0) { throw "Specify -Major (15/16/17) or -Exe <path>." }

    $cands = Get-NukeCandidates -Major $Major
    if ($cands.Count -eq 0) { throw "No Nuke $Major.x install found on this machine (looked in Start Menu and Program Files)." }

    # -Version for this launch, otherwise whatever was pinned for this major.
    $wanted = $Version.Trim()
    $wantedFrom = 'the -Version argument'
    if (-not $wanted) {
        $wanted = Get-PinnedVersion -Major $Major
        $wantedFrom = 'the saved default'
    }

    if ($wanted) {
        $hit = $cands | Where-Object { $_.Version -ieq $wanted } | Select-Object -First 1
        if ($hit) {
            Write-Log ("using Nuke {0} (from {1})" -f $hit.Version, $wantedFrom)
            return $hit.Path
        }
        $available = (($cands | ForEach-Object { $_.Version }) -join ', ')
        if ($Version.Trim()) {
            # Asked for on the command line. Refuse: starting a DIFFERENT build
            # than the one named is the failure this feature exists to prevent,
            # and a silent fallback exits 0 so the wrapper never pauses and
            # nobody reads the warning. -SetDefault already refuses the same
            # string; this makes the launch path agree with it.
            throw ("Nuke {0} is not installed. Available: {1}" -f $wanted, $available)
        }
        # A SAVED pin, not a request made just now: warn and take the newest
        # rather than refusing to start. Uninstalling an old build must not
        # break the launcher for everyone who pinned it.
        Write-Log ("Nuke {0} ({1}) is not installed; available: {2}" -f `
            $wanted, $wantedFrom, $available)
        Write-Log ("falling back to the newest, Nuke {0}" -f $cands[0].Version)
    }

    return $cands[0].Path
}

if ($ListVersions) {
    if ($Major -le 0) { throw 'Specify -Major (15/16/17) with -ListVersions.' }
    $all = Get-NukeCandidates -Major $Major
    if ($all.Count -eq 0) { Write-Log "No Nuke $Major.x install found on this machine."; exit 0 }
    $pin = Get-PinnedVersion -Major $Major
    Write-Log "Nuke $Major.x builds on this machine:"
    foreach ($c in $all) {
        $marks = @()
        if ($pin -and ($c.Version -ieq $pin)) { $marks += 'saved default' }
        if ($c.Version -ieq $all[0].Version)  { $marks += 'newest' }
        $suffix = ''
        if ($marks.Count -gt 0) { $suffix = '   <- ' + ($marks -join ', ') }
        Write-Host ("    {0,-10} {1}{2}" -f $c.Version, $c.Path, $suffix)
    }
    if ($pin -and -not ($all | Where-Object { $_.Version -ieq $pin })) {
        Write-Log "the saved default ($pin) is NOT installed; the newest would be used instead"
    }
    if (-not $pin) { Write-Log "no saved default; the newest is used. Set one with: -Major $Major -Version <x.yvZ> -SetDefault" }
    exit 0
}

if ($SetDefault) {
    if ($Major -le 0)  { throw 'Specify -Major (15/16/17) with -SetDefault.' }
    if (-not $Version) { throw 'Specify -Version <x.yvZ> with -SetDefault.' }
    $known = Get-NukeCandidates -Major $Major
    if (-not ($known | Where-Object { $_.Version -ieq $Version.Trim() })) {
        # Refuse rather than save a typo that would silently fall back forever.
        throw ("Nuke {0} is not installed. Available: {1}" -f `
            $Version, (($known | ForEach-Object { $_.Version }) -join ', '))
    }
    Set-PinnedVersion -Major $Major -Version $Version.Trim()
}

$exePath = Resolve-NukeExe -Major $Major -Exe $Exe -Version $Version

switch ($Mode) {
    'nukex'  { $modeArgs = @('--nukex') }
    'studio' { $modeArgs = @('--studio') }
    'assist' { $modeArgs = @('--nukeassist') }
    'nuke'   { $modeArgs = @() }
    default  { $modeArgs = @('--nukex') }
}

$launchArgs = @()
$launchArgs += $modeArgs
# Quote any pass-through arg that contains whitespace; Start-Process -ArgumentList
# otherwise splits e.g. "C:\my project\comp.nk" into two separate arguments.
if ($ExtraArgs) {
    foreach ($a in $ExtraArgs) {
        $s = [string]$a
        if (($s -match '\s') -and -not ($s.StartsWith('"') -and $s.EndsWith('"'))) { $launchArgs += ('"' + $s + '"') }
        else { $launchArgs += $s }
    }
}

if ($NoLaunch) {
    Write-Log ("NoLaunch set -> would launch: `"{0}`" {1}" -f $exePath, ($launchArgs -join ' '))
    Write-Log 'NoLaunch set -> done (no Nuke started).'
    return
}

Write-Log ("launching: `"{0}`" {1}" -f $exePath, ($launchArgs -join ' '))
if ($launchArgs.Count -gt 0) {
    Start-Process -FilePath $exePath -ArgumentList $launchArgs
}
else {
    Start-Process -FilePath $exePath
}
Write-Log "launched. You can close this window."

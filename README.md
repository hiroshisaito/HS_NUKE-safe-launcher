# Nuke safe launchers (uistate bloat guard)

Double-click launchers that **sanitize `~/.nuke/uistate.ini` before starting NukeX**, so the
Qt "audio device name" self-doubling bug can never grow `uistate.ini` large enough to hang
Nuke at the splash screen.

日本語: [`README_ja.md`](README_ja.md)

## Why this exists

On Japanese Windows, Nuke's `uistate.ini` (a Qt `QSettings` INI file) stores the localized
audio output endpoint name (e.g. `スピーカー`) under `[audio] device=`. A Qt codec round-trip
(written UTF-8, read back as Latin-1) makes that value **double in length every launch**.
Alternating **Nuke 15 (Qt5)** and **Nuke 16 (Qt6)**, which share the same `~/.nuke/uistate.ini`,
accelerates it. After ~24 launches the value reaches ~240 MB and Nuke hangs parsing it.

It is a Qt/Nuke bug (QTBUG-54510 class), not an `HS_nkBrowser` bug. There is no official fix,
so we prevent it externally: reset the runaway value while Nuke is not running.

## What the launcher does, every time

1. If a Nuke process is already running, it prints a note (the cleanup only "sticks" once all
   Nuke instances are closed) — but does not block.
2. For each `.nuke/uistate.ini` under `HOME`, `HOMEDRIVE+HOMEPATH`, and `USERPROFILE`
   (whichever exist — Nuke resolves `.nuke` from `HOME` first on Windows), it removes any
   **single line longer than 1 MB** (the runaway value). Everything else — window layout,
   file-browser history, prefs — is preserved **byte-for-byte**. A healthy file is not
   rewritten at all. When it does rewrite, it is atomic (temp + `File.Replace`) and the
   original is kept as `uistate.ini.presanitize.bak`.
3. Launches NukeX for the requested major version.

The check is **generic (line length)**, not audio-specific, so a future non-ASCII seed
(e.g. a Japanese project path in `[FileBrowser]`) is caught the same way.

## Choosing which build starts

With two builds of one major version installed - say `16.1v2` and `16.1v3` - the launcher
starts the newest unless told otherwise. To see what is installed:

```
powershell -ExecutionPolicy Bypass -File "nuke_safe_launch.ps1" -Major 16 -ListVersions
```

```
[nuke-safe-launch] Nuke 16.x builds on this machine:
    16.1v3     D:\Program Files\Nuke16.1v3\Nuke16.1.exe   <- newest
    16.1v2     D:\Program Files\Nuke16.1v2\Nuke16.1.exe
```

Start a particular one, this time only:

```
... -Major 16 -Version 16.1v2
```

Or remember it, so double-clicking `NukeX 16 (safe).bat` uses it from now on:

```
... -Major 16 -Version 16.1v2 -SetDefault
```

The preference is stored per user and per machine in `~/.nuke/hs_nuke_launcher.json`, beside
`hs_nkbrowser_config.json` — **not** next to these scripts, which get copied from the repo or
run off the share and would carry one machine's choice to every other. Remove the entry (or
the file) to go back to "newest".

Precedence, highest first: `-Exe` → `-Version` → the saved default → newest installed. If the
saved build has since been uninstalled the launcher says so and starts the newest instead,
rather than refusing to run. `-SetDefault` will not save a version that is not installed.

## Files

| File | Purpose |
|------|---------|
| `nuke_safe_launch.ps1` | The engine: sanitize + resolve exe + launch. |
| `NukeX 15 (safe).bat`  | Double-click → sanitize → NukeX 15. |
| `NukeX 16 (safe).bat`  | Double-click → sanitize → NukeX 16. |
| `NukeX 17 (safe).bat`  | Double-click → sanitize → NukeX 17. |

## Use it

Double-click the `.bat` for the version you want. The console window flashes (showing the
sanitize result) and NukeX opens. On error (e.g. that Nuke version not installed) the window
stays open with the message.

### Deploy to another machine

Copy this whole `launchers` folder anywhere on the target machine (or run it straight from the
network/repo). No editing needed:

- The Nuke executable is resolved from the machine's **Start Menu shortcuts** (the Foundry
  installer's canonical path), falling back to a scan of `Program Files` on every fixed drive.
  A manually-cloned duplicate copy on another drive is therefore ignored.
- The `uistate.ini` path follows `HOME`/`USERPROFILE`, so it also works where the studio sets
  `HOME`.

### Desktop shortcuts

Right-drag each `.bat` to the Desktop → *Create shortcuts here*, or point an existing shortcut's
Target at the `.bat`. (You can set the shortcut's icon to the Nuke exe so it looks native.)

## Advanced options (`nuke_safe_launch.ps1`)

```
-Major 15|16|17     which NukeX to launch (auto-detects the exe)
-Exe <path>         launch a specific exe (e.g. a non-standard install dir); overrides -Major
-Mode nukex|studio|assist|nuke   launch mode (default nukex)
-Version <x.yvZ>    launch this exact build, e.g. 16.1v2 (see "Choosing which build starts")
-ListVersions       list the builds installed for -Major, then exit
-SetDefault         remember -Version for this -Major, then launch it
-MaxLineChars <n>   bloat threshold in chars (default 1048576 = 1 MB)
-AbortLaunchOverMB <n>  if sanitizing FAILED and uistate is still larger than this,
                    abort the launch rather than hang on it (default 16 MB)
-NoLaunch           sanitize only, do not start Nuke (used by the tests)
-UiStatePath <path> sanitize a specific uistate.ini (used by the tests)
-SearchRoot <path>  look for installs here instead of Start Menu + Program Files
                    (used by the tests: a machine rarely has two builds of one major)
<extra args>        passed through to Nuke (e.g. a .nk to open)
```

Example — launch NukeX from a non-standard install and open a comp:

```
powershell -ExecutionPolicy Bypass -File "nuke_safe_launch.ps1" -Exe "C:\Apps\Nuke16.0v6\Nuke16.0.exe" "C:\path\to comp.nk"
```

## Notes / limitations

- **Close all Nuke instances first.** If Nuke is running, it rewrites `uistate.ini` on exit and
  can undo the cleanup (the launcher warns about this).
- **Group Policy** may override `-ExecutionPolicy Bypass` on locked-down machines; then the
  `.ps1` must be allowed by policy.
- Backup: the last pre-sanitize copy is kept next to `uistate.ini` as `*.presanitize.bak`.

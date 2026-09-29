@echo off
REM Sanitize ~/.nuke/uistate.ini (removes any runaway bloat line), then launch NukeX 15.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nuke_safe_launch.ps1" -Major 15 -Mode nukex %*
if errorlevel 1 pause

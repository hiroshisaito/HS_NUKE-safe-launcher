@echo off
REM Sanitize ~/.nuke/uistate.ini (removes any runaway bloat line), then launch NukeX 16.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0nuke_safe_launch.ps1" -Major 16 -Mode nukex %*
if errorlevel 1 pause

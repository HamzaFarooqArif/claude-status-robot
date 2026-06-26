@echo off
REM Launch the Claude Code status app (animated tray robot + floating widget), hidden.
REM Or just double-click "Claude Status.lnk".
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0cc_status.ps1"

@echo off
REM Claude Code status indicator - per-session cleanup (called by the SessionEnd hook).
REM Deletes this session's state file so it drops off the monitor when the session ends.
setlocal
set "DIR=%USERPROFILE%\.claude\cc_status\sessions"
set "PROJ=%CLAUDE_PROJECT_DIR%"
if "%PROJ%"=="" set "PROJ=%CD%"
set "FN=%PROJ%"
set "FN=%FN:\=_%"
set "FN=%FN::=_%"
set "FN=%FN:/=_%"
set "FN=%FN: =_%"
del "%DIR%\%FN%.txt" 2>nul

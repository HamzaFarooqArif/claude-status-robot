@echo off
REM Claude Code status indicator - per-session state writer.
REM Usage (from a hook): set_state.cmd BUSY | WAIT | IDLE
REM Writes "<STATE>|<project-dir>" to a per-session file keyed by the project
REM directory, so multiple concurrent Claude sessions each get their own entry.
setlocal
set "DIR=%USERPROFILE%\.claude\cc_status\sessions"
if not exist "%DIR%" mkdir "%DIR%"
set "PROJ=%CLAUDE_PROJECT_DIR%"
if "%PROJ%"=="" set "PROJ=%CD%"
set "FN=%PROJ%"
set "FN=%FN:\=_%"
set "FN=%FN::=_%"
set "FN=%FN:/=_%"
set "FN=%FN: =_%"
>"%DIR%\%FN%.txt" echo %~1^|%PROJ%

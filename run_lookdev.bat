@echo off
REM ── Launch the MetaHuman Look-Dev viewer (windowed) ──────────────────────────
REM Double-click this, or run it from any directory. It resolves the project
REM path relative to itself (%~dp0), so the "Invalid project path" error from a
REM relative --path can't happen.
REM
REM Godot binary resolution order:
REM   1. %GODOT% environment variable, if set
REM   2. Archie's local stock build
REM   3. "godot" on PATH
set "GODOT_BIN=%GODOT%"
if "%GODOT_BIN%"=="" set "GODOT_BIN=H:\dev\godot-stock\Godot_v4.6-stable_win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=godot"
"%GODOT_BIN%" --path "%~dp0." scenes/look_dev.tscn --resolution 1366x860 %*

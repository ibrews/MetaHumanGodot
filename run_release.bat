@echo off
REM ── Launch the MetaHuman → Godot RELEASE look-dev tool (windowed) ────────────
REM Double-click this, or run it from any directory. Resolves the project path
REM relative to itself (%~dp0) so a relative --path can't fail.
REM
REM Godot binary resolution order:
REM   1. %GODOT% environment variable, if set
REM   2. Archie's local stock build
REM   3. "godot" on PATH
set "GODOT_BIN=%GODOT%"
if "%GODOT_BIN%"=="" set "GODOT_BIN=H:\dev\godot-stock\Godot_v4.6-stable_win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=godot"
"%GODOT_BIN%" --path "%~dp0." scenes/release.tscn --resolution 1280x1280 %*

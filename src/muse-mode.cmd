@echo off
rem muse-mode on | off | status  (see muse-mode.ps1)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0muse-mode.ps1" %*

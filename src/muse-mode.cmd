@echo off
rem muse-mode on | off | status | shim  (see muse-mode.ps1)
rem Prefers pwsh; falls back to Windows PowerShell 5.1 (the .ps1 is 5.1-safe).
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0muse-mode.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0muse-mode.ps1" %*
)

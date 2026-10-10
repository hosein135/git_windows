@echo off
setlocal
cd /d "%~dp0"
title Git Installer

echo Requesting administrator privileges if needed...

net session >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo Running git_installer.ps1 ...
echo.

if not exist "%~dp0git_installer.ps1" (
  echo ERROR: git_installer.ps1 not found.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0git_installer.ps1"
echo.
echo Exit code: %ERRORLEVEL%
pause
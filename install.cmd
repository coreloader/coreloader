@echo off
setlocal EnableExtensions
rem Core Loader — one-click install (Windows CMD / PowerShell)
rem Usage (works in both CMD and PowerShell):
rem   cmd /c "curl -fsSL -o %TEMP%\cl-install.cmd https://coreloader.com/core-loader-releases/install.cmd && call %TEMP%\cl-install.cmd"
rem   cmd /c "curl -fsSL -o %TEMP%\cl-install.cmd https://coreloader.com/core-loader-releases/install.cmd && call %TEMP%\cl-install.cmd 8.5"
rem   install.cmd -Php 8.3
rem
rem Downloads and runs install.ps1 (PowerShell runtime is required on Windows).

set "INSTALL_PS1_URL=https://coreloader.com/core-loader-releases/install.ps1"
if defined CORELOADER_BASE_URL (
  set "INSTALL_PS1_URL=%CORELOADER_BASE_URL%/core-loader-releases/install.ps1"
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo Error: PowerShell is required to run the installer.
  exit /b 1
)

set "PS1=%TEMP%\coreloader-install-%RANDOM%%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing -Uri '%INSTALL_PS1_URL%' -OutFile '%PS1%'"
if errorlevel 1 (
  echo Failed to download install.ps1
  if exist "%PS1%" del /f /q "%PS1%" >nul 2>&1
  exit /b 1
)
if not exist "%PS1%" (
  echo Failed to download install.ps1
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "EC=%ERRORLEVEL%"
del /f /q "%PS1%" >nul 2>&1
exit /b %EC%

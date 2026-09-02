@echo off
setlocal EnableExtensions
echo Core Loader installer...

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
set "DETECT_VER="
if not "%~1"=="" (
  echo.%~1| findstr /r "^[0-9][0-9]*\.[0-9][0-9]*$" >nul && set "DETECT_VER=%~1"
)

echo Downloading install.ps1...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri '%INSTALL_PS1_URL%' -OutFile '%PS1%' -TimeoutSec 120 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
  echo Failed to download install.ps1
  if exist "%PS1%" del /f /q "%PS1%" >nul 2>&1
  exit /b 1
)
if not exist "%PS1%" (
  echo Failed to download install.ps1
  exit /b 1
)

echo Detecting PHP...
set "PHPBIN="
if defined CORELOADER_PHP_BIN (
  if exist "%CORELOADER_PHP_BIN%" set "PHPBIN=%CORELOADER_PHP_BIN%"
)
if not defined PHPBIN (
  if defined DETECT_VER set "CORELOADER_DETECT_PHP_VER=%DETECT_VER%"
  for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$want=$env:CORELOADER_DETECT_PHP_VER; function Out-Bin([string]$b){ if($b -and (Test-Path -LiteralPath $b)){ Write-Output $b; exit 0 } }; if ($env:CORELOADER_PHP_BIN) { Out-Bin $env:CORELOADER_PHP_BIN }; if ($want -match '^(\d+)\.(\d+)') { $compact = ($Matches[1] + $Matches[2]); foreach ($root in @('C:\BtSoft\php','D:\BtSoft\php','E:\BtSoft\php','C:\phpstudy_pro\Extensions\php')) { if (-not (Test-Path -LiteralPath $root)) { continue }; Out-Bin (Join-Path $root ($compact + '\php.exe')); Out-Bin (Join-Path $root ($want + '\php.exe')); Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $bin = Join-Path $_.FullName 'php.exe'; if (-not (Test-Path -LiteralPath $bin)) { return }; $ver = & $bin -n -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>$null; if ($ver -and ($ver.ToString().Trim() -eq $want)) { Write-Output $bin; exit 0 } } } }; $cmd = Get-Command php -ErrorAction SilentlyContinue; if ($cmd) { Out-Bin $cmd.Source }; foreach ($root in @('C:\BtSoft\php','D:\BtSoft\php','E:\BtSoft\php','C:\phpstudy_pro\Extensions\php')) { if (-not (Test-Path -LiteralPath $root)) { continue }; Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { Out-Bin (Join-Path $_.FullName 'php.exe') } }"`) do set "PHPBIN=%%P"
  set "CORELOADER_DETECT_PHP_VER="
)
if not defined PHPBIN (
  echo Error: Could not find PHP under BtSoft or PATH.
  if defined DETECT_VER echo Requested PHP version: %DETECT_VER%
  echo Run: dir /s /b C:\BtSoft\php\php.exe
  echo Then: set CORELOADER_PHP_BIN=C:\BtSoft\php\84\php.exe
  echo       call %TEMP%\cl-install.cmd 8.4
  exit /b 1
)

for %%D in ("%PHPBIN%") do set "EXTDIR=%%~dpDext"
echo Using PHP: %PHPBIN%
if defined DETECT_VER echo Requested PHP: %DETECT_VER%
echo Extension dir: %EXTDIR%

echo Running installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -PhpBin "%PHPBIN%" -Dir "%EXTDIR%" %*
set "EC=%ERRORLEVEL%"
del /f /q "%PS1%" >nul 2>&1
if not "%EC%"=="0" (
  echo Install failed with exit code %EC%.
  exit /b %EC%
)
echo Done.
exit /b 0

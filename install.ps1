# Core Loader — one-click install (Windows PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/coreloader/coreloader/main/install.ps1 | iex
#   .\install.ps1 -Version v8.0.0 -Php 8.3
param(
  [string]$Owner = $(if ($env:CORELOADER_GH_OWNER) { $env:CORELOADER_GH_OWNER } else { "coreloader" }),
  [string]$Repo = $(if ($env:CORELOADER_GH_REPO) { $env:CORELOADER_GH_REPO } else { "coreloader" }),
  [string]$Version = $(if ($env:CORELOADER_VERSION) { $env:CORELOADER_VERSION } else { "latest" }),
  [string]$Php = "",
  [string]$Dir = "",
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repo)) {
  Write-Error "Owner/Repo must not be empty"
}

function Get-PhpVersion {
  $out = & php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>$null
  if (-not $out) { throw "php not found in PATH" }
  return $out.Trim()
}

function Get-WinArch {
  # Prefer process architecture for matching NTS DLL
  if ([Environment]::Is64BitProcess) { return "x64" }
  return "x86"
}

function Get-ExtensionDir {
  if ($Dir) { return $Dir }
  $ini = & php -r "echo ini_get('extension_dir');" 2>$null
  if ($ini -and $ini.Trim() -ne "." -and $ini.Trim() -ne "") {
    return $ini.Trim()
  }
  throw "Could not detect extension_dir; pass -Dir"
}

if (-not $Php) { $Php = Get-PhpVersion }
$supported = @("7.0","7.1","7.2","7.3","7.4","8.0","8.1","8.2","8.3","8.4","8.5")
if ($supported -notcontains $Php) {
  throw "Unsupported PHP version '$Php' (supported: 7.0–8.5)"
}

$arch = Get-WinArch
$asset = "php_core_loader-php${Php}-win-${arch}.dll"
$destName = "php_core_loader.dll"
$installDir = Get-ExtensionDir

if ($Version -eq "latest") {
  $url = "https://github.com/$Owner/$Repo/releases/latest/download/$asset"
} else {
  $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
  $url = "https://github.com/$Owner/$Repo/releases/download/$tag/$asset"
}

$dest = Join-Path $installDir $destName

Write-Host "Core Loader install"
Write-Host "  PHP:     $Php"
Write-Host "  Arch:    win-$arch"
Write-Host "  Asset:   $asset"
Write-Host "  From:    $url"
Write-Host "  To:      $dest"

if ($DryRun) {
  Write-Host "[dry-run] skip download/install"
  exit 0
}

if ((Test-Path $dest) -and -not $Force) {
  throw "$dest already exists (use -Force to overwrite)"
}

$tmp = Join-Path $env:TEMP ("core_loader_" + [guid]::NewGuid().ToString() + ".dll")
try {
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
  # PE magic MZ
  $fs = [System.IO.File]::OpenRead($tmp)
  try {
    $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
  } finally { $fs.Close() }
  if ($b0 -ne 0x4D -or $b1 -ne 0x5A) {
    throw "Downloaded file is not a PE DLL"
  }

  if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
  }
  Copy-Item -Force $tmp $dest
} catch {
  Write-Host "Install failed: $_"
  Write-Host "If permission denied, run PowerShell as Administrator, or:"
  Write-Host "  .\install.ps1 -Dir `$env:USERPROFILE\php-ext -Force"
  Write-Host "  # php.ini: extension=$env:USERPROFILE\php-ext\php_core_loader.dll"
  throw
} finally {
  if (Test-Path $tmp) { Remove-Item -Force $tmp }
}

Write-Host ""
Write-Host "Installed: $dest"
Write-Host ""
Write-Host "Add to php.ini (use extension=, NOT zend_extension=):"
Write-Host "  extension=$destName"
Write-Host "  # or absolute path:"
Write-Host "  # extension=$dest"
Write-Host ""
Write-Host "Verify:"
Write-Host "  php -m | findstr core_loader"
Write-Host "  php -r `"var_export(extension_loaded('core_loader')); echo PHP_EOL;`""

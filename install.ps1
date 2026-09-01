# Core Loader — one-click install (Windows PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/coreloader/coreloader/main/install.ps1 | iex
#   .\install.ps1 -Version v8.0.0 -Php 8.3
param(
  [string]$Owner = $(if ($env:CORELOADER_GH_OWNER) { $env:CORELOADER_GH_OWNER } else { "coreloader" }),
  [string]$Repo = $(if ($env:CORELOADER_GH_REPO) { $env:CORELOADER_GH_REPO } else { "coreloader" }),
  [string]$Version = $(if ($env:CORELOADER_VERSION) { $env:CORELOADER_VERSION } else { "latest" }),
  [string]$Php = "",
  [string]$PhpBin = "",
  [string]$Dir = "",
  [string]$Ini = "",
  [switch]$NoIni,
  [switch]$NoReload,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repo)) {
  Write-Error "Owner/Repo must not be empty"
}

function Get-PhpVersionFromBin([string]$bin) {
  $out = & $bin -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>$null
  if (-not $out) { throw "php not found: $bin" }
  return $out.Trim()
}

function Get-WinArch {
  if ([Environment]::Is64BitProcess) { return "x64" }
  return "x86"
}

function Normalize-IniPath([string]$p) {
  if (-not $p) { return $p }
  return ($p.Trim().Trim('"').Trim("'"))
}

function Get-ExtensionDir([string]$bin) {
  if ($Dir) { return $Dir }
  $ext = & $bin -r "echo ini_get('extension_dir');" 2>$null
  if ($ext -and $ext.Trim() -ne "." -and $ext.Trim() -ne "") {
    return $ext.Trim()
  }
  throw "Could not detect extension_dir; pass -Dir"
}

function Get-IniTargets([string]$bin) {
  if ($Ini) { return @((Normalize-IniPath $Ini)) }
  $iniOut = & $bin --ini 2>$null | Out-String
  $loaded = $null
  $scan = $null
  foreach ($line in ($iniOut -split "`n")) {
    if ($line -match 'Loaded Configuration File:\s*(.+)$') {
      $loaded = Normalize-IniPath $Matches[1]
    }
    if ($line -match 'Scan for additional \.ini files in:\s*(.+)$') {
      $scan = Normalize-IniPath $Matches[1]
    }
  }
  $targets = New-Object System.Collections.Generic.List[string]
  if ($scan -and $scan -ne '(none)' -and $scan -ne 'none') {
    $targets.Add((Join-Path $scan '99-core_loader.ini')) | Out-Null
  } elseif ($loaded -and $loaded -ne '(none)' -and $loaded -ne 'none') {
    $etc = Split-Path -Parent $loaded
    $phpIni = Join-Path $etc 'php.ini'
    $cliIni = Join-Path $etc 'php-cli.ini'
    if ((Split-Path -Leaf $loaded) -eq 'php-cli.ini' -and (Test-Path $phpIni)) {
      $targets.Add($phpIni) | Out-Null
      $targets.Add($loaded) | Out-Null
    } else {
      $targets.Add($loaded) | Out-Null
      if ((Split-Path -Leaf $loaded) -eq 'php.ini' -and (Test-Path $cliIni)) {
        $targets.Add($cliIni) | Out-Null
      }
    }
  }
  if ($targets.Count -eq 0) {
    throw "Could not detect php.ini; pass -Ini"
  }
  return $targets.ToArray()
}

function Update-PhpIni([string]$path, [string]$line, [string]$comment) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  if ((Split-Path -Leaf $path) -eq '99-core_loader.ini') {
    $content = "$comment`r`n$line`r`n"
    Set-Content -Path $path -Value $content -Encoding ASCII
    Write-Host "  ini: wrote $path"
    return
  }

  $text = ""
  if (Test-Path $path) {
    $text = Get-Content -Path $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { $text = "" }
  }

  if ($text -match "(?m)^\s*extension\s*=\s*(php_)?core_loader(\.dll)?\b") {
    if ($text -match "(?m)^\s*;\s*Core Loader") {
      $text = [regex]::Replace($text, '(?m)^\s*;\s*Core Loader.*$', $comment)
      Set-Content -Path $path -Value $text -Encoding ASCII -NoNewline
    }
    Write-Host "  ini: already enabled in $path"
    return
  }

  $text = [regex]::Replace($text, '(?m)^(\s*)zend_extension\s*=\s*.*core_loader.*$', ';${1} disabled by coreloader install (use extension=)')
  if (-not ($text.EndsWith("`n") -or $text.Length -eq 0)) { $text += "`r`n" }
  $text += "`r`n$comment`r`n$line`r`n"
  Set-Content -Path $path -Value $text -Encoding ASCII -NoNewline
  Write-Host "  ini: updated $path"
}

function Get-DownloadUrls([string]$primary) {
  return @(
    $primary,
    "https://ghfast.top/$primary",
    "https://mirror.ghproxy.com/$primary",
    "https://ghproxy.net/$primary",
    "https://gitdl.cn/$primary"
  )
}

function Download-Asset([string]$dest, [string[]]$urls) {
  Write-Host "Downloading:"
  $i = 0
  foreach ($u in $urls) {
    $i++
    try {
      # Progress shown by Invoke-WebRequest in interactive hosts
      Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 180
      if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        return
      }
    } catch {
      # try next mirror silently
    }
  }
  throw "Download failed for all mirrors"
}

function Restart-PhpRuntime([string]$phpVer) {
  Write-Host "Reloading PHP runtime..."
  $compact = ($phpVer -replace '\.', '')
  $ok = $false

  # IIS
  try {
    if (Get-Command iisreset -ErrorAction SilentlyContinue) {
      & iisreset /noforce 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  reloaded via iisreset"
        return
      }
    }
  } catch {}

  try {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    if (Get-Command Restart-WebAppPool -ErrorAction SilentlyContinue) {
      Get-ChildItem IIS:\AppPools -ErrorAction SilentlyContinue | ForEach-Object {
        Restart-WebAppPool $_.Name -ErrorAction SilentlyContinue
        $ok = $true
      }
      if ($ok) {
        Write-Host "  restarted IIS app pools"
        return
      }
    }
  } catch {}

  # Windows services commonly used by panels / phpstudy / custom NSSM
  $serviceNames = @(
    "php-fpm-$compact",
    "php-fpm$compact",
    "php$compact-fpm",
    "php$phpVer-fpm",
    "php-cgi-$compact",
    "php-cgi",
    "php-fpm",
    "w3svc",
    "Apache2.4",
    "Apache2.2",
    "nginx"
  )
  foreach ($name in $serviceNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { continue }
    try {
      Restart-Service -Name $name -Force -ErrorAction Stop
      Write-Host "  restarted service $name"
      return
    } catch {}
  }

  # Docker Desktop / Windows containers (1Panel-like / compose)
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    $rows = docker ps --format "{{.ID}} {{.Names}} {{.Image}}" 2>$null
    if ($rows) {
      $matched = $rows | Where-Object { $_ -match 'php|fpm|1panel' -and $_ -match "$phpVer|$compact" }
      if (-not $matched) {
        $matched = $rows | Where-Object { $_ -match 'php.*fpm|fpm.*php|1panel.*php' }
      }
      foreach ($row in $matched) {
        $id = ($row -split '\s+')[0]
        $name = ($row -split '\s+')[1]
        try {
          docker restart $id 2>$null | Out-Null
          Write-Host "  restarted docker container $name"
          return
        } catch {}
      }
    }
  }

  Write-Host "  warning: could not auto-reload PHP runtime; restart IIS/service/container manually if needed"
}

if (-not $PhpBin) { $PhpBin = "php" }
if (-not $Php) { $Php = Get-PhpVersionFromBin $PhpBin }

$supported = @("7.0","7.1","7.2","7.3","7.4","8.0","8.1","8.2","8.3","8.4","8.5")
if ($supported -notcontains $Php) {
  throw "Unsupported PHP version '$Php' (supported: 7.0–8.5). Hint: -Version is the Release tag (v8.0.0); use -Php 8.3 for PHP version."
}

$arch = Get-WinArch
$asset = "php_core_loader-php${Php}-win-${arch}.dll"
$destName = "php_core_loader.dll"
$installDir = Get-ExtensionDir $PhpBin
$iniLine = "extension=$destName"

$productVer = "8.0.0"
if ($Version -ne "latest") {
  $productVer = $Version.TrimStart('v')
} else {
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 15
    if ($rel.tag_name) { $productVer = $rel.tag_name.TrimStart('v') }
  } catch {}
}
$iniComment = "; Core Loader $productVer"

$iniPaths = @()
if (-not $NoIni) {
  $iniPaths = Get-IniTargets $PhpBin
}

if ($Version -eq "latest") {
  $url = "https://github.com/$Owner/$Repo/releases/latest/download/$asset"
} else {
  $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
  $url = "https://github.com/$Owner/$Repo/releases/download/$tag/$asset"
}

$dest = Join-Path $installDir $destName

Write-Host "Core Loader install"
Write-Host "  PHP:     $Php ($PhpBin)"
Write-Host "  Arch:    win-$arch"
Write-Host "  Asset:   $asset"
Write-Host "  From:    $url"
Write-Host "  To:      $dest"
if ($NoIni) {
  Write-Host "  Ini:     (skipped)"
} else {
  Write-Host "  Ini:     $($iniPaths -join ' ')"
}

if ($DryRun) {
  Write-Host "[dry-run] skip download/install/ini"
  exit 0
}

$tmp = Join-Path $env:TEMP ("core_loader_" + [guid]::NewGuid().ToString() + ".dll")
try {
  Download-Asset -dest $tmp -urls (Get-DownloadUrls $url)

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
  Write-Host "Run PowerShell as Administrator if permission denied."
  throw
} finally {
  if (Test-Path $tmp) { Remove-Item -Force $tmp }
}

Write-Host "Installed: $dest"

if (-not $NoIni) {
  Write-Host "Configuring PHP..."
  foreach ($p in $iniPaths) {
    Update-PhpIni -path $p -line $iniLine -comment $iniComment
  }
}

if (-not $NoReload) {
  Restart-PhpRuntime -phpVer $Php
}

Write-Host ""
Write-Host "Done. Verify:"
Write-Host "  $PhpBin -m | findstr core_loader"
Write-Host "  $PhpBin -r `"var_export(extension_loaded('core_loader')); echo PHP_EOL;`""

# Core Loader — Windows install engine (invoked by install.cmd)
# Public entry (CMD / PowerShell):
#   cmd /c "curl -fsSL -o %TEMP%\cl-install.cmd https://coreloader.com/core-loader-releases/install.cmd && call %TEMP%\cl-install.cmd"
# Direct:
#   .\install.ps1 8.5
#   .\install.ps1 -Php 8.3
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Position = 0)]
  [string]$Php = $(if ($env:CORELOADER_PHP) { $env:CORELOADER_PHP } else { "" }),
  [string]$BaseUrl = $(if ($env:CORELOADER_BASE_URL) { $env:CORELOADER_BASE_URL } else { "https://coreloader.com" }),
  [string]$DownloadUrl = $(if ($env:CORELOADER_DOWNLOAD_URL) { $env:CORELOADER_DOWNLOAD_URL } else { "" }),
  [string]$FallbackUrl = $(if ($env:CORELOADER_FALLBACK_URL) { $env:CORELOADER_FALLBACK_URL } else { "" }),
  [string]$Owner = $(if ($env:CORELOADER_GH_OWNER) { $env:CORELOADER_GH_OWNER } else { "coreloader" }),
  [string]$Repo = $(if ($env:CORELOADER_GH_REPO) { $env:CORELOADER_GH_REPO } else { "coreloader" }),
  [string]$Version = $(if ($env:CORELOADER_VERSION) { $env:CORELOADER_VERSION } else { "8.0.0" }),
  [string]$PhpBin = "",
  [string]$Dir = "",
  [string]$Ini = "",
  [switch]$NoIni,
  [switch]$NoReload,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

# Avoid stair-step output under cmd.exe + Windows PowerShell 5.x (LF without CR).
if ($PSVersionTable.PSVersion.Major -lt 6) {
  function Write-Host {
    [CmdletBinding()]
    param(
      [Parameter(Position = 0, ValueFromPipeline = $true)]
      [object]$Object,
      [ConsoleColor]$ForegroundColor,
      [ConsoleColor]$BackgroundColor,
      [switch]$NoNewline
    )
    process {
      $text = if ($null -eq $Object) { "" } else { [string]$Object }
      $oldFg = $null
      $oldBg = $null
      try {
        if ($PSBoundParameters.ContainsKey("ForegroundColor")) {
          $oldFg = [Console]::ForegroundColor
          [Console]::ForegroundColor = $ForegroundColor
        }
        if ($PSBoundParameters.ContainsKey("BackgroundColor")) {
          $oldBg = [Console]::BackgroundColor
          [Console]::BackgroundColor = $BackgroundColor
        }
        if ($NoNewline) { [Console]::Write($text) } else { [Console]::WriteLine($text) }
      } finally {
        if ($null -ne $oldFg) { [Console]::ForegroundColor = $oldFg }
        if ($null -ne $oldBg) { [Console]::BackgroundColor = $oldBg }
      }
    }
  }
}

if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
  $DownloadUrl = "$($BaseUrl.TrimEnd('/'))/download"
}
$InstallBase = "$($BaseUrl.TrimEnd('/'))/core-loader-releases"

# Backup: GitHub Release assets
if ([string]::IsNullOrWhiteSpace($FallbackUrl)) {
  if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq "latest") {
    $FallbackUrl = "https://github.com/$Owner/$Repo/releases/latest/download"
  } else {
    $tag = $Version
    if (-not $tag.StartsWith("v")) { $tag = "v$tag" }
    $FallbackUrl = "https://github.com/$Owner/$Repo/releases/download/$tag"
  }
}

function Invoke-PhpProbe([string]$Bin, [string[]]$PhpArgs) {
  # Use -n so a half-configured php.ini (extension line before DLL exists) does not break install.
  $argLine = "-n " + (($PhpArgs | ForEach-Object {
    if ($_ -match '\s') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
  }) -join ' ')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Bin
  $psi.Arguments = $argLine
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  [void]$proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  return $stdout.Trim()
}

function Get-PhpVersionFromBin([string]$bin) {
  $out = Invoke-PhpProbe $bin @('-r', "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
  if (-not $out) { throw "php not found: $bin" }
  return $out.Trim()
}

function Add-PhpCandidate([System.Collections.Generic.HashSet[string]]$set, [string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  [void]$set.Add($path.Trim().Trim('"').Trim("'"))
}

function Find-PhpBin([string]$WantVer) {
  $candidates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

  if ($env:CORELOADER_PHP_BIN) { Add-PhpCandidate $candidates $env:CORELOADER_PHP_BIN }

  $cmd = Get-Command php -ErrorAction SilentlyContinue
  if ($cmd) { Add-PhpCandidate $candidates $cmd.Source }

  $compact = $null
  if ($WantVer -match '^(\d+)\.(\d+)') {
    $compact = "$($Matches[1])$($Matches[2])"
  }

  $panelPhpRoots = @(
    'C:\BtSoft\php', 'D:\BtSoft\php', 'E:\BtSoft\php',
    'C:\phpstudy_pro\Extensions\php',
    'C:\Program Files\php', 'C:\php', 'D:\php'
  )

  foreach ($root in $panelPhpRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }

    if ($compact) {
      Add-PhpCandidate $candidates (Join-Path $root "$compact\php.exe")
      Add-PhpCandidate $candidates (Join-Path $root "$WantVer\php.exe")
    }

    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Add-PhpCandidate $candidates (Join-Path $_.FullName 'php.exe')
    }
  }

  $matched = New-Object System.Collections.Generic.List[object]
  foreach ($bin in $candidates) {
    if (-not (Test-Path -LiteralPath $bin)) { continue }
    try {
      $ver = Invoke-PhpProbe $bin @('-r', "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
      if (-not $ver) { continue }
      $ver = $ver.ToString().Trim()
      if ($WantVer -and $ver -ne $WantVer) { continue }
      if ($WantVer) { return $bin }
      $matched.Add([pscustomobject]@{ Bin = $bin; Ver = $ver }) | Out-Null
    } catch {}
  }

  if ($matched.Count -eq 0) { return $null }
  return ($matched | Sort-Object { [version]$_.Ver } -Descending | Select-Object -First 1).Bin
}

function Resolve-PhpRuntime([string]$WantVer, [string]$ExplicitBin) {
  if ($ExplicitBin) {
    if (-not (Test-Path -LiteralPath $ExplicitBin)) {
      throw "PHP binary not found: $ExplicitBin"
    }
    $ver = Get-PhpVersionFromBin $ExplicitBin
    if ($WantVer -and $ver -ne $WantVer) {
      $found = Find-PhpBin -WantVer $WantVer
      if ($found) {
        Write-Host "Note: using $found for PHP $WantVer (not $ExplicitBin)."
        return @{ Bin = $found; Ver = $WantVer }
      }
      throw "PHP binary $ExplicitBin is version $ver, expected $WantVer. Install PHP $WantVer or run: dir /s /b C:\BtSoft\php\php.exe"
    }
    return @{ Bin = $ExplicitBin; Ver = $ver }
  }

  $found = Find-PhpBin -WantVer $WantVer
  if (-not $found) {
    $verHint = if ($WantVer) { " $WantVer" } else { "" }
    throw "Could not find PHP${verHint}. Common paths: C:\BtSoft\php\85\php.exe (BtSoft), C:\phpstudy_pro\Extensions\php\*\php.exe. Pass -PhpBin 'C:\path\to\php.exe' or set CORELOADER_PHP_BIN."
  }

  $ver = if ($WantVer) { $WantVer } else { Get-PhpVersionFromBin $found }
  return @{ Bin = $found; Ver = $ver }
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
  $phpHome = Split-Path -Parent $bin
  $defaultExt = [System.IO.Path]::GetFullPath((Join-Path $phpHome 'ext'))
  if ($Dir) {
    $dirFull = if ([System.IO.Path]::IsPathRooted($Dir)) {
      [System.IO.Path]::GetFullPath($Dir)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path $phpHome $Dir))
    }
    if ($dirFull.StartsWith($phpHome, [StringComparison]::OrdinalIgnoreCase)) {
      return $dirFull
    }
    Write-Host "  note: extension dir adjusted to $defaultExt"
    return $defaultExt
  }

  # BtSoft / panel: ext/ next to php.exe is the real directory.
  if (Test-Path -LiteralPath $defaultExt) {
    return $defaultExt
  }

  # Read extension_dir from php.ini on disk (avoid php -n default C:\php\ext).
  $phpIni = Join-Path $phpHome 'php.ini'
  if (Test-Path -LiteralPath $phpIni) {
    $iniText = Get-Content -LiteralPath $phpIni -Raw -ErrorAction SilentlyContinue
    if ($iniText -match '(?mim)^\s*extension_dir\s*=\s*"?([^"\r\n;]+)"?\s*') {
      $ext = $Matches[1].Trim()
      if ($ext -and $ext -ne '.' -and $ext -ne '') {
        if (-not [System.IO.Path]::IsPathRooted($ext)) {
          $ext = Join-Path $phpHome $ext
        }
        return [System.IO.Path]::GetFullPath($ext)
      }
    }
  }

  return $defaultExt
}

function Get-IniTargets([string]$bin) {
  if ($Ini) { return @((Normalize-IniPath $Ini)) }

  $phpHome = Split-Path -Parent $bin
  $phpIni = Join-Path $phpHome 'php.ini'
  $cliIni = Join-Path $phpHome 'php-cli.ini'
  $targets = New-Object System.Collections.Generic.List[string]

  # BtSoft / panel layouts: php.ini sits next to php.exe; avoid `php --ini` during install
  # when php.ini already references core_loader but the DLL is not in place yet.
  if (Test-Path -LiteralPath $phpIni) {
    $targets.Add($phpIni) | Out-Null
    if (Test-Path -LiteralPath $cliIni) {
      $targets.Add($cliIni) | Out-Null
    }
    return $targets.ToArray()
  }

  $iniOut = Invoke-PhpProbe $bin @('--ini')
  $loaded = $null
  $scan = $null
  foreach ($line in ($iniOut -split "`r?`n")) {
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

function Download-Asset([string]$dest, [string[]]$urls) {
  Write-Host "Downloading:"
  $idx = 0
  foreach ($u in $urls) {
    $idx++
    $timeout = if ($idx -eq 1) { 45 } else { 180 }
    if ($idx -gt 1) { Write-Host "Switching to backup..." }
    try {
      if (Test-Path $dest) { Remove-Item -Force $dest }
      Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec $timeout
      if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        return
      }
    } catch {
      # try next
    }
  }
  throw "Download failed (primary + backup)"
}

function Stop-PhpRuntimeForUpdate([string]$phpVer, [string]$destPath) {
  Write-Host "Stopping PHP/IIS so extension can be updated..."
  Get-Process -Name php-cgi, php -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath $destPath) {
    try {
      if (Get-Command iisreset -ErrorAction SilentlyContinue) {
        & iisreset /stop 2>$null | Out-Null
        Start-Sleep -Seconds 2
        Write-Host "  stopped IIS (iisreset /stop)"
      }
    } catch {}
  }
}

function Copy-ExtensionDll([string]$src, [string]$dest, [string]$phpVer) {
  $attempts = 0
  while ($attempts -lt 3) {
    $attempts++
    try {
      Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
      return
    } catch {
      if ($attempts -ge 3) { throw }
      Write-Host "  file locked: $dest"
      Stop-PhpRuntimeForUpdate -phpVer $phpVer -destPath $dest
    }
  }
}

function Invoke-WithTimeout([string]$Label, [scriptblock]$Block, [int]$TimeoutSec = 10) {
  Write-Host "  $Label..."
  $job = Start-Job -ScriptBlock $Block
  if (Wait-Job -Job $job -Timeout $TimeoutSec) {
    Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Host "  $Label done"
    return $true
  }
  Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  Write-Host "  $Label timed out (continuing)"
  return $false
}

function Write-BtSoftReloadHint([string]$phpVer, [string]$phpBin) {
  Write-Host ""
  Write-Host "Install finished. If the website still uses the old PHP config, restart manually:"
  if ($phpBin -match '\\BtSoft\\php\\') {
    Write-Host "  BtSoft panel -> Software Store -> PHP $phpVer -> Restart"
    Write-Host "  (Avoid iisreset in remote panel sessions; it may disconnect the terminal.)"
  } else {
    Write-Host "  Run as Administrator: iisreset /restart"
  }
}

function Restart-PhpRuntime([string]$phpVer, [string]$phpBin) {
  Write-Host "Reloading PHP runtime (quick, non-blocking)..."
  $isBtSoft = $phpBin -match '\\BtSoft\\php\\'
  $actions = New-Object System.Collections.Generic.List[string]

  $phpCgi = @(Get-Process -Name php-cgi -ErrorAction SilentlyContinue)
  if ($phpCgi.Count -gt 0) {
    $phpCgi | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $actions.Add("stopped $($phpCgi.Count) php-cgi process(es)") | Out-Null
  }

  if (Invoke-WithTimeout "recycling IIS app pools" {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    if (Get-Command Restart-WebAppPool -ErrorAction SilentlyContinue) {
      Get-ChildItem IIS:\AppPools -ErrorAction SilentlyContinue | ForEach-Object {
        Restart-WebAppPool $_.Name -ErrorAction SilentlyContinue
      }
    }
  } -TimeoutSec 12) {
    $actions.Add("recycled IIS app pools") | Out-Null
  }

  if (-not $isBtSoft) {
    $compact = ($phpVer -replace '\.', '')
    foreach ($name in @("php-fpm-$compact", "php-cgi-$compact", "php-cgi", "Apache2.4", "nginx")) {
      if (Invoke-WithTimeout "restarting service $name" { Restart-Service -Name $name -Force -ErrorAction Stop } -TimeoutSec 8) {
        $actions.Add("restarted service $name") | Out-Null
        break
      }
    }
  }

  if ($env:CORELOADER_FORCE_RELOAD -eq '1') {
    Write-Host "  starting iisreset /restart in background (CORELOADER_FORCE_RELOAD=1)..."
    Start-Process -FilePath "iisreset.exe" -ArgumentList "/restart" -WindowStyle Hidden | Out-Null
    $actions.Add("iisreset /restart (background)") | Out-Null
  }

  if ($actions.Count -gt 0) {
    foreach ($a in $actions) { Write-Host "  $a" }
  } else {
    Write-Host "  cleared PHP worker processes; reload on next request"
  }

  Write-BtSoftReloadHint -phpVer $phpVer -phpBin $phpBin
}

$resolved = Resolve-PhpRuntime -WantVer $Php -ExplicitBin $PhpBin
$PhpBin = $resolved.Bin
$Php = $resolved.Ver

$supported = @("7.0","7.1","7.2","7.3","7.4","8.0","8.1","8.2","8.3","8.4","8.5")
if ($supported -notcontains $Php) {
  throw "Unsupported PHP version '$Php' (supported: 7.0–8.5). Use -Php 8.3 for PHP version."
}

$arch = Get-WinArch
$asset = "php_core_loader-php${Php}-win-${arch}.dll"
$destName = "php_core_loader.dll"
$installDir = Get-ExtensionDir $PhpBin
$iniLine = "extension=$destName"

$productVer = $Version.TrimStart('v')
if ($productVer -eq "latest" -or [string]::IsNullOrWhiteSpace($productVer)) {
  $productVer = "8.0.0"
  try {
    $verText = (Invoke-WebRequest -Uri "$($DownloadUrl.TrimEnd('/'))/VERSION" -UseBasicParsing -TimeoutSec 10).Content
    if ($verText) {
      $productVer = ($verText -split "`n")[0].Trim().TrimStart('v')
    }
  } catch {}
}
$iniComment = "; Core Loader $productVer"

$iniPaths = @()
if (-not $NoIni) {
  $iniPaths = Get-IniTargets $PhpBin
}

$url = "$($DownloadUrl.TrimEnd('/'))/$asset"
$fallbackAssetUrl = "$($FallbackUrl.TrimEnd('/'))/$asset"
$dest = Join-Path $installDir $destName

Write-Host "Core Loader install"
Write-Host "  PHP:     $Php ($PhpBin)"
Write-Host "  Arch:    win-$arch"
Write-Host "  Asset:   $asset"
Write-Host "  From:    $url"
Write-Host "  Backup:  $fallbackAssetUrl"
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
  Download-Asset -dest $tmp -urls @($url, $fallbackAssetUrl)

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
  Copy-ExtensionDll -src $tmp -dest $dest -phpVer $Php
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
  Restart-PhpRuntime -phpVer $Php -phpBin $PhpBin
}

Write-Host ""
Write-Host "Done. Verify:"
Write-Host "  $PhpBin -m | findstr core_loader"
Write-Host "  $PhpBin -r `"var_export(extension_loaded('core_loader')); echo PHP_EOL;`""

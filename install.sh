#!/usr/bin/env bash
# Core Loader — one-click install (Linux / macOS)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version v8.0.0
#   ./install.sh --php 8.3 --dir /www/server/php/83/lib/php/extensions/...
set -euo pipefail

# Defaults — https://github.com/coreloader/coreloader
DEFAULT_OWNER="${CORELOADER_GH_OWNER:-coreloader}"
DEFAULT_REPO="${CORELOADER_GH_REPO:-coreloader}"
DEFAULT_VERSION="${CORELOADER_VERSION:-latest}"

OWNER="$DEFAULT_OWNER"
REPO="$DEFAULT_REPO"
VERSION="$DEFAULT_VERSION"
PHP_VER=""
PHP_BIN=""
INSTALL_DIR=""
INI_FILE=""
NO_INI=0
DRY_RUN=0
FORCE=0

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --owner NAME       GitHub owner (default: $DEFAULT_OWNER)
  --repo NAME        GitHub repo  (default: $DEFAULT_REPO)
  --version TAG      Release tag or "latest" (default: $DEFAULT_VERSION)
  --php X.Y          PHP major.minor (default: detect from php)
  --php-bin PATH     PHP binary to use (default: auto-detect)
  --dir PATH         Extension install directory (default: php-config --extension-dir)
  --ini PATH         php.ini or conf.d drop-in to write (default: auto-detect)
  --no-ini           Do not modify php.ini / conf.d
  --dry-run          Print actions only
  --force            Accepted for compatibility (always overwrites)
  -h, --help         Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --php) PHP_VER="$2"; shift 2 ;;
    --php-bin) PHP_BIN="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --ini) INI_FILE="$2"; shift 2 ;;
    --no-ini) NO_INI=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  echo "Error: owner/repo must not be empty" >&2
  exit 1
fi

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  echo "Windows detected. Use install.ps1 instead:" >&2
  echo "  irm https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.ps1 | iex" >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

need_cmd curl

detect_os() {
  case "$(uname -s)" in
    Linux*) echo linux ;;
    Darwin*) echo darwin ;;
    *) echo "Error: unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64) echo x86_64 ;;
    *) echo "Error: unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Prefer Baota / common multi-PHP layouts when --php is given
find_php_bin() {
  local ver="$1"
  local major="${ver%%.*}"
  local minor="${ver#*.}"
  local compact="${major}${minor}"   # 85
  local candidates=(
    "/www/server/php/${compact}/bin/php"
    "/www/server/php/${ver}/bin/php"
    "/usr/bin/php${ver}"
    "/usr/local/bin/php${ver}"
    "/opt/homebrew/opt/php@${ver}/bin/php"
    "/usr/local/opt/php@${ver}/bin/php"
  )

  if command -v php >/dev/null 2>&1; then
    candidates+=("$(command -v php)")
  fi

  local c got
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] || continue
    got="$("$c" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    if [[ "$got" == "$ver" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

find_php_config() {
  local php_bin="$1"
  local bindir
  bindir="$(dirname "$php_bin")"
  if [[ -x "${bindir}/php-config" ]]; then
    echo "${bindir}/php-config"
    return 0
  fi
  if command -v php-config >/dev/null 2>&1; then
    echo "$(command -v php-config)"
    return 0
  fi
  return 1
}

# Strip whitespace / surrounding quotes from php --ini paths
normalize_ini_path() {
  local p="$1"
  p="$(printf '%s' "$p" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"+//; s/"+$//; s/^'\''+//; s/'\''+$//')"
  printf '%s' "$p"
}

# Print one or more ini targets (newline-separated). Prefer php.d drop-in.
resolve_ini_targets() {
  local php_bin="$1"
  local ini_out loaded scan etc_dir major minor compact
  local -a targets=()
  ini_out="$("$php_bin" --ini 2>/dev/null || true)"
  loaded="$(normalize_ini_path "$(printf '%s\n' "$ini_out" | awk -F': *' '/Loaded Configuration File/{print $2; exit}')")"
  scan="$(normalize_ini_path "$(printf '%s\n' "$ini_out" | awk -F': *' '/Scan for additional .ini files in/{print $2; exit}')")"

  major="${PHP_VER%%.*}"
  minor="${PHP_VER#*.}"
  compact="${major}${minor}"

  if [[ -n "$loaded" && "$loaded" != "(none)" && "$loaded" != "none" ]]; then
    etc_dir="$(dirname "$loaded")"
  else
    etc_dir=""
  fi

  # 1) Prefer conf.d / php.d drop-in (CLI + FPM when both scan it)
  if [[ -n "$scan" && "$scan" != "(none)" && "$scan" != "none" ]]; then
    targets+=("${scan%/}/99-core_loader.ini")
  elif [[ -n "$etc_dir" && -d "${etc_dir}/php.d" ]]; then
    targets+=("${etc_dir}/php.d/99-core_loader.ini")
  elif [[ -d "/www/server/php/${compact}/etc/php.d" ]]; then
    targets+=("/www/server/php/${compact}/etc/php.d/99-core_loader.ini")
  fi

  # 2) No drop-in: write web php.ini (and php-cli.ini), never quotes-wrapped paths
  if [[ ${#targets[@]} -eq 0 ]]; then
    if [[ -f "/www/server/php/${compact}/etc/php.ini" ]]; then
      targets+=("/www/server/php/${compact}/etc/php.ini")
      [[ -f "/www/server/php/${compact}/etc/php-cli.ini" ]] && targets+=("/www/server/php/${compact}/etc/php-cli.ini")
    elif [[ -n "$loaded" && "$loaded" != "(none)" && "$loaded" != "none" ]]; then
      if [[ "$(basename "$loaded")" == "php-cli.ini" && -f "${etc_dir}/php.ini" ]]; then
        targets+=("${etc_dir}/php.ini" "$loaded")
      else
        targets+=("$loaded")
        if [[ "$(basename "$loaded")" == "php.ini" && -f "${etc_dir}/php-cli.ini" ]]; then
          targets+=("${etc_dir}/php-cli.ini")
        fi
      fi
    fi
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${targets[@]}"
}

write_file() {
  local path="$1"
  local content="$2"
  local dir
  dir="$(dirname "$path")"
  if mkdir -p "$dir" 2>/dev/null && printf '%s' "$content" >"$path" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$dir"
    printf '%s' "$content" | sudo tee "$path" >/dev/null
    return 0
  fi
  return 1
}

append_or_create_ini() {
  local path="$1"
  local line="$2"
  local comment="${3:-; Core Loader}"
  local tmp content

  # Drop-in file: always rewrite with current version comment
  if [[ "$(basename "$path")" == "99-core_loader.ini" ]]; then
    content="${comment}
${line}
"
    if write_file "$path" "$content"; then
      echo "  ini: wrote ${path}"
      return 0
    fi
    echo "Error: cannot write ${path}" >&2
    return 1
  fi

  if [[ -f "$path" ]] && grep -Eq "^[[:space:]]*extension[[:space:]]*=[[:space:]]*(core_loader\\.so|${DEST_NAME})([[:space:]]|;|$)" "$path" 2>/dev/null; then
    # Refresh nearby comment if present; otherwise leave as-is
    if grep -Eq "^[[:space:]]*;[[:space:]]*Core Loader" "$path" 2>/dev/null; then
      tmp="$(mktemp)"
      sed -E "s|^[[:space:]]*;[[:space:]]*Core Loader.*$|${comment}|" "$path" >"$tmp" && \
        { cp "$tmp" "$path" 2>/dev/null || sudo cp "$tmp" "$path"; } && rm -f "$tmp"
    fi
    echo "  ini: already enabled in ${path}"
    return 0
  fi

  # Main php.ini: append if missing; comment out mistaken zend_extension=
  tmp="$(mktemp)"
  if [[ -f "$path" ]]; then
    sed -E \
      -e 's/^([[:space:]]*)zend_extension[[:space:]]*=[[:space:]]*.*core_loader.*/;\1 disabled by coreloader install (use extension=)/' \
      "$path" >"$tmp" || cp "$path" "$tmp"
    if ! grep -Eq "^[[:space:]]*extension[[:space:]]*=[[:space:]]*(core_loader\\.so|${DEST_NAME})([[:space:]]|;|$)" "$tmp"; then
      printf '\n%s\n%s\n' "$comment" "$line" >>"$tmp"
    fi
  else
    printf '%s\n%s\n' "$comment" "$line" >"$tmp"
  fi

  if cp "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    echo "  ini: updated ${path}"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo cp "$tmp" "$path"; then
    rm -f "$tmp"
    echo "  ini: updated ${path} (sudo)"
    return 0
  fi
  rm -f "$tmp"
  echo "Error: cannot update ${path}" >&2
  return 1
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

USER_PHP_BIN="$PHP_BIN"

if [[ -z "$PHP_VER" ]]; then
  need_cmd php
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
fi

case "$PHP_VER" in
  7.0|7.1|7.2|7.3|7.4|8.0|8.1|8.2|8.3|8.4|8.5) ;;
  *)
    echo "Error: unsupported PHP version '$PHP_VER' (supported: 7.0–8.5)" >&2
    echo "Hint: --version is the GitHub Release tag (e.g. v8.0.0); use --php 8.3 for PHP version." >&2
    exit 1
    ;;
esac

if [[ -n "$USER_PHP_BIN" ]]; then
  PHP_BIN="$USER_PHP_BIN"
  [[ -x "$PHP_BIN" ]] || { echo "Error: --php-bin not executable: $PHP_BIN" >&2; exit 1; }
else
  if ! PHP_BIN="$(find_php_bin "$PHP_VER")"; then
    echo "Error: PHP ${PHP_VER} binary not found. Pass --php-bin /path/to/php" >&2
    exit 1
  fi
fi

ASSET="core_loader-php${PHP_VER}-${OS}-${ARCH}.so"
DEST_NAME="core_loader.so"
INI_LINE="extension=${DEST_NAME}"

# Release label for ini comment, e.g. "; Core Loader 8.0.0"
PRODUCT_VER="8.0.0"
if [[ "$VERSION" != "latest" ]]; then
  PRODUCT_VER="${VERSION#v}"
else
  _latest_tag="$(curl -fsSL --connect-timeout 5 --max-time 15 \
    "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -n "${_latest_tag:-}" ]]; then
    PRODUCT_VER="${_latest_tag#v}"
  fi
fi
INI_COMMENT="; Core Loader ${PRODUCT_VER}"

if [[ -z "$INSTALL_DIR" ]]; then
  if PHP_CONFIG="$(find_php_config "$PHP_BIN" 2>/dev/null)"; then
    INSTALL_DIR="$("$PHP_CONFIG" --extension-dir)"
  else
    INSTALL_DIR="$("$PHP_BIN" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
  fi
fi

if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "." ]]; then
  echo "Error: could not detect extension_dir; pass --dir" >&2
  exit 1
fi

INI_TARGETS=()
if [[ "$NO_INI" -eq 0 ]]; then
  if [[ -n "$INI_FILE" ]]; then
    INI_TARGETS+=("$(normalize_ini_path "$INI_FILE")")
  else
    while IFS= read -r _ini; do
      [[ -n "$_ini" ]] && INI_TARGETS+=("$_ini")
    done < <(resolve_ini_targets "$PHP_BIN" || true)
    if [[ ${#INI_TARGETS[@]} -eq 0 ]]; then
      echo "Warning: could not detect php.ini; skip auto config (pass --ini PATH)" >&2
      NO_INI=1
    fi
  fi
fi

if [[ "$VERSION" == "latest" ]]; then
  URL="https://github.com/${OWNER}/${REPO}/releases/latest/download/${ASSET}"
else
  TAG="$VERSION"
  [[ "$TAG" == v* ]] || TAG="v${TAG}"
  URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${ASSET}"
fi

# GitHub releases often hang on CN networks — try mirrors with timeouts
build_download_urls() {
  local primary="$1"
  printf '%s\n' \
    "$primary" \
    "https://ghfast.top/${primary}" \
    "https://mirror.ghproxy.com/${primary}" \
    "https://ghproxy.net/${primary}" \
    "https://gitdl.cn/${primary}"
}

download_asset() {
  local dest="$1"
  shift
  local url
  local -a urls=("$@")
  local first=1
  for url in "${urls[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      echo "Downloading:"
      first=0
    fi
    rm -f "$dest"
    # Progress bar only; hide URL / mirror index
    if curl -fL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 \
         -# -o "$dest" "$url" 2>&1; then
      if [[ -s "$dest" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

DEST="${INSTALL_DIR%/}/${DEST_NAME}"
TMP="$(mktemp "${TMPDIR:-/tmp}/core_loader.XXXXXX.so")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "Core Loader install"
echo "  PHP:     ${PHP_VER} (${PHP_BIN})"
echo "  OS/Arch: ${OS}-${ARCH}"
echo "  Asset:   ${ASSET}"
echo "  From:    ${URL}"
echo "  To:      ${DEST}"
if [[ "$NO_INI" -eq 0 ]]; then
  echo "  Ini:     ${INI_TARGETS[*]}"
else
  echo "  Ini:     (skipped)"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] skip download/install/ini"
  exit 0
fi

DOWNLOAD_URLS=()
while IFS= read -r _u; do
  [[ -n "$_u" ]] && DOWNLOAD_URLS+=("$_u")
done < <(build_download_urls "$URL")

if ! download_asset "$TMP" "${DOWNLOAD_URLS[@]}"; then
  echo "Error: download failed for all mirrors: ${ASSET}" >&2
  echo "Primary URL: ${URL}" >&2
  echo "Check network access to GitHub Releases, or download manually and place at:" >&2
  echo "  ${DEST}" >&2
  exit 1
fi

magic="$(xxd -l 4 -p "$TMP" 2>/dev/null || od -An -tx1 -N4 "$TMP" | tr -d ' \n')"
magic="$(echo "$magic" | tr -d ' \n')"
case "$OS" in
  linux)
    if [[ "$magic" != 7f454c46 ]]; then
      echo "Error: downloaded file is not an ELF shared object (magic=$magic)" >&2
      exit 1
    fi
    ;;
  darwin)
    case "$magic" in
      cffaedfe|feedfacf|cafebabe|befaceca) ;;
      *)
        echo "Error: downloaded file is not a Mach-O library (magic=$magic)" >&2
        exit 1
        ;;
    esac
    ;;
esac

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if ! cp -f "$TMP" "$DEST" 2>/dev/null; then
  echo "Permission denied writing ${DEST}"
  if [[ -t 0 ]]; then
    read -r -p "Retry with sudo? [y/N] " ans || true
    if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
      sudo mkdir -p "$INSTALL_DIR"
      sudo cp -f "$TMP" "$DEST"
    else
      exit 1
    fi
  else
    if sudo -n true 2>/dev/null || [[ "$(id -u)" -eq 0 ]]; then
      sudo mkdir -p "$INSTALL_DIR" 2>/dev/null || mkdir -p "$INSTALL_DIR"
      if [[ "$(id -u)" -eq 0 ]]; then
        cp -f "$TMP" "$DEST"
      else
        sudo cp -f "$TMP" "$DEST"
      fi
    else
      echo "Error: need root/sudo to write ${DEST}" >&2
      exit 1
    fi
  fi
fi

chmod 755 "$DEST" 2>/dev/null || sudo chmod 755 "$DEST" 2>/dev/null || true
echo "Installed: ${DEST}"

if [[ "$NO_INI" -eq 0 ]]; then
  echo "Configuring PHP..."
  _ini_fail=0
  for _ini in "${INI_TARGETS[@]}"; do
    if ! append_or_create_ini "$_ini" "$INI_LINE" "$INI_COMMENT"; then
      _ini_fail=1
    fi
  done
  if [[ "$_ini_fail" -ne 0 ]]; then
    echo "Error: failed to update one or more ini files" >&2
    exit 1
  fi
fi

echo ""
echo "Verify:"
echo "  ${PHP_BIN} -m | grep core_loader"
echo "  ${PHP_BIN} -r 'var_export(extension_loaded(\"core_loader\")); echo PHP_EOL;'"
echo "Reload PHP-FPM if needed (Baota: 软件商店 → PHP ${PHP_VER} → 服务 → 重载)."

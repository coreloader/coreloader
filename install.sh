#!/usr/bin/env bash
# Core Loader — one-click install (Linux / macOS)
# Usage:
#   curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- 8.5
#   ./install.sh -php 8.3 --dir /www/server/php/83/lib/php/extensions/...
# Auto-detects Docker/1Panel when host has no php.
# Must run under bash (1Panel PHP images often only have /bin/sh).
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this installer requires bash, not sh." >&2
  echo "Hint: run on the 1Panel/Docker host (auto-detects PHP containers):" >&2
  echo "  curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash" >&2
  echo "Or inside a container that has bash:" >&2
  echo "  curl -fsSL https://coreloader.com/core-loader-releases/install.sh -o /tmp/cl-install.sh && bash /tmp/cl-install.sh" >&2
  exit 1
fi
set -euo pipefail

# Defaults — primary: https://coreloader.com ; backup: GitHub Releases
DEFAULT_BASE="${CORELOADER_BASE_URL:-https://coreloader.com}"
DEFAULT_DOWNLOAD="${CORELOADER_DOWNLOAD_URL:-${DEFAULT_BASE}/download}"
DEFAULT_INSTALL_BASE="${CORELOADER_INSTALL_BASE:-${DEFAULT_BASE}/core-loader-releases}"
DEFAULT_GH_OWNER="${CORELOADER_GH_OWNER:-coreloader}"
DEFAULT_GH_REPO="${CORELOADER_GH_REPO:-coreloader}"
DEFAULT_VERSION="${CORELOADER_VERSION:-8.0.0}"
# Empty = auto from GitHub Release tag; override with CORELOADER_FALLBACK_URL / --fallback-url
DEFAULT_FALLBACK="${CORELOADER_FALLBACK_URL:-}"

BASE_URL="$DEFAULT_BASE"
DOWNLOAD_URL="$DEFAULT_DOWNLOAD"
INSTALL_BASE="$DEFAULT_INSTALL_BASE"
FALLBACK_URL="$DEFAULT_FALLBACK"
GH_OWNER="$DEFAULT_GH_OWNER"
GH_REPO="$DEFAULT_GH_REPO"
VERSION="$DEFAULT_VERSION"
PHP_VER=""
PHP_BIN=""
INSTALL_DIR=""
INI_FILE=""
NO_INI=0
NO_RELOAD=0
DRY_RUN=0
FORCE=0
FALLBACK_SET=0
# empty = host install; "auto" or container name/id = install into Docker/1Panel PHP
DOCKER_TARGET="${CORELOADER_DOCKER:-}"
DOCKER_ID=""
DOCKER_NAME=""
[[ -n "$DEFAULT_FALLBACK" ]] && FALLBACK_SET=1

usage() {
  cat <<EOF
Core Loader — one-click install (Linux / macOS)

Usage:
  curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- 8.5
  ./install.sh -php 8.3

Auto-detects host PHP, or Docker/1Panel PHP containers when host has no php.
With multiple PHP containers, pass PHP version: bash -s -- 8.5

Options:
  -php, --php X.Y    PHP major.minor (default: detect from php / container)
  X.Y                Same as -php X.Y (positional)
  --version X.Y.Z    Product version for ini comment (default: $DEFAULT_VERSION)
  --php-bin PATH     PHP binary to use (default: auto-detect)
  --dir PATH         Extension install directory (default: php-config --extension-dir)
  --ini PATH         php.ini or conf.d drop-in to write (default: auto-detect)
  --docker [NAME]    Force Docker/1Panel install (NAME=auto or container name/id)
  --base-url URL     Site root (default: $DEFAULT_BASE)
  --download-url URL Extension download root (default: $DEFAULT_DOWNLOAD)
  --fallback-url URL Backup download root (default: GitHub Releases for --version)
  --owner NAME       GitHub owner for Release backup (default: $DEFAULT_GH_OWNER)
  --repo NAME        GitHub repo for Release backup (default: $DEFAULT_GH_REPO)
  --no-ini           Do not modify php.ini / conf.d
  --no-reload        Do not reload PHP-FPM after install
  --dry-run          Print actions only
  --force            Accepted for compatibility (always overwrites)
  -h, --help         Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    -php|--php) PHP_VER="$2"; shift 2 ;;
    --php-bin) PHP_BIN="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --ini) INI_FILE="$2"; shift 2 ;;
    --docker)
      if [[ -n "${2:-}" && "$2" != -* && ! "$2" =~ ^[0-9]+\.[0-9]+$ ]]; then
        DOCKER_TARGET="$2"; shift 2
      else
        DOCKER_TARGET="auto"; shift
      fi
      ;;
    --base-url) BASE_URL="$2"; DOWNLOAD_URL="${BASE_URL%/}/download"; INSTALL_BASE="${BASE_URL%/}/core-loader-releases"; shift 2 ;;
    --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
    --fallback-url) FALLBACK_URL="$2"; FALLBACK_SET=1; shift 2 ;;
    --owner) GH_OWNER="$2"; shift 2 ;;
    --repo) GH_REPO="$2"; shift 2 ;;
    --no-ini) NO_INI=1; shift ;;
    --no-reload) NO_RELOAD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    # Bare PHP version: 8.5 / 7.4
    [0-9].[0-9]|[0-9].[0-9][0-9])
      if [[ -n "$PHP_VER" ]]; then
        echo "Error: PHP version already set to ${PHP_VER}; unexpected: $1" >&2
        exit 1
      fi
      PHP_VER="$1"; shift
      ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Backup: GitHub Release assets
#   latest → .../releases/latest/download/<asset>
#   v8.0.0 → .../releases/download/v8.0.0/<asset>
resolve_fallback_url() {
  if [[ "$FALLBACK_SET" -eq 1 && -n "$FALLBACK_URL" ]]; then
    return 0
  fi
  local tag="${VERSION}"
  if [[ -z "$tag" || "$tag" == "latest" ]]; then
    FALLBACK_URL="https://github.com/${GH_OWNER}/${GH_REPO}/releases/latest/download"
  else
    [[ "$tag" == v* ]] || tag="v${tag}"
    FALLBACK_URL="https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/${tag}"
  fi
}
resolve_fallback_url

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  echo "Windows detected. Use install.cmd instead:" >&2
  echo "  cmd /c \"curl -fsSL -o %TEMP%\\cl-install.cmd ${INSTALL_BASE}/install.cmd && call %TEMP%\\cl-install.cmd\"" >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    if [[ "$1" == "php" ]]; then
      echo "Hint: on 1Panel, run the same one-liner on the host (not inside the container):" >&2
      echo "  curl -fsSL ${INSTALL_BASE}/install.sh | bash" >&2
      echo "The installer auto-detects Docker PHP containers when host php is missing." >&2
    fi
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

# docker / sudo docker (1Panel root usually fine; some hosts need sudo)
DOCKER_BIN=()
init_docker_bin() {
  DOCKER_BIN=()
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  if docker ps >/dev/null 2>&1; then
    DOCKER_BIN=(docker)
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n docker ps >/dev/null 2>&1 || sudo docker ps >/dev/null 2>&1; then
      DOCKER_BIN=(sudo docker)
      return 0
    fi
  fi
  return 1
}

docker_cmd() {
  [[ ${#DOCKER_BIN[@]} -gt 0 ]] || init_docker_bin || return 1
  "${DOCKER_BIN[@]}" "$@"
}

# Per-container php binary (1Panel images may not have php on PATH)
DOCKER_PHP_BIN=""
# 1Panel host bind-mount paths (config must be written on host, not ephemeral container layer)
PANEL_HOST_PHP_INI=""
PANEL_HOST_CONF_D=""
PANEL_HOST_EXT_BASE=""
PANEL_MODE=0

sanitize_php_ver() {
  local v="$1"
  v="$(printf '%s' "$v" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$v"
    return 0
  fi
  return 1
}

# php CLI inside container (PATH may omit /usr/local/bin/php)
find_docker_php_bin() {
  local id="$1"
  local c
  for c in /usr/local/bin/php php /usr/bin/php; do
    if docker_cmd exec "$id" "$c" -r 'echo PHP_MAJOR_VERSION;' >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

docker_php_ver() {
  local id="$1" bin="$2"
  sanitize_php_ver "$(docker_cmd exec "$id" "$bin" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)" || true
}

# Detect 1Panel bind mounts: config/extension live on host under /opt/1panel/runtime/php/
detect_1panel_host_paths() {
  local id="$1" name="$2" ver="${3:-}"
  local src dest base

  PANEL_HOST_PHP_INI=""
  PANEL_HOST_CONF_D=""
  PANEL_HOST_EXT_BASE=""
  PANEL_MODE=0

  while IFS=$'\t' read -r src dest; do
    [[ -n "$src" && -n "$dest" ]] || continue
    case "$dest" in
      */php.ini) PANEL_HOST_PHP_INI="$src" ;;
      */conf.d|*/conf.d/) PANEL_HOST_CONF_D="${src%/}" ;;
      */extensions|*/extensions/) PANEL_HOST_EXT_BASE="${src%/}" ;;
    esac
  done < <(docker_cmd inspect -f '{{range .Mounts}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' "$id" 2>/dev/null || true)

  # Host layout fallbacks (1Panel v1: PHP82, v2: php-8.2)
  base="/opt/1panel/runtime/php/${name}"
  if [[ -z "$PANEL_HOST_PHP_INI" ]]; then
    for src in \
      "${base}/conf/php.ini" \
      "${base}/php/php.ini" \
      "${base}/php.ini"
    do
      [[ -f "$src" ]] && PANEL_HOST_PHP_INI="$src" && break
    done
  fi
  if [[ -z "$PANEL_HOST_CONF_D" ]]; then
    for src in \
      "${base}/conf/conf.d" \
      "${base}/php/conf.d" \
      "${base}/conf.d"
    do
      [[ -d "$src" ]] && PANEL_HOST_CONF_D="$src" && break
    done
  fi
  if [[ -n "$ver" && -z "$PANEL_HOST_CONF_D" ]]; then
    for src in \
      "/opt/1panel/runtime/php/php-${ver}/conf/conf.d" \
      "/opt/1panel/runtime/php/php${ver//./}/conf/conf.d"
    do
      [[ -d "$src" ]] && PANEL_HOST_CONF_D="$src" && break
    done
  fi
  if [[ -z "$PANEL_HOST_EXT_BASE" && -d "${base}/extensions" ]]; then
    PANEL_HOST_EXT_BASE="${base}/extensions"
  fi

  if [[ -n "$PANEL_HOST_PHP_INI" || -n "$PANEL_HOST_CONF_D" || -n "$PANEL_HOST_EXT_BASE" ]]; then
    PANEL_MODE=1
    return 0
  fi
  return 1
}

# Host extension dir with API suffix (no-debug-non-zts-XXXXXXXX)
resolve_1panel_ext_dir() {
  local id="$1" base="$2" bin="$3"
  local zend sub existing

  [[ -n "$base" ]] || return 1
  zend="$(docker_cmd exec "$id" "$bin" -r 'echo ZEND_MODULE_API_NO;' 2>/dev/null || true)"
  for sub in "no-debug-non-zts-${zend}" "no-debug-zts-${zend}"; do
    [[ -n "$zend" && -d "${base}/${sub}" ]] && printf '%s' "${base}/${sub}" && return 0
  done
  existing="$(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
  [[ -n "$existing" ]] && printf '%s' "$existing" && return 0
  if [[ -n "$zend" ]]; then
    mkdir -p "${base}/no-debug-non-zts-${zend}" 2>/dev/null || sudo mkdir -p "${base}/no-debug-non-zts-${zend}" 2>/dev/null || true
    printf '%s' "${base}/no-debug-non-zts-${zend}"
    return 0
  fi
  printf '%s' "$base"
}

resolve_1panel_ini_targets() {
  local -a targets=()
  # 1Panel FPM + 面板「配置」读的是主 php.ini；仅写 conf.d 面板里看不到，网站也可能不生效
  if [[ -n "$PANEL_HOST_PHP_INI" && -f "$PANEL_HOST_PHP_INI" ]]; then
    targets+=("$PANEL_HOST_PHP_INI")
  elif [[ -n "$PANEL_HOST_CONF_D" && -d "$PANEL_HOST_CONF_D" ]]; then
    targets+=("${PANEL_HOST_CONF_D}/99-core_loader.ini")
  fi
  if [[ ${#targets[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${targets[@]}"
}

# Match extension= line style already used in 1Panel php.ini (quoted basename vs container path)
detect_1panel_ini_line() {
  local id="$1" bin="$2" host_ini="${3:-}"
  local ext_dir container_path

  ext_dir="$(docker_cmd exec "$id" "$bin" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
  ext_dir="${ext_dir%/}"
  container_path="${ext_dir}/${DEST_NAME}"

  if [[ -n "$host_ini" && -f "$host_ini" ]]; then
    if grep -qE '^[[:space:]]*extension[[:space:]]*=[[:space:]]*/usr/local/lib/php/extensions/' "$host_ini" 2>/dev/null; then
      printf 'extension=%s' "$container_path"
      return 0
    fi
    if grep -qE '^[[:space:]]*extension[[:space:]]*=[[:space:]]*"[^"/]+\.so"' "$host_ini" 2>/dev/null; then
      printf 'extension="%s"' "$DEST_NAME"
      return 0
    fi
  fi
  printf 'extension="%s"' "$DEST_NAME"
}

# List running PHP containers: ID<TAB>NAME<TAB>IMAGE<TAB>PHP_VER(or -)
list_php_docker_rows() {
  local id name image ver line bin
  local -a rows=()
  init_docker_bin || return 1

  while IFS=$'\t' read -r id name image; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "$name $image" | grep -qiE 'php|fpm|1panel|^PHP[0-9]+$' || continue
    bin="$(find_docker_php_bin "$id" || true)"
    [[ -n "$bin" ]] || continue
    ver="$(docker_php_ver "$id" "$bin")"
    [[ -n "$ver" ]] || continue
    rows+=("${id}"$'\t'"${name}"$'\t'"${image}"$'\t'"${ver}")
  done < <(docker_cmd ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null || true)

  # Fallback: probe all running containers for php CLI
  if [[ ${#rows[@]} -eq 0 ]]; then
    while IFS=$'\t' read -r id name image; do
      [[ -n "$id" ]] || continue
      bin="$(find_docker_php_bin "$id" || true)"
      [[ -n "$bin" ]] || continue
      ver="$(docker_php_ver "$id" "$bin")"
      [[ -n "$ver" ]] || continue
      rows+=("${id}"$'\t'"${name}"$'\t'"${image}"$'\t'"${ver}")
    done < <(docker_cmd ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null || true)
  fi

  for line in "${rows[@]+"${rows[@]}"}"; do
    printf '%s\n' "$line"
  done
  [[ ${#rows[@]} -gt 0 ]]
}

# Resolve DOCKER_TARGET → DOCKER_ID / DOCKER_NAME; optional PHP_VER filter
# Multiple containers: require explicit PHP version (bash -s -- 8.5); never install all versions at once.
DOCKER_AUTO_TARGETS=""
resolve_docker_container() {
  local target="${1:-auto}"
  local want_ver="${2:-}"
  local id name image ver rows matched n
  init_docker_bin || { echo "Error: docker not available" >&2; exit 1; }
  DOCKER_AUTO_TARGETS=""

  if [[ "$target" != "auto" ]]; then
    id="$(docker_cmd inspect -f '{{.Id}}' "$target" 2>/dev/null | cut -c1-12 || true)"
    if [[ -z "$id" ]]; then
      id="$(docker_cmd ps --format '{{.ID}}\t{{.Names}}' 2>/dev/null | awk -v t="$target" 'index($1,t)==1 || $2==t || index($2,t)>0 {print $1; exit}')"
    fi
    [[ -n "$id" ]] || { echo "Error: docker container not found: $target" >&2; exit 1; }
    DOCKER_PHP_BIN="$(find_docker_php_bin "$id" || true)"
    [[ -n "$DOCKER_PHP_BIN" ]] || { echo "Error: container has no usable php CLI: $target" >&2; exit 1; }
    ver="$(docker_php_ver "$id" "$DOCKER_PHP_BIN")"
    [[ -n "$ver" ]] || { echo "Error: could not detect PHP version in: $target" >&2; exit 1; }
    if [[ -n "$want_ver" && "$ver" != "$want_ver" ]]; then
      echo "Error: container ${target} PHP is ${ver}, but ${want_ver} was requested" >&2
      exit 1
    fi
    DOCKER_ID="$id"
    DOCKER_NAME="$(docker_cmd inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
    DOCKER_AUTO_TARGETS="${DOCKER_ID}|${DOCKER_NAME}|${ver}"$'\n'
    return 0
  fi

  rows="$(list_php_docker_rows || true)"
  [[ -n "$rows" ]] || {
    echo "Error: no running PHP/1Panel docker container found" >&2
    echo "Hint: docker ps | grep -i php" >&2
    exit 1
  }

  matched=""
  if [[ -n "$want_ver" ]]; then
    while IFS=$'\t' read -r id name image ver; do
      [[ "$ver" == "$want_ver" ]] || continue
      matched+="${id}"$'\t'"${name}"$'\t'"${image}"$'\t'"${ver}"$'\n'
    done <<< "$rows"
    [[ -n "$matched" ]] || {
      echo "Error: no PHP ${want_ver} container found among:" >&2
      printf '%s\n' "$rows" | awk -F'\t' '{printf "  %-14s %-40s php=%s\n", $1, $2, $4}' >&2
      exit 1
    }
  else
    n="$(printf '%s' "$rows" | grep -c . || true)"
    if [[ "$n" -gt 1 ]]; then
      echo "Multiple PHP containers found; specify PHP version:" >&2
      echo "  curl -fsSL ${INSTALL_BASE}/install.sh | bash -s -- 8.5" >&2
      printf '%s\n' "$rows" | awk -F'\t' '{printf "  %-14s %-40s php=%s\n", $1, $2, $4}' >&2
      exit 1
    fi
    matched="$rows"
  fi

  n="$(printf '%s' "$matched" | grep -c . || true)"
  if [[ "$n" -gt 1 ]]; then
    while IFS=$'\t' read -r id name image ver; do
      [[ -n "$id" ]] || continue
      DOCKER_AUTO_TARGETS+="${id}|${name}|${ver}"$'\n'
    done <<< "$matched"
    IFS=$'\t' read -r DOCKER_ID DOCKER_NAME image ver <<< "$(printf '%s\n' "$matched" | head -1)"
    echo "Detected ${n} PHP ${want_ver} containers; will install into each:"
    printf '%s\n' "$matched" | awk -F'\t' '{printf "  %-14s %-40s php=%s\n", $1, $2, $4}'
    return 0
  fi

  IFS=$'\t' read -r DOCKER_ID DOCKER_NAME image ver <<< "$(printf '%s\n' "$matched" | head -1)"
  [[ -n "$DOCKER_ID" ]] || { echo "Error: failed to select docker container" >&2; exit 1; }
  DOCKER_AUTO_TARGETS="${DOCKER_ID}|${DOCKER_NAME}|${ver}"$'\n'
}

docker_php() {
  local bin="${DOCKER_PHP_BIN:-php}"
  docker_cmd exec "$DOCKER_ID" "$bin" "$@"
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
# When DOCKER_ID is set, probe php --ini inside the container (no host -d checks).
resolve_ini_targets() {
  local php_bin="$1"
  local ini_out loaded scan etc_dir major minor compact
  local -a targets=()
  if [[ -n "$DOCKER_ID" ]]; then
    ini_out="$(docker_php --ini 2>/dev/null || true)"
  else
    ini_out="$("$php_bin" --ini 2>/dev/null || true)"
  fi
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
  elif [[ -n "$DOCKER_ID" ]]; then
    # Container: trust common official-image / 1Panel paths when scan is empty
    if [[ -n "$etc_dir" ]]; then
      if docker_cmd exec "$DOCKER_ID" test -d "${etc_dir}/conf.d" 2>/dev/null; then
        targets+=("${etc_dir}/conf.d/99-core_loader.ini")
      elif docker_cmd exec "$DOCKER_ID" test -d "${etc_dir}/php.d" 2>/dev/null; then
        targets+=("${etc_dir}/php.d/99-core_loader.ini")
      fi
    fi
  elif [[ -n "$etc_dir" && -d "${etc_dir}/php.d" ]]; then
    targets+=("${etc_dir}/php.d/99-core_loader.ini")
  elif [[ -d "/www/server/php/${compact}/etc/php.d" ]]; then
    targets+=("/www/server/php/${compact}/etc/php.d/99-core_loader.ini")
  fi

  # 2) No drop-in: write web php.ini (and php-cli.ini), never quotes-wrapped paths
  if [[ ${#targets[@]} -eq 0 ]]; then
    if [[ -n "$DOCKER_ID" ]]; then
      if [[ -n "$loaded" && "$loaded" != "(none)" && "$loaded" != "none" ]]; then
        targets+=("$loaded")
      fi
    elif [[ -f "/www/server/php/${compact}/etc/php.ini" ]]; then
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

  if [[ -f "$path" ]] && grep -Eq "^[[:space:]]*extension[[:space:]]*=[[:space:]]*(\"|')?(core_loader\\.so|${DEST_NAME})(\"|')?([[:space:]]|;|$)|^[[:space:]]*extension[[:space:]]*=.*/${DEST_NAME}([[:space:]]|;|$)" "$path" 2>/dev/null; then
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
    if ! grep -Eq "^[[:space:]]*extension[[:space:]]*=[[:space:]]*(\"|')?(core_loader\\.so|${DEST_NAME})(\"|')?([[:space:]]|;|$)|^[[:space:]]*extension[[:space:]]*=.*/${DEST_NAME}([[:space:]]|;|$)" "$tmp"; then
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

# Copy ini out of container → edit on host → copy back (paths are container paths)
append_or_create_ini_docker() {
  local path="$1"
  local line="$2"
  local comment="$3"
  local work local_path
  work="$(mktemp -d)"
  local_path="${work}/$(basename "$path")"
  docker_cmd exec "$DOCKER_ID" mkdir -p "$(dirname "$path")" >/dev/null 2>&1 || true
  if docker_cmd exec "$DOCKER_ID" test -f "$path" 2>/dev/null; then
    docker_cmd cp "${DOCKER_ID}:${path}" "$local_path" >/dev/null
  else
    : >"$local_path"
  fi
  # Suppress local-path messages from append_or_create_ini; print container path below
  if ! append_or_create_ini "$local_path" "$line" "$comment" >/dev/null; then
    rm -rf "$work"
    return 1
  fi
  if ! docker_cmd cp "$local_path" "${DOCKER_ID}:${path}" >/dev/null; then
    echo "Error: cannot write ${path} in container ${DOCKER_NAME:-$DOCKER_ID}" >&2
    rm -rf "$work"
    return 1
  fi
  echo "  ini: updated ${DOCKER_NAME:-$DOCKER_ID}:${path}"
  rm -rf "$work"
  return 0
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

USER_PHP_BIN="$PHP_BIN"
USER_INSTALL_DIR="$INSTALL_DIR"
USER_INI_FILE="$INI_FILE"
REQUESTED_PHP_VER="$PHP_VER"

# Auto-detect 1Panel/Docker when host has no php (bare: curl … | bash)
if [[ -z "$DOCKER_TARGET" ]] && ! command -v php >/dev/null 2>&1; then
  if init_docker_bin; then
    _php_rows="$(list_php_docker_rows 2>/dev/null || true)"
    if [[ -n "$_php_rows" ]]; then
      echo "No host php found; auto-detected Docker/1Panel PHP runtime"
      DOCKER_TARGET="auto"
    fi
  fi
fi

DEST_NAME="core_loader.so"
INI_LINE="extension=${DEST_NAME}"

# Release label for ini comment, e.g. "; Core Loader 8.0.0"
PRODUCT_VER="${VERSION#v}"
if [[ "$PRODUCT_VER" == "latest" || -z "$PRODUCT_VER" ]]; then
  PRODUCT_VER="8.0.0"
  _ver_file="$(curl -fsSL --connect-timeout 5 --max-time 10 "${DOWNLOAD_URL%/}/VERSION" 2>/dev/null || true)"
  if [[ -n "${_ver_file:-}" ]]; then
    PRODUCT_VER="$(printf '%s' "$_ver_file" | head -1 | tr -d '\r' | sed 's/^v//')"
  fi
fi
INI_COMMENT="; Core Loader ${PRODUCT_VER}"

validate_php_ver() {
  sanitize_php_ver "$1" >/dev/null || {
    echo "Error: unsupported PHP version '$1' (supported: 7.0–8.5)" >&2
    echo "Hint: --version is the GitHub Release tag (e.g. v8.0.0); use --php 8.3 for PHP version." >&2
    return 1
  }
  case "$(sanitize_php_ver "$1")" in
    7.0|7.1|7.2|7.3|7.4|8.0|8.1|8.2|8.3|8.4|8.5) return 0 ;;
    *)
      echo "Error: unsupported PHP version '$1' (supported: 7.0–8.5)" >&2
      echo "Hint: --version is the GitHub Release tag (e.g. v8.0.0); use --php 8.3 for PHP version." >&2
      return 1
      ;;
  esac
}

build_download_urls_for() {
  local asset="$1"
  printf '%s\n' "${DOWNLOAD_URL%/}/${asset}" "${FALLBACK_URL%/}/${asset}"
}

download_asset() {
  local dest="$1"
  shift
  local url
  local -a urls=("$@")
  local idx=0
  local connect_to max_to

  echo "Downloading:"
  for url in "${urls[@]}"; do
    idx=$((idx + 1))
    rm -f "$dest"
    if [[ "$idx" -eq 1 ]]; then
      connect_to=8
      max_to=45
    else
      echo "Switching to backup..."
      connect_to=10
      max_to=180
    fi
    if curl -fL --connect-timeout "$connect_to" --max-time "$max_to" --retry 1 \
         -# -o "$dest" "$url" 2>&1; then
      if [[ -s "$dest" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# Cache downloaded assets across multi-container installs
ASSET_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/core_loader_cache.XXXXXX")"
cleanup_all() { rm -rf "$ASSET_CACHE_DIR"; }
trap cleanup_all EXIT

ensure_asset_file() {
  local asset="$1"
  local out="$2"
  local cached="${ASSET_CACHE_DIR}/${asset}"
  local -a urls=()
  local u magic

  if [[ -s "$cached" ]]; then
    cp -f "$cached" "$out"
    return 0
  fi
  while IFS= read -r u; do
    [[ -n "$u" ]] && urls+=("$u")
  done < <(build_download_urls_for "$asset")
  if ! download_asset "$out" "${urls[@]}"; then
    echo "Error: download failed (primary + backup): ${asset}" >&2
    echo "  primary: ${urls[0]:-}" >&2
    echo "  backup:  ${urls[1]:-}" >&2
    return 1
  fi
  magic="$(xxd -l 4 -p "$out" 2>/dev/null || od -An -tx1 -N4 "$out" | tr -d ' \n')"
  magic="$(echo "$magic" | tr -d ' \n')"
  case "$OS" in
    linux)
      if [[ "$magic" != 7f454c46 ]]; then
        echo "Error: downloaded file is not an ELF shared object (magic=$magic)" >&2
        return 1
      fi
      ;;
    darwin)
      case "$magic" in
        cffaedfe|feedfacf|cafebabe|befaceca) ;;
        *)
          echo "Error: downloaded file is not a Mach-O library (magic=$magic)" >&2
          return 1
          ;;
      esac
      ;;
  esac
  cp -f "$out" "$cached"
  return 0
}

reload_one_docker() {
  local id="$1" name="$2" panel="${3:-0}"
  echo "Reloading PHP-FPM (${name:-$id})..."

  # 1Panel runtime: supervisord is PID 1; php-fpm is [program:php-fpm]
  if [[ "$panel" -eq 1 ]] || docker_cmd exec "$id" sh -c 'test -S /run/supervisor.sock 2>/dev/null || test -f /run/supervisord.pid' 2>/dev/null; then
    for svc in php-fpm php-fpm_00; do
      if docker_cmd exec "$id" supervisorctl restart "$svc" >/dev/null 2>&1; then
        echo "  reloaded via supervisorctl restart ${svc} (${name:-$id})"
        return 0
      fi
    done
    if docker_cmd exec "$id" sh -c '
      command -v supervisorctl >/dev/null 2>&1 || exit 1
      for s in $(supervisorctl status 2>/dev/null | awk "/php-fpm/{print \$1}"); do
        supervisorctl restart "$s" && exit 0
      done
      exit 1
    ' >/dev/null 2>&1; then
      echo "  reloaded via supervisorctl (${name:-$id})"
      return 0
    fi
  fi

  # USR2 → php-fpm master only (never PID 1 — often supervisord on 1Panel)
  if docker_cmd exec "$id" sh -c '
    if command -v pkill >/dev/null 2>&1; then
      pkill -o -USR2 php-fpm 2>/dev/null && exit 0
    fi
    if command -v pgrep >/dev/null 2>&1; then
      m=$(pgrep -o -f "php-fpm: master" 2>/dev/null || pgrep -o php-fpm 2>/dev/null || true)
      [ -n "$m" ] && [ "$m" != "1" ] && kill -USR2 "$m" 2>/dev/null && exit 0
    fi
    for f in /run/php/*.pid /var/run/php/*.pid /usr/local/var/run/*.pid /tmp/php-fpm.pid /var/run/php-fpm.pid; do
      [ -f "$f" ] || continue
      pid=$(cat "$f" 2>/dev/null) || continue
      [ "$pid" != "1" ] || continue
      kill -USR2 "$pid" 2>/dev/null && exit 0
    done
    exit 1
  ' >/dev/null 2>&1; then
    echo "  reloaded via USR2 php-fpm master (${name:-$id})"
    return 0
  fi

  if docker_cmd restart "$id" >/dev/null 2>&1; then
    echo "  restarted docker container ${name:-$id}"
    return 0
  fi

  echo "  warning: could not reload PHP-FPM automatically"
  if [[ "$panel" -eq 1 ]]; then
    echo "  hint: 1Panel → 网站 → 运行环境 → ${name} → 重载/重启"
  fi
  return 1
}

install_one_docker() {
  local id="$1" name="$2" ver="$3"
  local asset dest tmp install_dir host_install=0
  local -a ini_targets=()
  local _ini _ini_fail saved_dir saved_ini ini_line
  local bin

  ver="$(sanitize_php_ver "$ver" || true)"
  [[ -n "$ver" ]] || {
    echo "Warning: skip ${name:-$id} (could not detect PHP version)" >&2
    return 0
  }
  validate_php_ver "$ver" || return 1
  if [[ -n "$REQUESTED_PHP_VER" && "$ver" != "$REQUESTED_PHP_VER" ]]; then
    echo "Error: container ${name} PHP is ${ver}, but -php ${REQUESTED_PHP_VER} was requested" >&2
    return 1
  fi

  DOCKER_ID="$id"
  DOCKER_NAME="$name"
  PHP_VER="$ver"
  DOCKER_PHP_BIN="$(find_docker_php_bin "$id" || true)"
  [[ -n "$DOCKER_PHP_BIN" ]] || {
    echo "Warning: skip ${name:-$id} (no php CLI in container)" >&2
    return 0
  }
  PHP_BIN="docker:${name:-$id}:${DOCKER_PHP_BIN}"
  asset="core_loader-php${ver}-${OS}-${ARCH}.so"
  ini_line="$INI_LINE"

  saved_dir="$USER_INSTALL_DIR"
  saved_ini="$USER_INI_FILE"
  install_dir="$saved_dir"
  host_install=0

  if detect_1panel_host_paths "$id" "$name" "$ver"; then
    host_install=1
    if [[ -z "$install_dir" && -n "$PANEL_HOST_EXT_BASE" ]]; then
      install_dir="$(resolve_1panel_ext_dir "$id" "$PANEL_HOST_EXT_BASE" "$DOCKER_PHP_BIN" || true)"
    fi
  fi

  if [[ -z "$install_dir" ]]; then
    install_dir="$(docker_php -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
  fi
  if [[ -z "$install_dir" || "$install_dir" == "." ]]; then
    echo "Error: could not detect extension_dir in ${name:-$id}; pass --dir" >&2
    return 1
  fi
  dest="${install_dir%/}/${DEST_NAME}"

  ini_targets=()
  if [[ "$NO_INI" -eq 0 ]]; then
    if [[ -n "$saved_ini" ]]; then
      ini_targets+=("$(normalize_ini_path "$saved_ini")")
    elif [[ "$host_install" -eq 1 ]]; then
      while IFS= read -r _ini; do
        [[ -n "$_ini" ]] && ini_targets+=("$_ini")
      done < <(resolve_1panel_ini_targets || true)
      if [[ ${#ini_targets[@]} -eq 0 ]]; then
        while IFS= read -r _ini; do
          [[ -n "$_ini" ]] && ini_targets+=("$_ini")
        done < <(resolve_ini_targets "$PHP_BIN" || true)
      fi
    else
      while IFS= read -r _ini; do
        [[ -n "$_ini" ]] && ini_targets+=("$_ini")
      done < <(resolve_ini_targets "$PHP_BIN" || true)
    fi
    if [[ ${#ini_targets[@]} -eq 0 ]]; then
      echo "Warning: could not detect php.ini in ${name:-$id}; skip auto config" >&2
    fi
  fi

  if [[ "$host_install" -eq 1 && ${#ini_targets[@]} -gt 0 ]]; then
    ini_line="$(detect_1panel_ini_line "$id" "$DOCKER_PHP_BIN" "${ini_targets[0]}")"
  fi

  echo ""
  echo "Core Loader install"
  echo "  PHP:     ${ver} (${PHP_BIN})"
  echo "  Docker:  ${name:-$id}"
  if [[ "$host_install" -eq 1 ]]; then
    echo "  1Panel:  write config to host php.ini (FPM / panel UI)"
  fi
  echo "  OS/Arch: ${OS}-${ARCH}"
  echo "  Asset:   ${asset}"
  echo "  To:      ${dest}"
  if [[ "$NO_INI" -eq 0 && ${#ini_targets[@]} -gt 0 ]]; then
    echo "  Ini:     ${ini_targets[*]}"
  else
    echo "  Ini:     (skipped)"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] skip download/install/ini"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/core_loader.XXXXXX.so")"
  if ! ensure_asset_file "$asset" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ "$host_install" -eq 1 ]]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null || sudo mkdir -p "$(dirname "$dest")"
    if ! cp -f "$tmp" "$dest" 2>/dev/null; then
      sudo cp -f "$tmp" "$dest" || {
        echo "Error: cannot write extension to ${dest}" >&2
        rm -f "$tmp"
        return 1
      }
    fi
    chmod 755 "$dest" 2>/dev/null || sudo chmod 755 "$dest" 2>/dev/null || true
  else
    docker_cmd exec "$id" mkdir -p "$install_dir" >/dev/null
    if ! docker_cmd cp "$tmp" "${id}:${dest}" >/dev/null; then
      echo "Error: docker cp failed → ${name:-$id}:${dest}" >&2
      rm -f "$tmp"
      return 1
    fi
    docker_cmd exec "$id" chmod 755 "$dest" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp"
  echo "Installed: ${dest}"

  if [[ "$NO_INI" -eq 0 && ${#ini_targets[@]} -gt 0 ]]; then
    echo "Configuring PHP..."
    _ini_fail=0
    for _ini in "${ini_targets[@]}"; do
      if [[ "$_ini" == /opt/1panel/* ]] || { [[ "$host_install" -eq 1 ]] && [[ -f "$_ini" || -d "$(dirname "$_ini")" ]]; }; then
        if ! append_or_create_ini "$_ini" "$ini_line" "$INI_COMMENT"; then
          _ini_fail=1
        fi
      else
        if ! append_or_create_ini_docker "$_ini" "$ini_line" "$INI_COMMENT"; then
          _ini_fail=1
        fi
      fi
    done
    if [[ "$_ini_fail" -ne 0 ]]; then
      echo "Error: failed to update ini for ${name:-$id}" >&2
      return 1
    fi
    # Old installs wrote conf.d only; 1Panel FPM reads php.ini — remove stale drop-in
    if [[ "$host_install" -eq 1 && -n "$PANEL_HOST_CONF_D" && -f "${PANEL_HOST_CONF_D}/99-core_loader.ini" \
        && -n "$PANEL_HOST_PHP_INI" ]] && grep -q core_loader "$PANEL_HOST_PHP_INI" 2>/dev/null; then
      rm -f "${PANEL_HOST_CONF_D}/99-core_loader.ini" 2>/dev/null || sudo rm -f "${PANEL_HOST_CONF_D}/99-core_loader.ini" 2>/dev/null || true
      echo "  note: removed stale ${PANEL_HOST_CONF_D}/99-core_loader.ini (using php.ini)"
    fi
  fi

  if [[ "$NO_RELOAD" -eq 0 ]]; then
    reload_one_docker "$id" "$name" "$host_install" || true
    sleep 1
  fi

  bin="$DOCKER_PHP_BIN"
  if docker_cmd exec "$id" "$bin" -m 2>/dev/null | grep -q core_loader; then
    echo "Verified: core_loader loaded (CLI) in ${name:-$id}"
  else
    echo "Warning: core_loader not in php -m (CLI); check config or restart container"
  fi
  if [[ "$host_install" -eq 1 && -n "$PANEL_HOST_PHP_INI" && -f "$PANEL_HOST_PHP_INI" ]]; then
    if grep -q core_loader "$PANEL_HOST_PHP_INI" 2>/dev/null; then
      echo "Verified: core_loader present in ${PANEL_HOST_PHP_INI}"
    else
      echo "Warning: ${PANEL_HOST_PHP_INI} has no core_loader line — reload PHP in 1Panel panel"
    fi
  fi
  echo "  docker exec ${name:-$id} ${bin} -m | grep core_loader"
  return 0
}

# ——— Docker / 1Panel path ———
if [[ -n "$DOCKER_TARGET" ]]; then
  resolve_docker_container "$DOCKER_TARGET" "$REQUESTED_PHP_VER"
  _fail=0
  while IFS='|' read -r _id _name _ver; do
    [[ -n "$_id" ]] || continue
    if ! install_one_docker "$_id" "$_name" "$_ver"; then
      _fail=1
    fi
  done <<< "$DOCKER_AUTO_TARGETS"
  if [[ "$_fail" -ne 0 ]]; then
    exit 1
  fi
  echo ""
  echo "Done."
  exit 0
fi

# ——— Host PHP path ———
if [[ -z "$PHP_VER" ]]; then
  need_cmd php
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
fi
validate_php_ver "$PHP_VER" || exit 1

if [[ -n "$USER_PHP_BIN" ]]; then
  PHP_BIN="$USER_PHP_BIN"
  [[ -x "$PHP_BIN" ]] || { echo "Error: --php-bin not executable: $PHP_BIN" >&2; exit 1; }
else
  if ! PHP_BIN="$(find_php_bin "$PHP_VER")"; then
    # Last chance: host asked for a version but binary missing → try Docker
    if init_docker_bin && [[ -n "$(list_php_docker_rows 2>/dev/null || true)" ]]; then
      echo "Host PHP ${PHP_VER} not found; falling back to Docker/1Panel"
      DOCKER_TARGET="auto"
      resolve_docker_container "auto" "$PHP_VER"
      _fail=0
      while IFS='|' read -r _id _name _ver; do
        [[ -n "$_id" ]] || continue
        if ! install_one_docker "$_id" "$_name" "$_ver"; then
          _fail=1
        fi
      done <<< "$DOCKER_AUTO_TARGETS"
      [[ "$_fail" -eq 0 ]] || exit 1
      echo ""
      echo "Done."
      exit 0
    fi
    echo "Error: PHP ${PHP_VER} binary not found. Pass --php-bin /path/to/php" >&2
    exit 1
  fi
fi

ASSET="core_loader-php${PHP_VER}-${OS}-${ARCH}.so"
INSTALL_DIR="$USER_INSTALL_DIR"
INI_FILE="$USER_INI_FILE"

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

URL="${DOWNLOAD_URL%/}/${ASSET}"
FALLBACK_ASSET_URL="${FALLBACK_URL%/}/${ASSET}"
DEST="${INSTALL_DIR%/}/${DEST_NAME}"
TMP="$(mktemp "${TMPDIR:-/tmp}/core_loader.XXXXXX.so")"

echo "Core Loader install"
echo "  PHP:     ${PHP_VER} (${PHP_BIN})"
echo "  OS/Arch: ${OS}-${ARCH}"
echo "  Asset:   ${ASSET}"
echo "  From:    ${URL}"
echo "  Backup:  ${FALLBACK_ASSET_URL}"
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

if ! ensure_asset_file "$ASSET" "$TMP"; then
  echo "Place file manually at: ${DEST}" >&2
  exit 1
fi

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

run_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@" >/dev/null 2>&1
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@" >/dev/null 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

signal_fpm_pidfile() {
  local pidf="$1"
  local pid
  [[ -f "$pidf" ]] || return 1
  pid="$(tr -d ' \r\n' <"$pidf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    if run_cmd kill -USR2 "$pid"; then
      echo "  reloaded via USR2 (${pidf})"
      return 0
    fi
  fi
  return 1
}

reload_php_fpm_docker() {
  local ver="$1"
  local compact="$2"
  local ids id name
  init_docker_bin || return 1

  ids="$(docker_cmd ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | \
    grep -iE "php|fpm|1panel" | \
    grep -iE "${ver}|${compact}|php${compact}|php-${ver}|php${ver}" | \
    awk '{print $1}' || true)"

  if [[ -z "$ids" ]]; then
    ids="$(docker_cmd ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | \
      grep -iE 'php.*fpm|fpm.*php|1panel.*php' | awk '{print $1}' || true)"
  fi

  [[ -n "$ids" ]] || return 1

  for id in $ids; do
    name="$(docker_cmd inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
    if reload_one_docker "$id" "$name" 0; then
      return 0
    fi
  done
  return 1
}

reload_php_fpm() {
  local ver="$1"
  local major="${ver%%.*}"
  local minor="${ver#*.}"
  local compact="${major}${minor}"
  local svc cmd pidf

  echo "Reloading PHP-FPM..."

  # 1) Panel / distro init scripts (宝塔 / aaPanel / 传统 LNMP)
  for cmd in \
    "/etc/init.d/php-fpm-${compact}" \
    "/etc/init.d/php-fpm-${ver}" \
    "/etc/init.d/php-fpm${compact}" \
    "/etc/init.d/php${compact}-fpm" \
    "/etc/init.d/php${ver}-fpm" \
    "/etc/init.d/php-fpm"
  do
    if [[ -x "$cmd" ]]; then
      if run_cmd "$cmd" reload || run_cmd "$cmd" restart; then
        echo "  reloaded via ${cmd}"
        return 0
      fi
    fi
  done

  # 2) systemd (Debian/Ubuntu php8.5-fpm、RHEL php-fpm、面板封装单元)
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || -d /sys/fs/cgroup/systemd ]]; then
    for svc in \
      "php${ver}-fpm" \
      "php${compact}-fpm" \
      "php-fpm-${compact}" \
      "php-fpm${compact}" \
      "php-fpm" \
      "php${major}-fpm"
    do
      if run_cmd systemctl reload "$svc" || run_cmd systemctl restart "$svc"; then
        echo "  reloaded via systemctl ${svc}"
        return 0
      fi
    done
  fi

  # 3) service(8)
  if command -v service >/dev/null 2>&1; then
    for svc in "php${ver}-fpm" "php${compact}-fpm" "php-fpm-${compact}" "php-fpm"; do
      if run_cmd service "$svc" reload || run_cmd service "$svc" restart; then
        echo "  reloaded via service ${svc}"
        return 0
      fi
    done
  fi

  # 4) supervisor (部分面板 / 容器编排)
  if command -v supervisorctl >/dev/null 2>&1; then
    for svc in "php-fpm" "php${ver}-fpm" "php${compact}-fpm" "php-fpm-${compact}"; do
      if run_cmd supervisorctl restart "$svc" || run_cmd supervisorctl signal USR2 "$svc"; then
        echo "  reloaded via supervisorctl ${svc}"
        return 0
      fi
    done
  fi

  # 5) Direct USR2 via common pid files (host or inside PHP container)
  for pidf in \
    "/www/server/php/${compact}/var/run/php-fpm.pid" \
    "/www/server/php/${ver}/var/run/php-fpm.pid" \
    "/run/php/php${ver}-fpm.pid" \
    "/run/php/php-fpm.pid" \
    "/var/run/php/php${ver}-fpm.pid" \
    "/var/run/php/php-fpm.pid" \
    "/var/run/php-fpm/php-fpm.pid" \
    "/var/run/php-fpm.pid" \
    "/usr/local/var/run/php-fpm.pid" \
    "/tmp/php-fpm.pid"
  do
    signal_fpm_pidfile "$pidf" && return 0
  done
  # glob leftovers
  for pidf in /run/php/*.pid /var/run/php/*.pid; do
    [[ -e "$pidf" ]] || continue
    signal_fpm_pidfile "$pidf" && return 0
  done

  # 6) Docker / 1Panel / Compose PHP containers
  if reload_php_fpm_docker "$ver" "$compact"; then
    return 0
  fi

  # 7) macOS Homebrew
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    if run_cmd brew services restart "php@${ver}" || run_cmd brew services restart php; then
      echo "  restarted via brew services"
      return 0
    fi
  fi

  # 8) Last resort: pkill php-fpm master gracefully (USR2)
  if command -v pgrep >/dev/null 2>&1; then
    local master
    master="$(pgrep -o -f 'php-fpm: master' 2>/dev/null || pgrep -o php-fpm 2>/dev/null || true)"
    if [[ -n "$master" ]] && run_cmd kill -USR2 "$master"; then
      echo "  reloaded via USR2 pgrep master (${master})"
      return 0
    fi
  fi

  echo "  warning: could not auto-reload PHP-FPM; reload/restart your PHP runtime manually"
  return 1
}

if [[ "$NO_RELOAD" -eq 0 ]]; then
  reload_php_fpm "$PHP_VER" || true
fi

echo ""
echo "Done. Verify:"
echo "  ${PHP_BIN} -m | grep core_loader"
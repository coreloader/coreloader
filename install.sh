#!/usr/bin/env bash
# Core Loader — one-click install (Linux / macOS)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version v8.0.0
#   ./install.sh --php 8.3 --dir /usr/lib/php/modules
set -euo pipefail

# Defaults — https://github.com/coreloader/coreloader
DEFAULT_OWNER="${CORELOADER_GH_OWNER:-coreloader}"
DEFAULT_REPO="${CORELOADER_GH_REPO:-coreloader}"
DEFAULT_VERSION="${CORELOADER_VERSION:-latest}"

OWNER="$DEFAULT_OWNER"
REPO="$DEFAULT_REPO"
VERSION="$DEFAULT_VERSION"
PHP_VER=""
INSTALL_DIR=""
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
  --dir PATH         Extension install directory (default: php-config --extension-dir)
  --dry-run          Print actions only
  --force            Overwrite existing core_loader.so
  -h, --help         Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --php) PHP_VER="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
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
need_cmd php

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

detect_php() {
  php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'
}

OS="$(detect_os)"
ARCH="$(detect_arch)"
if [[ -z "$PHP_VER" ]]; then
  PHP_VER="$(detect_php)"
fi

case "$PHP_VER" in
  7.0|7.1|7.2|7.3|7.4|8.0|8.1|8.2|8.3|8.4|8.5) ;;
  *)
    echo "Error: unsupported PHP version '$PHP_VER' (supported: 7.0–8.5)" >&2
    exit 1
    ;;
esac

ASSET="core_loader-php${PHP_VER}-${OS}-${ARCH}.so"
DEST_NAME="core_loader.so"

if [[ -z "$INSTALL_DIR" ]]; then
  if command -v php-config >/dev/null 2>&1; then
    INSTALL_DIR="$(php-config --extension-dir)"
  else
    INSTALL_DIR="$(php -r 'echo ini_get("extension_dir");')"
  fi
fi

if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "." ]]; then
  echo "Error: could not detect extension_dir; pass --dir" >&2
  exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
  URL="https://github.com/${OWNER}/${REPO}/releases/latest/download/${ASSET}"
else
  # Accept v8.0.0 or 8.0.0
  TAG="$VERSION"
  [[ "$TAG" == v* ]] || TAG="v${TAG}"
  URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${ASSET}"
fi

DEST="${INSTALL_DIR%/}/${DEST_NAME}"
TMP="$(mktemp "${TMPDIR:-/tmp}/core_loader.XXXXXX.so")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "Core Loader install"
echo "  PHP:     ${PHP_VER}"
echo "  OS/Arch: ${OS}-${ARCH}"
echo "  Asset:   ${ASSET}"
echo "  From:    ${URL}"
echo "  To:      ${DEST}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] skip download/install"
  exit 0
fi

if [[ -f "$DEST" && "$FORCE" -ne 1 ]]; then
  echo "Error: ${DEST} already exists (use --force to overwrite)" >&2
  exit 1
fi

if ! curl -fsSL -o "$TMP" "$URL"; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' -L "$URL" || echo fail)"
  echo "Error: download failed (HTTP ${code}): ${URL}" >&2
  echo "Check that the release exists and the asset name matches your PHP/OS/arch." >&2
  exit 1
fi
if [[ ! -s "$TMP" ]]; then
  echo "Error: downloaded file is empty: ${URL}" >&2
  exit 1
fi

# Basic ELF / Mach-O sanity
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
    # Mach-O 64-bit: cffaedfe (LE) / feedfacf (BE) ; universal: cafebabe
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
  echo "Retry with sudo, or install to a writable directory:"
  echo "  curl -fsSL https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh | bash -s -- --dir \"\$HOME/php-ext\" --force"
  echo "  # then in php.ini:"
  echo "  # extension=\$HOME/php-ext/core_loader.so"
  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Retry with sudo? [y/N] " ans || true
    if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
      sudo mkdir -p "$INSTALL_DIR"
      sudo cp -f "$TMP" "$DEST"
    else
      exit 1
    fi
  else
    # non-interactive (curl | bash): try sudo -n
    if sudo -n true 2>/dev/null; then
      sudo mkdir -p "$INSTALL_DIR"
      sudo cp -f "$TMP" "$DEST"
    else
      exit 1
    fi
  fi
fi

chmod 755 "$DEST" 2>/dev/null || sudo chmod 755 "$DEST" 2>/dev/null || true

echo ""
echo "Installed: ${DEST}"
echo ""
echo "Add to php.ini (use extension=, NOT zend_extension=):"
echo "  extension=${DEST_NAME}"
echo "  # or absolute path:"
echo "  # extension=${DEST}"
echo ""
echo "Verify:"
echo "  php -m | grep core_loader"
echo "  php -r 'var_export(extension_loaded(\"core_loader\")); echo PHP_EOL;'"

#!/bin/bash
set -euo pipefail

# Flua installer for macOS (Apple Silicon, macOS 27+)
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eclipter/flua/main/install.sh)"
# Or:
#   curl -fsSL https://raw.githubusercontent.com/Eclipter/flua/main/install.sh | bash

REPO="${FLUA_REPO:-Eclipter/flua}"
VERSION="${FLUA_VERSION:-latest}"
INSTALL_DIR="${FLUA_INSTALL_DIR:-/Applications}"
APP_NAME="Flua.app"
TARGET_APP="${INSTALL_DIR}/${APP_NAME}"

# Parse optional arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --dir)
            INSTALL_DIR="$2"
            TARGET_APP="${INSTALL_DIR}/${APP_NAME}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: install.sh [options]"
            echo "Options:"
            echo "  --version <tag>    Install specific release tag (default: latest)"
            echo "  --dir <path>       Target install directory (default: /Applications)"
            echo "  --help, -h         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# Color formatting
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    BLUE=''
    NC=''
fi

info() {
    printf "${BLUE}==>${NC} %s\n" "$*"
}

success() {
    printf "${GREEN}==>${NC} %s\n" "$*"
}

error() {
    printf "${RED}Error:${NC} %s\n" "$*" >&2
}

# 1. Verify operating system
OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    error "Flua requires macOS. Detected OS: $OS"
    exit 1
fi

# 2. Verify architecture (Apple Silicon)
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    error "Flua requires Apple Silicon (arm64). Detected architecture: $ARCH"
    exit 1
fi

# 3. Verify macOS version (macOS 27+)
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="$(echo "$MACOS_VERSION" | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 27 ]; then
    error "Flua requires macOS 27 or later (detected macOS $MACOS_VERSION)."
    exit 1
fi

# 4. Check target directory permissions
if [ ! -d "$INSTALL_DIR" ]; then
    error "Target directory $INSTALL_DIR does not exist."
    exit 1
fi

if [ ! -w "$INSTALL_DIR" ]; then
    error "Target directory $INSTALL_DIR is not writable. Please run with sudo or check directory permissions."
    exit 1
fi

if [ -e "$TARGET_APP" ] && [ ! -w "$TARGET_APP" ]; then
    error "$TARGET_APP exists and is not writable. Please run with sudo or check directory permissions."
    exit 1
fi

# 5. Resolve download URL
if [ -n "${FLUA_DOWNLOAD_URL:-}" ]; then
    DOWNLOAD_URL="$FLUA_DOWNLOAD_URL"
elif [ "$VERSION" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/Flua.zip"
else
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/Flua.zip"
fi

# 6. Set up temporary directory with automated cleanup
TMP_DIR="$(mktemp -d /tmp/flua-install.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM HUP

TMP_ZIP="${TMP_DIR}/Flua.zip"
TMP_EXTRACT="${TMP_DIR}/extract"
mkdir -p "$TMP_EXTRACT"

# 7. Download archive
info "Downloading Flua from $DOWNLOAD_URL..."
if [ -t 1 ]; then
    curl -fL --progress-bar "$DOWNLOAD_URL" -o "$TMP_ZIP"
else
    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_ZIP"
fi

# 8. Unpack archive
info "Extracting archive..."
ditto -x -k "$TMP_ZIP" "$TMP_EXTRACT"

if [ ! -d "${TMP_EXTRACT}/${APP_NAME}" ]; then
    error "Downloaded archive does not contain ${APP_NAME}."
    exit 1
fi

# 9. Install application to target directory
info "Installing to ${TARGET_APP}..."
if pgrep -xq "Flua" 2>/dev/null; then
    info "Closing running Flua instance..."
    killall Flua 2>/dev/null || true
    sleep 1
fi

if [ -e "$TARGET_APP" ]; then
    rm -rf "$TARGET_APP"
fi

cp -R "${TMP_EXTRACT}/${APP_NAME}" "${INSTALL_DIR}/"

# 10. Strip quarantine attribute
info "Removing quarantine attribute..."
xattr -rd com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

success "Flua successfully installed to ${TARGET_APP}!"

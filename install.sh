#!/usr/bin/env bash
set -euo pipefail

# Appitool Installer for macOS (Apple Silicon arm64)
# Usage: curl -fsSL https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | bash

REPO="appibara-ltd/appitool"
GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "🌊 Installing appitool..."

# 1. OS & Architecture Check
if [ "$OS" != "Darwin" ]; then
    echo "❌ Error: Only macOS (Darwin) is currently supported." >&2
    exit 1
fi

if [ "$ARCH" != "arm64" ]; then
    echo "❌ Error: Only Apple Silicon (arm64) is currently supported." >&2
    exit 1
fi

# 2. Fetch Latest Release Metadata
TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

AUTH_HEADER=()
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$TOKEN" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
fi

echo "   🟡 Fetching latest release information..."
RELEASE_JSON="$(curl -fsSL ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} -H "Accept: application/vnd.github.v3+json" "$GITHUB_API" 2>/dev/null || true)"

if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message": *"Not Found"'; then
    echo "❌ Error: Could not fetch releases from GitHub (404 Not Found)." >&2
    if [ -z "$TOKEN" ]; then
        echo "   If this repository is private, please export GITHUB_TOKEN before running:" >&2
        echo "   export GITHUB_TOKEN=\"ghp_...\"" >&2
    fi
    exit 1
fi

TAG_NAME="$(echo "$RELEASE_JSON" | awk -F'"' '/"tag_name":/ { print $4; exit }')"
TARBALL_URL="$(echo "$RELEASE_JSON" | awk -F'"' '/"name": *"appitool-darwin-arm64\.tar\.gz"/ { found=1 } found && /"browser_download_url":/ { print $4; exit }')"
CHECKSUMS_URL="$(echo "$RELEASE_JSON" | awk -F'"' '/"name": *"checksums\.txt"/ { found=1 } found && /"browser_download_url":/ { print $4; exit }')"

TARBALL_API_URL="$(echo "$RELEASE_JSON" | awk -F'"' '/"url":/ { last_url=$4 } /"name": *"appitool-darwin-arm64\.tar\.gz"/ { print last_url; exit }')"
CHECKSUMS_API_URL="$(echo "$RELEASE_JSON" | awk -F'"' '/"url":/ { last_url=$4 } /"name": *"checksums\.txt"/ { print last_url; exit }')"

if [ -z "$TARBALL_URL" ] || [ -z "$CHECKSUMS_URL" ]; then
    echo "❌ Error: Could not locate release artifacts for arm64 macOS (${TAG_NAME:-unknown})." >&2
    exit 1
fi

echo "   🟡 Downloading appitool ${TAG_NAME}..."
if [ -n "$TOKEN" ] && [ -n "$TARBALL_API_URL" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" "$TARBALL_API_URL" -o "$TMP_DIR/appitool-darwin-arm64.tar.gz"
    curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" "$CHECKSUMS_API_URL" -o "$TMP_DIR/checksums.txt"
else
    curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/appitool-darwin-arm64.tar.gz"
    curl -fsSL "$CHECKSUMS_URL" -o "$TMP_DIR/checksums.txt"
fi

# 3. Verify SHA256 Checksum
echo "   🟡 Verifying checksum..."
EXPECTED_SHA="$(grep 'appitool-darwin-arm64\.tar\.gz' "$TMP_DIR/checksums.txt" | awk '{print $1}')"
ACTUAL_SHA="$(shasum -a 256 "$TMP_DIR/appitool-darwin-arm64.tar.gz" | awk '{print $1}')"

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "❌ Error: Checksum verification failed!" >&2
    echo "   Expected: $EXPECTED_SHA" >&2
    echo "   Actual:   $ACTUAL_SHA" >&2
    exit 1
fi
echo "   ✅ Checksum verified."

# 4. Determine Installation Directory
INSTALL_DIR=""
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

echo "   🟡 Installing binary to ${INSTALL_DIR}/appitool..."
tar -xzf "$TMP_DIR/appitool-darwin-arm64.tar.gz" -C "$TMP_DIR"
cp -f "$TMP_DIR/appitool" "$INSTALL_DIR/appitool"
chmod +x "$INSTALL_DIR/appitool"

# 5. Configure PATH if installing to ~/.local/bin
PATH_NEEDS_RELOAD=0
UPDATED_RC=""

if [ "$INSTALL_DIR" = "$HOME/.local/bin" ]; then
    CURRENT_SHELL="$(basename "${SHELL:-}")"
    RC_FILE=""

    case "$CURRENT_SHELL" in
        zsh)
            RC_FILE="$HOME/.zshrc"
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                RC_FILE="$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                RC_FILE="$HOME/.bashrc"
            else
                RC_FILE="$HOME/.bash_profile"
            fi
            ;;
        fish)
            FISH_CONF_DIR="$HOME/.config/fish"
            mkdir -p "$FISH_CONF_DIR"
            RC_FILE="$FISH_CONF_DIR/config.fish"
            ;;
        *)
            if [ -f "$HOME/.zshrc" ]; then
                RC_FILE="$HOME/.zshrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                RC_FILE="$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                RC_FILE="$HOME/.bashrc"
            else
                RC_FILE="$HOME/.profile"
            fi
            ;;
    esac

    # Ensure RC_FILE exists
    touch "$RC_FILE"

    # Check if an active (uncommented) PATH export for ~/.local/bin exists in RC_FILE
    if grep -E '^[[:space:]]*(export[[:space:]]+)?PATH=.*\.local/bin' "$RC_FILE" >/dev/null 2>&1 || \
       grep -E '^[[:space:]]*fish_add_path.*\.local/bin' "$RC_FILE" >/dev/null 2>&1; then
        : # Already explicitly in rc file
    else
        echo "" >> "$RC_FILE"
        echo '# Added by appitool installer' >> "$RC_FILE"
        if [ "$CURRENT_SHELL" = "fish" ]; then
            echo 'fish_add_path -g $HOME/.local/bin' >> "$RC_FILE"
        else
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC_FILE"
        fi
        PATH_NEEDS_RELOAD=1
        UPDATED_RC="$RC_FILE"
    fi

    # Check if ~/.local/bin is actually in the current running environment's PATH
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *)
            PATH_NEEDS_RELOAD=1
            UPDATED_RC="${UPDATED_RC:-$RC_FILE}"
            ;;
    esac
fi

echo "🎉 appitool ${TAG_NAME} installed successfully to ${INSTALL_DIR}/appitool!"
if [ "$PATH_NEEDS_RELOAD" -eq 1 ] && [ -n "$UPDATED_RC" ]; then
    echo ""
    echo "   🚧 PATH Configuration:"
    echo "   Added ~/.local/bin to your ${UPDATED_RC}."
    echo "   To start using 'appitool' in this terminal session, run:"
    echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "   Or reload your configuration:"
    echo "       source ${UPDATED_RC}"
else
    echo "   Run 'appitool --help' to get started."
fi

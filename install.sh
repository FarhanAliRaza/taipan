#!/bin/sh
# taipan installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.sh | sh
#
# Environment variables:
#   TAIPAN_VERSION      Release tag to install (e.g. v0.2.0). Defaults to the
#                       latest release.
#   TAIPAN_INSTALL_DIR  Directory to install into. Defaults to /usr/local/bin,
#                       falling back to ~/.local/bin when /usr/local/bin is not
#                       writable and sudo is unavailable.
set -eu

REPO="FarhanAliRaza/taipan"

err() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf '%s\n' "$1" >&2
}

# --- Detect platform ---------------------------------------------------------

os=$(uname -s)
arch=$(uname -m)

case "$os" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
        err "this installer does not support Windows. Download taipan-windows-x86_64.exe from https://github.com/$REPO/releases and place it on your PATH."
        ;;
    *) err "unsupported operating system: $os" ;;
esac

case "$arch" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) err "unsupported architecture: $arch" ;;
esac

asset="taipan-$os-$arch"

if [ -n "${TAIPAN_VERSION:-}" ]; then
    url="https://github.com/$REPO/releases/download/$TAIPAN_VERSION/$asset"
else
    url="https://github.com/$REPO/releases/latest/download/$asset"
fi

# --- Download ----------------------------------------------------------------

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM
tmpfile="$tmpdir/taipan"

info "Downloading $asset..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmpfile" "$url" || err "download failed: $url"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmpfile" "$url" || err "download failed: $url"
else
    err "neither curl nor wget is available"
fi

chmod +x "$tmpfile"

# --- Install -----------------------------------------------------------------

if [ -n "${TAIPAN_INSTALL_DIR:-}" ]; then
    install_dir=$TAIPAN_INSTALL_DIR
    mkdir -p "$install_dir" || err "cannot create $install_dir"
    mv "$tmpfile" "$install_dir/taipan" || err "cannot write to $install_dir"
elif [ -w /usr/local/bin ]; then
    install_dir=/usr/local/bin
    mv "$tmpfile" "$install_dir/taipan"
elif command -v sudo >/dev/null 2>&1; then
    install_dir=/usr/local/bin
    info "Installing to $install_dir (requires sudo)..."
    sudo mv "$tmpfile" "$install_dir/taipan" || err "cannot write to $install_dir"
else
    install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
    mv "$tmpfile" "$install_dir/taipan"
fi

info "Installed taipan to $install_dir/taipan"

case ":${PATH}:" in
    *":$install_dir:"*) ;;
    *)
        info ""
        info "warning: $install_dir is not on your PATH. Add it with:"
        info "  export PATH=\"$install_dir:\$PATH\""
        ;;
esac

info ""
info "Run 'taipan script.py' to get started."

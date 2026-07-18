#!/bin/sh
# Install taipan on Linux or macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.sh | sh
#
# Detects the platform, downloads the matching binary from the latest GitHub
# release, and installs it as `taipan`.
#
# Environment variables:
#   TAIPAN_VERSION      release tag to install (e.g. v0.2.0); defaults to latest
#   TAIPAN_INSTALL_DIR  directory to install into; defaults to ~/.local/bin

set -eu

REPO="FarhanAliRaza/taipan"

info() { printf '%s\n' "$*"; }
err() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

os=$(uname -s)
case "$os" in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) err "unsupported operating system: $os
On Windows, run the PowerShell installer instead:
  powershell -ExecutionPolicy Bypass -Command \"irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex\"" ;;
esac

arch=$(uname -m)
case "$arch" in
    x86_64 | amd64) cpu=x86_64 ;;
    aarch64 | arm64) cpu=aarch64 ;;
    *) err "unsupported architecture: $arch" ;;
esac

if [ "$platform" = linux ] && ldd --version 2>&1 | grep -qi musl; then
    err "musl-based distributions (e.g. Alpine) are not supported yet; taipan requires glibc"
fi

asset="taipan-$platform-$cpu"
if [ -n "${TAIPAN_VERSION:-}" ]; then
    url="https://github.com/$REPO/releases/download/$TAIPAN_VERSION/$asset"
else
    url="https://github.com/$REPO/releases/latest/download/$asset"
fi

install_dir="${TAIPAN_INSTALL_DIR:-$HOME/.local/bin}"

tmp=$(mktemp "${TMPDIR:-/tmp}/taipan.XXXXXX")
trap 'rm -f "$tmp"' EXIT

info "Downloading $url"
if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$tmp" "$url" || err "download failed: $url"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || err "download failed: $url"
else
    err "neither curl nor wget is available"
fi

mkdir -p "$install_dir"
chmod 755 "$tmp"
mv "$tmp" "$install_dir/taipan"
trap - EXIT

info "Installed taipan to $install_dir/taipan"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        info ""
        info "warning: $install_dir is not on your PATH. Add it with:"
        info "  export PATH=\"$install_dir:\$PATH\""
        ;;
esac

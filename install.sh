#!/bin/sh
set -eu

repo="${TAIPAN_REPOSITORY:-FarhanAliRaza/taipan}"
version="${TAIPAN_VERSION:-latest}"
install_dir="${TAIPAN_INSTALL_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"

case "$(uname -s)" in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *)
        echo "taipan: unsupported operating system: $(uname -s)" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *)
        echo "taipan: unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

artifact="taipan-$platform-$arch"
if [ -n "${TAIPAN_DOWNLOAD_URL:-}" ]; then
    url=$TAIPAN_DOWNLOAD_URL
elif [ "$version" = latest ]; then
    url="https://github.com/$repo/releases/latest/download/$artifact"
else
    url="https://github.com/$repo/releases/download/$version/$artifact"
fi

command -v curl >/dev/null 2>&1 || {
    echo "taipan: curl is required to install taipan" >&2
    exit 1
}

mkdir -p "$install_dir"
dest="$install_dir/taipan"
tmp="$install_dir/.taipan.tmp.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM

echo "taipan: downloading $artifact"
if [ -n "${TAIPAN_DOWNLOAD_URL:-}" ]; then
    curl -LsSf "$url" -o "$tmp"
else
    curl --proto '=https' --tlsv1.2 -LsSf "$url" -o "$tmp"
fi
chmod 755 "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT HUP INT TERM

echo "taipan: installed to $dest"
case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *) echo "taipan: add $install_dir to PATH, or run $dest" ;;
esac

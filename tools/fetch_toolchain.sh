#!/usr/bin/env bash
# Fetch the pinned build toolchain into vendor/: Zig and a python-build-
# standalone CPython (used for headers, libpython, and the stdlib payload).
# Native-only: fetches the toolchain matching the machine it runs on.
# Idempotent — skips anything already present. sha256-verified.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION=0.15.2
PBS_TAG=20260623
PBS_VERSION=3.13.14

case "$(uname -s)-$(uname -m)" in
Linux-x86_64)
    ZIG_PLAT=x86_64-linux
    ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
    PBS_PLAT=x86_64-unknown-linux-gnu
    PBS_SHA256=7fd02919461b368adafea3896ad082f5c4f759816d69681dcc6559bfbcd892af
    ;;
Linux-aarch64)
    ZIG_PLAT=aarch64-linux
    ZIG_SHA256=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f
    PBS_PLAT=aarch64-unknown-linux-gnu
    PBS_SHA256=1199b22c83725a339ebaef36d39476d037fb7267187513090b6cc83bb4579477
    ;;
Darwin-arm64)
    ZIG_PLAT=aarch64-macos
    ZIG_SHA256=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b
    PBS_PLAT=aarch64-apple-darwin
    PBS_SHA256=804c86c8665b18eb0df5070a79d828229018d145baea38a71a5c74c03f9b11d4
    ;;
Darwin-x86_64)
    ZIG_PLAT=x86_64-macos
    ZIG_SHA256=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f
    PBS_PLAT=x86_64-apple-darwin
    PBS_SHA256=cd0023fb84de358d285c8e116cffd2f433086b943e752955dade521c12e78cab
    ;;
*)
    echo "unsupported build platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_PLAT}-${ZIG_VERSION}.tar.xz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_VERSION}%2B${PBS_TAG}-${PBS_PLAT}-install_only.tar.gz"

sha_check() { # sha256 file — macOS has shasum, Linux has sha256sum
    if command -v sha256sum >/dev/null; then
        echo "$1  $2" | sha256sum -c --quiet -
    else
        echo "$1  $2" | shasum -a 256 -c --status -
    fi
}

fetch() { # url sha256 dest-dir strip-tar-flags...
    local url="$1" sha="$2" dest="$3"; shift 3
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    echo "fetching $url" >&2
    curl -fsSL -o "$tmp" "$url"
    sha_check "$sha" "$tmp"
    mkdir -p "$dest"
    tar -xf "$tmp" -C "$dest" "$@"
}

if [ ! -x vendor/zig/zig ]; then
    fetch "$ZIG_URL" "$ZIG_SHA256" vendor/zig --strip-components=1
fi
vendor/zig/zig version >&2

if [ ! -x vendor/cpython/bin/python3 ]; then
    fetch "$PBS_URL" "$PBS_SHA256" vendor/cpython --strip-components=1
fi
vendor/cpython/bin/python3 --version >&2

echo "toolchain ready" >&2

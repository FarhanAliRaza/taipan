#!/usr/bin/env bash
# Fetch the pinned build toolchain into vendor/: Zig and a python-build-
# standalone CPython (used for headers, libpython, and the stdlib payload).
# Idempotent — skips anything already present. sha256-verified.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION=0.15.2
ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"

PBS_TAG=20260623
PBS_VERSION=3.13.14
PBS_SHA256=7fd02919461b368adafea3896ad082f5c4f759816d69681dcc6559bfbcd892af
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_VERSION}%2B${PBS_TAG}-x86_64-unknown-linux-gnu-install_only.tar.gz"

fetch() { # url sha256 dest-dir strip-tar-flags...
    local url="$1" sha="$2" dest="$3"; shift 3
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    echo "fetching $url" >&2
    curl -fsSL -o "$tmp" "$url"
    echo "$sha  $tmp" | sha256sum -c --quiet -
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

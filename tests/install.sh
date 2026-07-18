#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

printf 'fake taipan binary\n' > "$work/artifact"
TAIPAN_INSTALL_DIR="$work/bin" \
TAIPAN_DOWNLOAD_URL="file://$work/artifact" \
    sh "$root/install.sh" > "$work/output"

test -x "$work/bin/taipan"
cmp "$work/artifact" "$work/bin/taipan"
grep -q "taipan: installed to $work/bin/taipan" "$work/output"

# Reinstalling replaces the old binary and does not leave a temporary file.
printf 'updated taipan binary\n' > "$work/artifact"
TAIPAN_INSTALL_DIR="$work/bin" \
TAIPAN_DOWNLOAD_URL="file://$work/artifact" \
    sh "$root/install.sh" >/dev/null

cmp "$work/artifact" "$work/bin/taipan"
test -z "$(find "$work/bin" -name '.taipan.tmp.*' -print -quit)"

echo "installer tests passed"

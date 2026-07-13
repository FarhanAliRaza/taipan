#!/usr/bin/env bash
# Build stdlib.zip: the Python stdlib as bytecode-only zip, embedded into the
# taipan binary and extracted to ~/.cache/taipan/runtime/<tag>/ on first run.
# Usage: make_payload.sh <output-zip>
set -euo pipefail

OUT="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/vendor/cpython/bin/python3"
SRC="$ROOT/vendor/cpython/lib/python3.13"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Not needed at script runtime (or unusable from a zip): trims ~60% of size.
EXCLUDES=(test idlelib tkinter turtledemo ensurepip venv config-3.13-x86_64-linux-gnu
          lib-dynload site-packages __pycache__ turtle.py)

RSYNC_EX=()
for e in "${EXCLUDES[@]}"; do RSYNC_EX+=(--exclude "$e"); done
rsync -a "${RSYNC_EX[@]}" "$SRC/" "$TMP/lib/"

# -b writes legacy-location .pyc (os.pyc next to os.py) — the layout zipimport
# expects at the zip root.
"$PY" -m compileall -b -q -j0 "$TMP/lib" >/dev/null

find "$TMP/lib" -name '*.py' -delete
find "$TMP/lib" -name '__pycache__' -type d -prune -exec rm -rf {} +

"$PY" - "$OUT" "$TMP/lib" <<'EOF'
import os, sys, zipfile
out, root = sys.argv[1], sys.argv[2]
# ZIP_STORED: uncompressed. Deflate saved ~6MB of binary size but cost ~4ms
# of per-import decompression on warm starts — wrong trade for a runner.
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as zf:
    for dp, _, fns in os.walk(root):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            zf.write(p, os.path.relpath(p, root))
EOF

echo "payload: $(du -h "$OUT" | cut -f1) at $OUT" >&2

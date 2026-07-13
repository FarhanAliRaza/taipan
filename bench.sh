#!/usr/bin/env bash
# Reproducible startup/overhead benchmark for the taipan prototype.
#
# Runs a fixed matrix comparing taipan against the system python, the
# same vendored interpreter it embeds, and `uv run`, on both a
# dependency-free script and a PEP 723 script with a cached dependency.
#
# All measurements are WARM: every command is executed once up front so
# venvs, dependency caches and the page cache are already populated, then
# hyperfine runs it with --warmup 3.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

# Make uv (called by taipan on a cache miss) and our vendored hyperfine visible.
export PATH="$HOME/.local/bin:$ROOT/vendor/bin:$PATH"

PYX="$ROOT/zig-out/bin/taipan"
SYS_PY="/usr/bin/python3"
VENDOR_PY="$ROOT/vendor/cpython/bin/python3"
UV="$(command -v uv)"

HELLO="examples/hello.py"
PURE_DEP="examples/pure_dep.py"

# Pick hyperfine: prefer PATH, then the vendored copy.
HF="$(command -v hyperfine || true)"

# Prime every command so all caches/venvs exist and the page/dentry cache is
# fully warm before timing. A single pass is not always enough: on a cache
# miss taipan shells out to `uv pip install`, and the first source-compile of a
# dependency (taipan writes no .pyc) is slow until its files are OS-cached, so we
# prime a few rounds to reach steady state.
echo "Priming caches..."
for _ in 1 2 3; do
  "$PYX" "$HELLO"                      >/dev/null 2>&1 || true
  "$SYS_PY" "$HELLO"                   >/dev/null 2>&1 || true
  "$VENDOR_PY" "$HELLO"                >/dev/null 2>&1 || true
  "$UV" run --no-project "$HELLO"      >/dev/null 2>&1 || true
  "$PYX" run "$PURE_DEP"               >/dev/null 2>&1 || true
  "$UV" run --no-project "$PURE_DEP"   >/dev/null 2>&1 || true
done

OUT_MD="${1:-bench-results.md}"

if [ -n "$HF" ]; then
  "$HF" --warmup 3 --shell=none \
    --command-name "taipan hello (no deps)"            "$PYX $HELLO" \
    --command-name "system python3 hello"           "$SYS_PY $HELLO" \
    --command-name "vendored python3 hello"         "$VENDOR_PY $HELLO" \
    --command-name "uv run hello (no deps)"         "$UV run --no-project $HELLO" \
    --command-name "taipan pure_dep (cached cowsay)"   "$PYX run $PURE_DEP" \
    --command-name "uv run pure_dep (cached)"       "$UV run --no-project $PURE_DEP" \
    --export-markdown "$OUT_MD"
  echo "Markdown table written to $OUT_MD"
else
  # Fallback: shell timing loop, 20 runs, min/mean per command.
  echo "hyperfine not found; using shell timing fallback (20 runs)"
  run_loop() {
    local name="$1"; shift
    local n=20 total=0 min=999999
    for _ in $(seq "$n"); do
      local start end ms
      start=$(date +%s%N)
      "$@" >/dev/null 2>&1 || true
      end=$(date +%s%N)
      ms=$(( (end - start) / 1000000 ))
      total=$(( total + ms ))
      (( ms < min )) && min=$ms
    done
    printf '%-32s min=%dms mean=%dms\n' "$name" "$min" "$(( total / n ))"
  }
  run_loop "taipan hello (no deps)"          "$PYX" "$HELLO"
  run_loop "system python3 hello"         "$SYS_PY" "$HELLO"
  run_loop "vendored python3 hello"       "$VENDOR_PY" "$HELLO"
  run_loop "uv run hello (no deps)"       "$UV" run --no-project "$HELLO"
  run_loop "taipan pure_dep (cached cowsay)" "$PYX" run "$PURE_DEP"
  run_loop "uv run pure_dep (cached)"     "$UV" run --no-project "$PURE_DEP"
fi

#!/bin/bash
# Smoke-test a built taipan binary end-to-end, ideally in a python-less container.
# Usage: smoke.sh <taipan-binary> <examples-dir>
set -u

BIN="${1:?usage: smoke.sh <taipan-binary> <examples-dir>}"
EXAMPLES="${2:?usage: smoke.sh <taipan-binary> <examples-dir>}"
fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

check() { # name expected_exit actual_exit output [expected_substring]
  local name="$1" want="$2" got="$3" out="$4" substr="${5:-}"
  if [ "$got" != "$want" ]; then
    echo "FAIL [$name]: exit $got (wanted $want). Output: $out"; fail=1
  elif [ -n "$substr" ] && ! grep -q "$substr" <<<"$out"; then
    echo "FAIL [$name]: output missing '$substr'. Output: $out"; fail=1
  else
    echo "PASS [$name]"
  fi
}

if command -v python3 >/dev/null || command -v python >/dev/null; then
  echo "note: a system python exists in this environment; test is weaker than python-less"
else
  echo "environment is python-less — good"
fi

# uv bootstrap needs curl + https certs (documented requirement)
if ! command -v curl >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates >/dev/null
  elif command -v dnf >/dev/null; then
    dnf install -y -q curl ca-certificates >/dev/null
  else
    echo "FAIL: no curl and no known package manager"; exit 1
  fi
fi

out=$("$BIN" "$EXAMPLES/hello.py" 2>&1);        check hello 0 $? "$out" "hello"
out=$("$BIN" "$EXAMPLES/pure_dep.py" 2>&1);     check pure-dep-cold 0 $? "$out"
out=$("$BIN" "$EXAMPLES/pure_dep.py" 2>&1);     check pure-dep-warm 0 $? "$out"
out=$("$BIN" "$EXAMPLES/compiled_dep.py" 2>&1); check compiled-dep 0 $? "$out" "WITH C extension"

echo 'import sys; sys.exit(7)' > /tmp/smoke_exit7.py
"$BIN" /tmp/smoke_exit7.py >/dev/null 2>&1;     check exit-code 7 $? ""

echo 'raise ValueError("boom")' > /tmp/smoke_boom.py
out=$("$BIN" /tmp/smoke_boom.py 2>&1);          check traceback 1 $? "$out" "ValueError: boom"

# Build in the container, then remove the inputs and run each artifact with a
# fresh cache and a deliberately invalid uv path. This proves the output is
# self-contained rather than accidentally using the source or build cache.
cp "$EXAMPLES/hello.py" "$work/hello.py"
cp "$EXAMPLES/compiled_dep.py" "$work/compiled_dep.py"
echo 'import sys; sys.exit(7)' > "$work/exit7.py"

out=$(TAIPAN_CACHE="$work/build-cache" "$BIN" build "$work/hello.py" -o "$work/hello-built" 2>&1)
check build-hello 0 $? "$out" "built"
out=$(TAIPAN_CACHE="$work/build-cache" "$BIN" build "$work/compiled_dep.py" -o "$work/compiled-built" 2>&1)
check build-compiled-dep 0 $? "$out" "built"
out=$(TAIPAN_CACHE="$work/build-cache" "$BIN" build "$work/exit7.py" -o "$work/exit7-built" 2>&1)
check build-exit-code 0 $? "$out" "built"

rm -f "$work/hello.py" "$work/compiled_dep.py" "$work/exit7.py"
out=$(cd /tmp && TAIPAN_CACHE="$work/run-cache" TAIPAN_UV="$work/missing-uv" \
  "$work/hello-built" docker-arg 2>&1)
check built-hello 0 $? "$out" "docker-arg"
out=$(cd /tmp && TAIPAN_CACHE="$work/run-cache" TAIPAN_UV="$work/missing-uv" \
  "$work/compiled-built" 2>&1)
check built-compiled-dep 0 $? "$out" "WITH C extension"
TAIPAN_CACHE="$work/run-cache" TAIPAN_UV="$work/missing-uv" \
  "$work/exit7-built" >/dev/null 2>&1
check built-exit-code 7 $? ""

[ "$fail" = 0 ] && echo "SMOKE OK" || { echo "SMOKE FAILED"; exit 1; }

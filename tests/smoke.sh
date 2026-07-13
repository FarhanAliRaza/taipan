#!/bin/bash
# Smoke-test a built taipan binary end-to-end, ideally in a python-less container.
# Usage: smoke.sh <taipan-binary> <examples-dir>
set -u

BIN="${1:?usage: smoke.sh <taipan-binary> <examples-dir>}"
EXAMPLES="${2:?usage: smoke.sh <taipan-binary> <examples-dir>}"
fail=0

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

[ "$fail" = 0 ] && echo "SMOKE OK" || { echo "SMOKE FAILED"; exit 1; }

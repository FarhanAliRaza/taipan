#!/usr/bin/env bash
# Integration tests for the taipan binary. Expects a built ./zig-out/bin/taipan
# (override with $TAIPAN). Uses an isolated TAIPAN_CACHE; needs network on first
# dep-install (and for the uv bootstrap test if uv is not on PATH).
set -u
cd "$(dirname "$0")/.."

TAIPAN="${TAIPAN:-./zig-out/bin/taipan}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TAIPAN_CACHE="$WORK/cache"

pass=0
fail=0

check() { # name condition-exit-code
    local name="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        echo "ok       $name"
        pass=$((pass + 1))
    else
        echo "FAIL     $name"
        fail=$((fail + 1))
    fi
}

# --- basics -----------------------------------------------------------------
out="$("$TAIPAN" examples/hello.py a b 2>&1)"
echo "$out" | grep -q "hello from taipan on 3.13.14" && \
    echo "$out" | grep -qF "argv: ['examples/hello.py', 'a', 'b']"
check "hello: output and sys.argv" $?

"$TAIPAN" run examples/hello.py >/dev/null 2>&1
check "run subcommand accepted" $?

# --- runtime extraction -----------------------------------------------------
test -f "$TAIPAN_CACHE"/runtime/*/stdlib.zip && \
    test -f "$TAIPAN_CACHE"/runtime/*/libpython3.13.so.1.0 && \
    test -f "$TAIPAN_CACHE"/runtime/*/.taipan-ok
check "runtime extracted into TAIPAN_CACHE" $?

# --- exit codes ---------------------------------------------------------------
echo 'import sys; sys.exit(3)' > "$WORK/exit3.py"
"$TAIPAN" "$WORK/exit3.py"; [ $? -eq 3 ]
check "sys.exit(3) propagates" $?

echo 'raise RuntimeError("boom")' > "$WORK/raise.py"
"$TAIPAN" "$WORK/raise.py" 2>/dev/null; [ $? -eq 1 ]
check "uncaught exception exits 1" $?

"$TAIPAN" examples/hello.py >/dev/null 2>&1; [ $? -eq 0 ]
check "success exits 0" $?

"$TAIPAN" "$WORK/does-not-exist.py" 2>/dev/null; [ $? -ne 0 ]
check "missing script exits nonzero" $?

# --- stdlib from the embedded zip --------------------------------------------
cat > "$WORK/stdlib.py" <<'EOF'
import json, sqlite3, hashlib, decimal, ssl, asyncio, dataclasses
db = sqlite3.connect(":memory:")
db.execute("create table t(x)")
assert json.loads('{"a": 1}')["a"] == 1
assert hashlib.sha256(b"taipan").hexdigest().startswith("7914fca2")
ssl.create_default_context()
print("stdlib-ok")
EOF
"$TAIPAN" "$WORK/stdlib.py" 2>&1 | grep -q "stdlib-ok"
check "heavy stdlib imports from zipped stdlib" $?

# --- PEP 723 dependencies -----------------------------------------------------
cold="$("$TAIPAN" run examples/pure_dep.py 2>&1)"
echo "$cold" | grep -q "installing 1 dependencies" && \
    echo "$cold" | grep -q "taipan works with pure-python deps"
check "PEP 723 cold: installs and runs" $?

warm="$("$TAIPAN" run examples/pure_dep.py 2>&1)"
echo "$warm" | grep -q "taipan works with pure-python deps" && \
    ! echo "$warm" | grep -q "installing"
check "PEP 723 warm: cache hit, no uv" $?

env_dir=$(ls -d "$TAIPAN_CACHE"/envs/*/ | head -1)
find "$env_dir" -name '*.pyc' | grep -q .
check "dep env bytecode precompiled" $?

"$TAIPAN" run examples/compiled_dep.py 2>&1 | grep -q "WITH C extension"
check "compiled extension wheel loads" $?

# --- isolation: no python3/uv on PATH ------------------------------------------
ISO="$WORK/iso"
mkdir -p "$ISO/bin" "$ISO/home"
for t in sh curl tar gzip; do
    p="$(command -v $t)" && ln -s "$p" "$ISO/bin/$t"
done
cp "$TAIPAN" "$ISO/taipan"
env -i HOME="$ISO/home" PATH="$ISO/bin" "$ISO/taipan" examples/hello.py 2>&1 \
    | grep -q "hello from taipan"
check "runs dep-free with no python/uv on PATH (env -i)" $?

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

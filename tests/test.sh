#!/usr/bin/env bash
# Integration tests for the taipan binary. Expects a built ./zig-out/bin/taipan
# (override with $TAIPAN). Uses an isolated TAIPAN_CACHE; needs network on first
# dep-install (and for the uv bootstrap test if uv is not on PATH).
set -u
cd "$(dirname "$0")/.."

WIN=""
case "$(uname -s)" in MINGW* | MSYS*) WIN=1 ;; esac

TAIPAN="${TAIPAN:-./zig-out/bin/taipan${WIN:+.exe}}"
WORK="$(mktemp -d)"
# Env vars aren't path-converted by msys, so hand taipan a real Windows path.
[ -n "$WIN" ] && WORK="$(cygpath -m "$WORK")"
trap 'rm -rf "$WORK"' EXIT
export TAIPAN_CACHE="$WORK/cache"

pass=0
fail=0

check() { # name condition-exit-code [output-to-show-on-failure]
    local name="$1" rc="$2" out="${3:-}"
    if [ "$rc" -eq 0 ]; then
        echo "ok       $name"
        pass=$((pass + 1))
    else
        echo "FAIL     $name"
        [ -n "$out" ] && printf '  output was:\n%s\n' "$out" | sed 's/^/  | /'
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
    ls "$TAIPAN_CACHE"/runtime/*/ | grep -qE 'libpython3\.13|python313\.dll' && \
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

# --- compiled-script cache ----------------------------------------------------
echo 'print("cached-run")' > "$WORK/cached.py"
"$TAIPAN" "$WORK/cached.py" >/dev/null 2>&1 && \
    find "$TAIPAN_CACHE/scripts" -name '*.pyc' | grep -q .
check "script bytecode cached under scripts/" $?

out="$("$TAIPAN" "$WORK/cached.py" 2>&1)"
[ "$out" = "cached-run" ]
check "warm run served from script cache" $? "$out"

echo 'print("cached-edited")' > "$WORK/cached.py"
out="$("$TAIPAN" "$WORK/cached.py" 2>&1)"
[ "$out" = "cached-edited" ]
check "edited script recompiled (content-hash key)" $? "$out"

printf 'x = 1\nraise RuntimeError("boom")\n' > "$WORK/tb.py"
"$TAIPAN" "$WORK/tb.py" 2>/dev/null                # cold: populate the cache
out="$("$TAIPAN" "$WORK/tb.py" 2>&1)"              # warm: from cached bytecode
echo "$out" | grep -q 'line 2' && echo "$out" | grep -qF 'raise RuntimeError("boom")'
check "warm traceback keeps file/line and source text" $? "$out"

printf '\xef\xbb\xbfprint("bom-ok")\n' > "$WORK/bom.py"
"$TAIPAN" "$WORK/bom.py" 2>&1 | grep -q "bom-ok"
check "script with UTF-8 BOM runs" $?

# --- frozen startup modules -----------------------------------------------------
cat > "$WORK/frozen.py" <<'EOF'
import sys
encs = {n: m.__spec__.origin for n, m in sys.modules.items()
        if n.startswith("encodings")}
if encs and all(o == "frozen" for o in encs.values()):
    print("frozen-ok")
"cp850 codec loads from the zip:".encode("cp850")
import encodings.idna
print("zip-codecs-ok")
EOF
out="$("$TAIPAN" "$WORK/frozen.py" 2>&1)"
echo "$out" | grep -q "frozen-ok" && echo "$out" | grep -q "zip-codecs-ok"
check "startup encodings frozen; other codecs from zip" $? "$out"

# --- PEP 723 dependencies -----------------------------------------------------
cold="$("$TAIPAN" run examples/pure_dep.py 2>&1)"
echo "$cold" | grep -q "installing 1 dependencies" && \
    echo "$cold" | grep -q "taipan works with pure-python deps"
check "PEP 723 cold: installs and runs" $? "$cold"

warm="$("$TAIPAN" run examples/pure_dep.py 2>&1)"
echo "$warm" | grep -q "taipan works with pure-python deps" && \
    ! echo "$warm" | grep -q "installing"
check "PEP 723 warm: cache hit, no uv" $? "$warm"

env_dir=$(ls -d "$TAIPAN_CACHE"/envs/*/ | head -1)
find "$env_dir" -name '*.pyc' | grep -q .
check "dep env bytecode precompiled" $?

compiled="$("$TAIPAN" run examples/compiled_dep.py 2>&1)"
echo "$compiled" | grep -q "WITH C extension"
check "compiled extension wheel loads" $? "$compiled"

# --- standalone builds -------------------------------------------------------
"$TAIPAN" build examples/hello.py -o "$WORK/hello-built" >/dev/null 2>&1 && \
    test -x "$WORK/hello-built"
check "build creates an executable" $?

mkdir "$WORK/shipped"
mv "$WORK/hello-built" "$WORK/shipped/hello"
out="$(cd "$WORK/shipped" && TAIPAN_CACHE="$WORK/bundle-cache" ./hello x 2>&1)"
echo "$out" | grep -q "hello from taipan" && echo "$out" | grep -q "'x'"
check "built executable runs without its source" $? "$out"

"$TAIPAN" build examples/pure_dep.py -o "$WORK/shipped/pure-dep" >/dev/null 2>&1
out="$(cd "$WORK/shipped" && \
    TAIPAN_CACHE="$WORK/bundle-dep-cache" TAIPAN_UV=/definitely/missing ./pure-dep 2>&1)"
echo "$out" | grep -q "taipan works with pure-python deps" && \
    test -f "$WORK"/bundle-dep-cache/bundles/*/.taipan-ok
check "built executable carries PEP 723 dependencies" $? "$out"

"$TAIPAN" build examples/compiled_dep.py -o "$WORK/shipped/compiled-dep" >/dev/null 2>&1
out="$(cd "$WORK/shipped" && \
    TAIPAN_CACHE="$WORK/bundle-ext-cache" TAIPAN_UV=/definitely/missing ./compiled-dep 2>&1)"
echo "$out" | grep -q "WITH C extension"
check "built executable carries a compiled extension" $? "$out"

# Two builds of the same script must be byte-identical: the deps archive is
# the bundle cache key on target machines.
"$TAIPAN" build examples/pure_dep.py -o "$WORK/pure-dep-again" >/dev/null 2>&1 && \
    cmp -s "$WORK/shipped/pure-dep" "$WORK/pure-dep-again"
check "rebuilds are byte-identical" $?

out="$("$TAIPAN" build examples/hello.py -o 2>&1)"
[ $? -ne 0 ] && echo "$out" | grep -q "missing value for -o"
check "build -o without a value is rejected" $? "$out"

"$TAIPAN" build examples/hello.py -o "$WORK/corrupt" >/dev/null 2>&1
size=$(wc -c < "$WORK/corrupt")
# Flip a byte in a footer length field: the magic still matches, the recorded
# sizes no longer add up to the file size.
printf '\377' | dd of="$WORK/corrupt" bs=1 seek=$((size - 20)) conv=notrunc 2>/dev/null
out="$("$WORK/corrupt" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "corrupt"
check "corrupt built executable fails with a clear error" $? "$out"

mkdir -p "$WORK/local-project/pkg"
cat > "$WORK/local-project/app.py" <<'EOF'
import helper
from pathlib import Path
from pkg.answer import answer
print(helper.message(), answer, Path(__file__).with_name("message.txt").read_text().strip())
EOF
echo 'def message(): return "local-module-ok"' > "$WORK/local-project/helper.py"
echo 'from .answer import answer' > "$WORK/local-project/pkg/__init__.py"
echo 'answer = 42' > "$WORK/local-project/pkg/answer.py"
echo 'included-resource-ok' > "$WORK/local-project/message.txt"
"$TAIPAN" build "$WORK/local-project/app.py" --include-local \
    --include "$WORK/local-project/message.txt" -o "$WORK/shipped/local-app" >/dev/null 2>&1
rm -rf "$WORK/local-project"
out="$(TAIPAN_CACHE="$WORK/bundle-local-cache" "$WORK/shipped/local-app" 2>&1)"
[ "$out" = "local-module-ok 42 included-resource-ok" ]
check "build includes local modules, packages, and explicit resources" $? "$out"

# --- threads and multiprocessing --------------------------------------------
cat > "$WORK/concurrency.py" <<'EOF'
import concurrent.futures
import multiprocessing as mp
import sys

def square(x):
    return x * x

if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        assert list(pool.map(square, range(4))) == [0, 1, 4, 9]
    with mp.get_context("spawn").Pool(2) as pool:
        assert pool.map(square, range(4)) == [0, 1, 4, 9]
    assert sys.executable
    print("concurrency-ok")
EOF
out="$("$TAIPAN" run "$WORK/concurrency.py" 2>&1)"
echo "$out" | grep -q "concurrency-ok"
check "run supports threads and spawned processes" $? "$out"

"$TAIPAN" build "$WORK/concurrency.py" -o "$WORK/shipped/concurrency" >/dev/null 2>&1
rm "$WORK/concurrency.py"
out="$(TAIPAN_CACHE="$WORK/bundle-concurrency-cache" \
    "$WORK/shipped/concurrency" 2>&1)"
echo "$out" | grep -q "concurrency-ok"
check "built executable supports spawned processes" $? "$out"

# --- worker protocol gating ---------------------------------------------------
# TAIPAN_CHILD is inherited by every descendant of a taipan runtime; a `-c`
# after a subcommand or script path must reach the script, not be executed
# as the multiprocessing worker protocol.
cat > "$WORK/argv_echo.py" <<'EOF'
import sys
print("argv:", sys.argv[1:])
EOF
out="$(TAIPAN_CHILD=1 "$TAIPAN" run "$WORK/argv_echo.py" -c "print('hijacked')" 2>&1)"
echo "$out" | grep -qF "argv: ['-c'"
check "nested -c stays a script argument" $? "$out"

# --- duplicate bundle paths ----------------------------------------------------
mkdir "$WORK/collide"
printf 'import dup\nprint("dup:", dup.VALUE)\n' > "$WORK/collide/app.py"
echo 'VALUE = "ok"' > "$WORK/collide/dup.py"
out="$("$TAIPAN" build "$WORK/collide/app.py" --include-local \
    --include "$WORK/collide/dup.py" -o "$WORK/collide-built" 2>&1)"
echo "$out" | grep -q "bundled more than once"
check "duplicate bundle path warns at build time" $? "$out"

# --- isolation: no python3/uv on PATH ------------------------------------------
# POSIX-only: on Windows the msys tools can't be meaningfully symlinked into a
# bare PATH (they need their own DLLs), and env -i breaks Win32 API basics.
if [ -z "$WIN" ]; then
    ISO="$WORK/iso"
    mkdir -p "$ISO/bin" "$ISO/home"
    for t in sh curl tar gzip; do
        p="$(command -v $t)" && ln -s "$p" "$ISO/bin/$t"
    done
    cp "$TAIPAN" "$ISO/taipan"
    env -i HOME="$ISO/home" PATH="$ISO/bin" "$ISO/taipan" examples/hello.py 2>&1 \
        | grep -q "hello from taipan"
    check "runs dep-free with no python/uv on PATH (env -i)" $?
else
    echo "skip     isolation test (POSIX-only)"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

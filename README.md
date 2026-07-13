# taipan

`taipan` is a **single self-contained binary** (~25MB, written in
[Zig](https://ziglang.org)) that runs Python 3.13 scripts — including
[PEP 723](https://peps.python.org/pep-0723/) single-file scripts with inline
dependency blocks — on a machine with **no Python installed at all**. Its only
system dependency is glibc (`ldd` shows `libc` and the loader, nothing else).

Think Bun, for Python scripts: copy one file anywhere, `taipan main.py`, done.
For scripts that declare dependencies, taipan transparently provisions them into
a content-addressed cache with [uv](https://github.com/astral-sh/uv) —
downloading a uv binary by itself if the machine doesn't have one — then runs
with the cache on `sys.path`. No project, no virtualenv, no lockfile step.

```sh
taipan run script.py [args...]
# `run` is optional:
taipan script.py [args...]
```

Warm startup is ~9ms for a dependency-free script and ~15ms with cached PEP
723 dependencies — 2-3x faster than `uv run` (see
[BENCHMARKS.md](./BENCHMARKS.md)).

## How it works

The binary embeds three blobs, extracted once to
`~/.cache/taipan/runtime/cpython-3.13.14/` on first run (atomic writes, ~27MB):

1. **`stdlib.zip`** — the Python standard library, bytecode-only, imported
   directly via `zipimport` (the same mechanism as Windows' embeddable
   distribution). Trimmed of test/, tkinter, idlelib etc.
2. **`libpython3.13.so.1.0`** — CPython itself, from
   [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
   stripped from 241MB to 20MB at build time.
3. **`libtaipan_shim.so`** — a small C shim owning all `Python.h` usage:
   isolated `PyConfig` (no env vars, no `site`, fully explicit `sys.path`),
   script execution as `__main__`.

At startup taipan `dlopen`s libpython with `RTLD_GLOBAL` — which is what lets
manylinux wheels' compiled extension modules (which deliberately do not link
libpython) resolve `Py*` symbols — then the shim, and calls its single entry
point. The Zig executable itself never links Python.

### The dependency cache

1. taipan scans the script for the PEP 723 `# /// script` block and extracts the
   quoted strings from `dependencies = [ ... ]` (deliberately not a full TOML
   parser).
2. Cache key: `sha256(runtime-tag + sorted deps)`, first 16 hex chars. Envs
   live at `~/.cache/taipan/envs/<key>/`; a `.taipan-ok` marker means cache hit and
   uv is never invoked.
3. On a miss, taipan finds uv (`$TAIPAN_UV`, then `PATH`, then
   `~/.cache/taipan/bin/uv`, downloading it there if absent) and runs
   `uv pip install --python-version 3.13 --python-platform
   x86_64-unknown-linux-gnu --target <env>` — note: works without any Python
   interpreter on the machine.
4. The fresh env is bytecode-precompiled once, in-process, so warm runs never
   pay source→bytecode cost.

Env vars: `TAIPAN_CACHE` overrides the cache root, `TAIPAN_UV` pins a uv binary.

## Build from scratch

Prerequisites fetched into `vendor/` (Linux x86_64):

```sh
# Zig 0.15.2
mkdir -p vendor/zig
curl -sSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
  | tar -xJ --strip-components=1 -C vendor/zig

# CPython 3.13 install_only build from python-build-standalone
mkdir -p vendor/cpython
curl -sSL <.../cpython-3.13.x+YYYYMMDD-x86_64-unknown-linux-gnu-install_only.tar.gz> \
  | tar -xz --strip-components=1 -C vendor/cpython

./vendor/zig/zig build          # ReleaseFast by default; binary in zig-out/bin/taipan
```

The build strips libpython, compiles the stdlib to a bytecode zip
(`tools/make_payload.sh`), builds the shim `.so`, and embeds all three into
the executable. Build-time-only requirements: `bash`, `rsync`, `strip`
(binutils), and the vendored python (for `compileall`).

## Current limitations

- **Linux x86_64 + glibc only.** No macOS/Windows/musl yet.
- **Zipped, bytecode-only stdlib.** Tracebacks show no source lines for
  stdlib frames; anything that expects stdlib modules as real files on disk
  may misbehave. `tkinter`, `idlelib`, `venv`, `ensurepip` are excluded.
- **`sys.executable` is taipan, not python** — `multiprocessing`'s default
  spawn method may not work; workloads forking python subprocesses need care.
- **Minimal TOML parsing** of the PEP 723 block; `requires-python` is not
  enforced.
- **No lockfiles.** Deps are whatever uv resolves at first install of a given
  dep set.
- **First run writes ~27MB** to `~/.cache/taipan` (one-time, atomic).

## Next steps

- Script bytecode cache (never parse the same script twice; warm start
  independent of script size).
- Frozen bootstrap modules to break the ~9ms floor.
- `taipan build app.py` — bundle a script + resolved deps into the binary for
  single-artifact app distribution.
- macOS arm64 via Zig cross-compilation.

See [BENCHMARKS.md](./BENCHMARKS.md) for measurements.

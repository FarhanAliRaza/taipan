# taipan

[![CI](https://github.com/FarhanAliRaza/taipan/actions/workflows/ci.yml/badge.svg)](https://github.com/FarhanAliRaza/taipan/actions/workflows/ci.yml)

Run Python scripts anywhere. No Python required.

taipan is a single ~31 MB executable with CPython 3.13 inside. It runs Python
files — including [PEP 723](https://peps.python.org/pep-0723/) scripts with
inline dependencies — on machines with nothing installed, and compiles
scripts into standalone executables.

## Highlights

- **No Python required** — the interpreter ships inside the binary.
- **Inline dependencies** — PEP 723 blocks are installed with
  [uv](https://github.com/astral-sh/uv) and cached; one install per
  dependency set, ever.
- **~10 ms warm starts** — [about 3× faster](./BENCHMARKS.md) than `uv run`.
- **Standalone executables** — `taipan build` bundles a script, or a whole
  package and its console script, into one file that runs offline.
- Supports Linux, macOS, and Windows.

## Installation

```sh
# On macOS and Linux.
curl -LsSf https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.sh | sh
```

```powershell
# On Windows.
irm https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.ps1 | iex
```

Or download a binary for your platform from the
[releases page](https://github.com/FarhanAliRaza/taipan/releases) (rename it
to `taipan`, and on Linux/macOS `chmod +x` it).

## Usage

Run a script (`taipan run script.py` is the explicit equivalent):

```sh
taipan script.py [args...]
```

`sys.argv`, `__file__`, exit codes, tracebacks, threads, and every
`multiprocessing` start method behave as they would under a regular CPython.

Declare dependencies inline with PEP 723:

```python
# /// script
# dependencies = ["httpx"]
# ///

import httpx

print(httpx.get("https://example.com").status_code)
```

```sh
taipan example.py  # installs httpx on the first run; cached after that
```

Every later run — of this script or any script with the same dependency
set — reuses the cached environment with no network and no uv invocation.
Installs are delegated to uv, found via `$TAIPAN_UV`, then `PATH`; if
neither exists, taipan downloads a static copy into its cache once (this
needs `curl` and `tar`). Scripts without dependencies never touch uv.

uv is pointed at the embedded interpreter, so it never downloads a Python of
its own — including for a dependency that publishes no wheel and has to be
compiled from source. That build uses the same CPython 3.13 that will run the
code, and needs a C compiler on the machine (`cc`, or MSVC on Windows).

### Standalone executables

Bundle a script, the interpreter, and its dependencies into one file:

```sh
taipan build app.py -o app
./app
```

The result runs on the same platform with no Python, uv, or network access.
The output name defaults to the script name without `.py` (`.exe` added on
Windows). Dependencies are resolved at build time, so the first build of a
dependency set needs network; rebuilds are byte-identical.

Add sibling modules with `--include-local` and data files with `--include`:

```sh
taipan build app.py --include-local --include templates/ --include settings.json
```

`--include-local` bundles the `.py` files beside the entry script, keeping
their relative layout so `import helper` and `from pkg import x` work; it
skips `.git`, virtualenvs, `__pycache__`, and similar noise. It bundles what
exists — it does not compute an import graph. `--include` paths (repeatable,
file or directory) keep their basename next to the script; read them with
`Path(__file__).with_name("settings.json")`. Duplicate paths warn at build
time, and the last copy wins.

### Building a package

`taipan build` also takes a project directory or any requirement uv
understands, instead of a script. The package is installed with its
dependencies, and the executable runs one of its console scripts:

```sh
taipan build ./omniload -e omniload -o omniload   # from a local project
taipan build 'omniload==0.7.0' -e omniload        # from a package registry
```

`-e` names the console script, the same name a `pip install` would put on
your `PATH`. It can be omitted when the package declares exactly one; when it
declares several, taipan lists them and asks. The name is resolved from the
installed `[console_scripts]` metadata — the same thing
`importlib.metadata.entry_points()` reads — so there is no second copy of the
dependency list to maintain. Only `console_scripts` are considered;
`gui_scripts` and other entry point groups are not.

For a package that declares no console script for what you want to run, `-e`
also accepts an import target directly:

```sh
taipan build ./omniload -e omniload.main:main
```

The output name defaults to the console script's name. Because a directory's
contents change between builds, a local project is reinstalled on every build
(uv's own cache keeps this cheap); a pinned requirement reuses taipan's
cached environment, so keep it pinned if you want a rebuild to fetch nothing.

## How it works

The binary embeds a stripped CPython 3.13 and a bytecode-compiled standard
library, extracted to a local cache on first use. Dependencies are installed
by uv into content-addressed environments and precompiled once. Script
bytecode is cached and startup modules are frozen into the runtime, so a warm
start does almost no work. Threads and every `multiprocessing` start method
are supported.

`taipan build` appends the entry script — generated, for a package build —
and its installed environment to a copy of the launcher, sealed with a digest
that serves as both integrity check and cache key. On the target, the first
launch verifies and extracts the payload; later launches read only the
64-byte footer. A truncated or modified executable fails with a clear error.

The cache lives at `~/.cache/taipan` (`%LOCALAPPDATA%\taipan` on Windows) and
is disposable — deleting it costs one re-extraction on the next run. Set
`TAIPAN_CACHE` to move it, or `TAIPAN_UV` to use a specific uv executable.

## Comparison with `uv run`

`uv run` covers similar ground: it runs PEP 723 scripts and can download an
interpreter on first use — and taipan itself uses uv for installs. If you
have uv and network access, it is a good way to run scripts. taipan differs
where that assumption breaks:

- The interpreter is inside the binary, so a single file copy works on
  air-gapped and locked-down machines.
- Warm starts skip environment revalidation: roughly 10 ms versus 30 ms per
  run.
- `taipan build` produces one executable that needs nothing on the target.
  uv has no equivalent.

taipan is not a project manager. For lockfiles, multiple Python versions, and
day-to-day work inside a project, use uv.

## Limitations

- Linux builds require glibc; musl (Alpine) is not supported yet.
- Dependency sets are not locked — the first resolution wins and is cached.
  Pin versions in the PEP 723 block (`"httpx==0.28.1"`) for reproducibility.
- A dependency with no wheel is compiled on the spot, against the build
  machine's system libraries. Wheels from PyPI target manylinux's floor, so
  they run anywhere taipan does; a locally compiled extension only runs on
  systems at least as new as the one that built it. This matters for
  `taipan build`, whose output is otherwise portable across machines.
- Standard-library tracebacks show file and line but not source text, and
  code that expects stdlib modules to exist as ordinary files may fail.
  `tkinter`, `idlelib`, `venv`, and `ensurepip` are not included.
- `sys.executable` points at the taipan launcher; it supports running scripts
  and CPython's multiprocessing worker protocol, not the full CPython CLI
  (no `-m`, no REPL).
- PEP 723 `requires-python` is parsed but not enforced.
- TLS uses the operating system's certificate store. If stdlib `ssl` cannot
  find certificates, set `SSL_CERT_FILE`; packages like httpx and requests
  bundle their own via certifi and are unaffected.

## Building from source

Builds are native — the bundled CPython must match the host platform
(Linux x86_64/arm64, macOS, Windows x86_64):

```sh
./tools/fetch_toolchain.sh
./vendor/zig/zig build
```

The executable lands in `zig-out/bin/taipan`. The toolchain script downloads
pinned, checksum-verified copies of Zig and CPython into `vendor/`.

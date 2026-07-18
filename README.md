# taipan

Run Python scripts anywhere, without installing Python.

`taipan` is a self-contained executable that ships with Python 3.13 and runs
regular Python files as well as [PEP 723](https://peps.python.org/pep-0723/)
scripts with inline dependencies. Copy it to a machine, point it at a script,
and it is ready to go—no project setup, virtual environment, or separate Python
installation required.

```sh
taipan script.py
```

Dependencies are installed with [uv](https://github.com/astral-sh/uv) and kept
in a content-addressed cache. Once a dependency set has been installed, later
runs go straight to the cached environment.

## Install

On Linux or macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.sh | sh
```

The script detects your platform, downloads the binary from the latest
release, and installs it to `~/.local/bin`. Set `TAIPAN_INSTALL_DIR` to
install somewhere else, or `TAIPAN_VERSION` (e.g. `v0.2.0`) to pin a specific
release.

On Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.ps1 | iex"
```

This installs `taipan.exe` to `%LOCALAPPDATA%\Programs\taipan` and adds that
directory to your user `PATH`. The same `TAIPAN_INSTALL_DIR` and
`TAIPAN_VERSION` variables apply.

### Manual download

Grab the binary for your platform from the latest release:

| Platform | Download |
| --- | --- |
| Linux x86_64 | [taipan-linux-x86_64](https://github.com/FarhanAliRaza/taipan/releases/latest/download/taipan-linux-x86_64) |
| Linux ARM64 | [taipan-linux-aarch64](https://github.com/FarhanAliRaza/taipan/releases/latest/download/taipan-linux-aarch64) |
| macOS Apple Silicon | [taipan-macos-aarch64](https://github.com/FarhanAliRaza/taipan/releases/latest/download/taipan-macos-aarch64) |
| macOS Intel | [taipan-macos-x86_64](https://github.com/FarhanAliRaza/taipan/releases/latest/download/taipan-macos-x86_64) |
| Windows x86_64 | [taipan-windows-x86_64.exe](https://github.com/FarhanAliRaza/taipan/releases/latest/download/taipan-windows-x86_64.exe) |

Then rename it and make it executable:

```sh
mv taipan-<platform> taipan
chmod +x taipan
sudo mv taipan /usr/local/bin/
```

You can also browse [all releases](https://github.com/FarhanAliRaza/taipan/releases).

## Usage

Pass a script followed by any arguments intended for that script:

```sh
taipan script.py [args...]
```

The explicit `run` command works too:

```sh
taipan run script.py [args...]
```

For a script with inline dependencies:

```python
# /// script
# dependencies = [
#     "httpx",
# ]
# ///

import httpx

print(httpx.get("https://example.com").status_code)
```

Save it as `example.py` and run it normally:

```sh
taipan example.py
```

On the first run, taipan finds `uv` on your system or downloads a copy into its
cache, installs the declared packages, and precompiles them. Future runs reuse
that environment.

## How it works

The executable contains CPython, a bytecode-only standard library, and a small
native shim. On first use, these files are extracted atomically into the taipan
cache. The launcher then loads the bundled Python runtime and executes your
script as `__main__`.

For PEP 723 scripts, taipan reads the inline dependency block and derives a
cache key from the runtime and sorted dependency list. A cache hit starts the
script immediately. On a miss, taipan asks `uv` to install the packages into a
new isolated cache directory before running the script.

Compiled extension modules are supported. The bundled runtime is loaded in a
way that allows extension wheels to resolve Python symbols just as they would
with a conventional Python installation.

The cache lives at `~/.cache/taipan` by default. Set `TAIPAN_CACHE` to move it,
or `TAIPAN_UV` to use a specific `uv` executable.

## Performance

Warm startup is close to launching a bare Python interpreter and avoids the
repeated environment checks made by `uv run`. See [BENCHMARKS.md](./BENCHMARKS.md)
for the test setup, raw results, and caveats.

## Building from source

Builds are native because the bundled CPython runtime must match the host
platform. The toolchain script supports Linux on x86_64 and ARM64, plus macOS
on Apple Silicon and Intel.

```sh
./tools/fetch_toolchain.sh
./vendor/zig/zig build
```

The resulting executable is written to `zig-out/bin/taipan`. Building requires
`bash` and `rsync`; Linux builds also require `strip` from binutils. Zig and the
matching standalone Python runtime are downloaded into `vendor/` by the
toolchain script.

## Roadmap

- Cache compiled scripts so warm startup does not depend on script size.
- Freeze bootstrap modules to reduce startup time further.
- Add `taipan build` for bundling a script and its dependencies into one file.
- Add Windows ARM64 support.

## Limitations

- Linux builds require glibc; musl-based distributions such as Alpine are not
  supported yet.
- The standard library is stored as bytecode without source. Tracebacks still
  identify standard-library files and line numbers, but cannot display their
  source lines. Code that expects those modules to exist as ordinary files may
  also fail. `tkinter`, `idlelib`, `venv`, and `ensurepip` are not included.
- `sys.executable` is not a conventional Python interpreter and may be empty.
  Python subprocesses and `multiprocessing` with the `spawn` start method may
  not work as expected.
- PEP 723 parsing intentionally supports only the dependency syntax taipan
  needs. `requires-python` is not currently enforced.
- Dependency sets are not locked. The first installation uses whatever
  versions `uv` resolves at that time, and that result is then cached.
- Downloading `uv` automatically requires `curl` and `tar`; extracting it may
  also require `gzip`. HTTPS requests rely on the operating system's CA
  certificate store.
- The first run extracts the bundled runtime into the local cache and therefore
  uses additional disk space.

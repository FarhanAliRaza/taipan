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
curl -LsSf https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.sh | sh
```

On Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/FarhanAliRaza/taipan/main/install.ps1 | iex
```

The installer detects the platform, downloads the current release as
`taipan` (`taipan.exe` on Windows), and makes it executable. It installs to
`~/.local/bin` by default; set `TAIPAN_INSTALL_DIR` to choose another location.

To download a binary manually instead, use the platform-specific artifact from
the current release:

| Platform | Download |
| --- | --- |
| Linux x86_64 | [taipan-linux-x86_64](https://github.com/FarhanAliRaza/taipan/releases/download/v0.2.0/taipan-linux-x86_64) |
| Linux ARM64 | [taipan-linux-aarch64](https://github.com/FarhanAliRaza/taipan/releases/download/v0.2.0/taipan-linux-aarch64) |
| macOS Apple Silicon | [taipan-macos-aarch64](https://github.com/FarhanAliRaza/taipan/releases/download/v0.2.0/taipan-macos-aarch64) |
| macOS Intel | [taipan-macos-x86_64](https://github.com/FarhanAliRaza/taipan/releases/download/v0.2.0/taipan-macos-x86_64) |
| Windows x86_64 | [taipan-windows-x86_64.exe](https://github.com/FarhanAliRaza/taipan/releases/download/v0.2.0/taipan-windows-x86_64.exe) |

Direct binary downloads do not preserve executable permissions. On Linux or
macOS, make a manual download executable and give it a stable name:

```sh
mv taipan-<platform> taipan
chmod +x taipan
sudo mv taipan /usr/local/bin/
```

On Windows, rename a manual download to `taipan.exe` and place it somewhere on
your `PATH`.

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

### Build a standalone executable

Bundle a script, CPython, and its PEP 723 dependencies into one executable:

```sh
taipan build app.py -o app
./app [args...]
```

Include sibling modules and local packages rooted beside the entry script with
`--include-local`. Add resources or dynamically loaded files explicitly with a
repeatable `--include`:

```sh
taipan build app.py -o app --include-local \
  --include templates/ --include settings.json
```

`--include-local` recursively includes `.py` files while skipping common
environment, cache, VCS, and build directories. Explicitly included files and
directories keep their basename at the application bundle root.

The output name defaults to the script name without `.py` (with `.exe` added
on Windows). The built file can be copied to another machine of the same
platform and run without the source script, Python, uv, or network access.
Dependencies are resolved while building, so the build machine does need
network access on the first build of a dependency set.

Builds are platform-specific. Build on each operating system and CPU
architecture you intend to distribute to; packages containing native extension
modules must match that target as well.

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

The script itself is compiled only once: the resulting bytecode is cached,
keyed by the runtime, the script path, and a hash of its content, so warm
startup does not depend on script size. Editing or moving the script changes
the key and triggers a fresh compile. The modules Python touches on every
startup are frozen directly into the runtime, so a warm start of a
dependency-free script never has to read the bundled standard library at all.

Compiled extension modules are supported. The bundled runtime is loaded in a
way that allows extension wheels to resolve Python symbols just as they would
with a conventional Python installation.

Threads and all platform start methods from `multiprocessing` are supported.
Spawned workers re-enter the embedded interpreter through `sys.executable` and
inherit the script's dependency environment.

`taipan build` appends the script and its installed dependency environment to
a copy of the launcher. On first launch, the executable extracts its runtime
and dependencies into a content-addressed cache, then runs the embedded script
directly. Later launches reuse those files. The shipped artifact itself remains
a single file.

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

- Add Windows ARM64 support.

## Limitations

- Linux builds require glibc; musl-based distributions such as Alpine are not
  supported yet.
- The standard library is stored as bytecode without source. Tracebacks still
  identify standard-library files and line numbers, but cannot display their
  source lines. Code that expects those modules to exist as ordinary files may
  also fail. `tkinter`, `idlelib`, `venv`, and `ensurepip` are not included.
- `sys.executable` points to the taipan launcher. Invoking it with a script or
  with Python's internal `-c` worker protocol is supported, but it is not a
  complete replacement for every CPython command-line option.
- PEP 723 parsing intentionally supports only the dependency syntax taipan
  needs. `requires-python` is not currently enforced.
- Dependency sets are not locked. The first installation uses whatever
  versions `uv` resolves at that time, and that result is then cached.
- Downloading `uv` automatically requires `curl` and `tar`; extracting it may
  also require `gzip`. HTTPS requests rely on the operating system's CA
  certificate store.
- The first run extracts the bundled runtime into the local cache and therefore
  uses additional disk space.
- Standalone builds package one script rather than an entire
  `pyproject.toml` project. Use `--include-local` and `--include` for local
  modules and application resources.

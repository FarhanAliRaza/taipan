# taipan benchmarks

Startup / total-overhead benchmarks for the `taipan` prototype: a small Zig
launcher that embeds CPython 3.13 and runs PEP 723 scripts. All numbers are
**warm** (caches, venvs and dependency envs pre-populated; `hyperfine
--warmup 3`). Reproduce with [`./bench.sh`](./bench.sh).

## Machine

| | |
|---|---|
| CPU | AMD Ryzen 5 5600 6-Core Processor |
| Kernel | Linux 7.0.0-27-generic (#27-Ubuntu SMP PREEMPT_DYNAMIC), x86_64 |
| taipan interpreter | vendored CPython 3.13.14 (dynamic link to `libpython3.13.so`) |
| System python | /usr/bin/python3 — CPython 3.14.4 |
| uv | 0.11.23 |
| hyperfine | 1.19.0 (vendored static musl build under `vendor/bin/`) |

## Results

Measured with `hyperfine --warmup 3 --shell=none`:

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `taipan hello (no deps)` | 9.5 ± 0.6 | 8.4 | 13.3 | 1.02 ± 0.09 |
| `system python3 hello` | 10.2 ± 0.6 | 8.9 | 12.3 | 1.09 ± 0.09 |
| `vendored python3 hello` | 9.3 ± 0.5 | 8.1 | 10.8 | 1.00 |
| `uv run hello (no deps)` | 29.1 ± 3.7 | 23.5 | 38.4 | 3.11 ± 0.43 |
| `taipan pure_dep (cached cowsay)` | 19.0 ± 3.8 | 15.4 | 47.7 | 2.04 ± 0.42 |
| `uv run pure_dep (cached)` | 33.1 ± 3.0 | 26.8 | 41.5 | 3.55 ± 0.38 |

Full hyperfine output:

```
Benchmark 1: taipan hello (no deps)
  Time (mean ± σ):       9.5 ms ±   0.6 ms    [User: 6.1 ms, System: 3.3 ms]
  Range (min … max):     8.4 ms …  13.3 ms    290 runs

Benchmark 2: system python3 hello
  Time (mean ± σ):      10.2 ms ±   0.6 ms    [User: 7.1 ms, System: 3.0 ms]
  Range (min … max):     8.9 ms …  12.3 ms    288 runs

Benchmark 3: vendored python3 hello
  Time (mean ± σ):       9.3 ms ±   0.5 ms    [User: 6.5 ms, System: 2.7 ms]
  Range (min … max):     8.1 ms …  10.8 ms    277 runs

Benchmark 4: uv run hello (no deps)
  Time (mean ± σ):      29.1 ms ±   3.7 ms    [User: 9.3 ms, System: 9.9 ms]
  Range (min … max):    23.5 ms …  38.4 ms    104 runs

Benchmark 5: taipan pure_dep (cached cowsay)
  Time (mean ± σ):      19.0 ms ±   3.8 ms    [User: 13.7 ms, System: 4.7 ms]
  Range (min … max):    15.4 ms …  47.7 ms    190 runs

Benchmark 6: uv run pure_dep (cached)
  Time (mean ± σ):      33.1 ms ±   3.0 ms    [User: 14.7 ms, System: 10.4 ms]
  Range (min … max):    26.8 ms …  41.5 ms    92 runs

Summary
  vendored python3 hello ran
    1.02 ± 0.09 times faster than taipan hello (no deps)
    1.09 ± 0.09 times faster than system python3 hello
    2.04 ± 0.42 times faster than taipan pure_dep (cached cowsay)
    3.11 ± 0.43 times faster than uv run hello (no deps)
    3.55 ± 0.38 times faster than uv run pure_dep (cached)
```

## Summary

The honest headline is that **taipan's win is entirely against `uv run`, not
against a bare interpreter.** On the dependency-free `hello.py`, taipan (9.5 ms)
is statistically tied with the same vendored CPython it embeds (9.3 ms) and a
hair quicker than the system `python3` (10.2 ms). taipan runs with
`site_import=0`, and skipping `site` really is worth about 2 ms on this
interpreter (a bare `python3 -S` clocks ~7.2 ms vs ~9.3 ms with site). But
taipan's own launcher cost — process spawn, reading the whole script into Zig,
the PEP 723 scan, and the extra indirection of a dynamically linked
`libpython` — eats that saving back, so the net startup is a wash versus
`python3`. Where taipan clearly wins is against `uv run`: **~3.1x faster on a
dep-free script** (9.5 ms vs 29.1 ms) and **~1.95x faster on a script with a
cached dependency** (19.0 ms vs 33.1 ms). `uv run` re-resolves/re-validates
its environment and does more filesystem work on every invocation, whereas
taipan's content-addressed cache lets it go straight to the interpreter once the
env exists — that fixed ~20 ms of per-run overhead is the real difference for
short-lived PEP 723 scripts.

### Caveats

- **Dynamic libpython.** taipan links `libpython3.13.so` via rpath rather than
  statically, so it pays runtime symbol resolution on startup and the binary
  is not relocatable (see README limitations). A static link would likely
  close the small gap versus `python3 -S`.
- **No stdlib freezing yet.** The standard library is loaded from `.py`/`.pyc`
  files on disk, not frozen into the binary, so taipan enjoys none of the import
  savings a frozen stdlib would give.
- **~~No `.pyc` for cached deps~~ — fixed.** This benchmark run exposed that
  taipan's `write_bytecode=0` plus `uv pip install --target` (which ships no
  bytecode) meant dependency modules were compiled from source on *every*
  run — ~6-7 ms warm, ~36 ms on a cold OS cache, and the cause of the wide
  spread in the `pure_dep` row above (max 47.7 ms). taipan now runs
  `python -m compileall` on the env once at install time. Re-measured after
  the fix: **`taipan pure_dep` = 15.3 ± 0.8 ms (range 14.0–17.8 ms)** — down
  from 19.0 ± 3.8 ms, with the outliers gone, widening the lead over
  `uv run pure_dep` (33.1 ms) to ~2.2x. The table above predates the fix.
- **Startup, not throughput.** These are launch-overhead microbenchmarks;
  they say nothing about long-running compute, for which all four
  interpreters are the same CPython-class runtime.

## Self-contained milestone

Independent adversarial verification (2026-07-13) of the "runs Python with
zero system dependencies beyond glibc" claim. Same machine as above (AMD Ryzen
5 5600, Linux 7.0.0-27-generic, x86_64).

### Group C numbers

| Metric | This run | Prior milestone | Delta |
|:---|---:|---:|---:|
| `taipan hello` (warm, no deps) | 10.2–10.6 ms | 9.5 ms | +0.7–1.1 ms |
| `taipan run pure_dep` (warm, cached cowsay) | 19.2–19.5 ms | 15.3 ms | +3.9–4.2 ms ⚠ |
| Cold-start (`hello`, fresh `PYX_CACHE`) | ~27 ms (26–28 ms) | expected 50–150 ms | faster |
| Extracted runtime size | 24 MB | — | — |
| Binary size | 25,244,528 bytes (24.1 MiB) | — | — |
| `ldd` | glibc only (`libc.so.6`, `ld-linux`, vdso) | — | — |

- **Regression flag:** warm `taipan run pure_dep` measured 19.2–19.5 ms across
  repeated `hyperfine --warmup 5` runs (σ ≈ 0.7 ms), i.e. ~+3.9 ms over the
  stated post-`compileall` figure of 15.3 ms — above the 2 ms flag threshold.
  Dependency `.pyc` files were confirmed present in the cached env, so this is
  not the pre-fix "compile on every run" cause resurfacing.
- `taipan hello` (+0.7–1.1 ms) is within the 2 ms threshold — no flag.
- Cold-start of ~27 ms (extracting ~24 MB) is well under the 50–150 ms budget.

### Isolation test summary

Verified with a scrubbed `env -i HOME=… PATH=<only sh/curl/tar/gzip> taipan …`
and, independently, inside a bare `debian:bookworm-slim` container that has
**no `python3`** (confirmed via `which python3`), mounting only the binary.

- **Dep-free heavy stdlib** (json, sqlite3, decimal, hashlib, ssl,
  urllib.request): PASS. Runs on glibc alone. In a no-network bare container
  with only the binary mounted, stdlib scripts execute with zero system
  dependencies — the headline claim holds for Python execution itself.
- **HTTPS fetch** (`ssl.create_default_context()` + `urllib` to
  example.com): PASS on hosts with a system CA store; **FAILS** in a bare
  container that lacks one, with
  `[SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate`.
  The `_ssl` module (bundled OpenSSL 3.5.7) loads and completes the TLS
  handshake — only cert verification fails. Setting `SSL_CERT_FILE` to any
  real bundle restores a 200 response. **taipan bundles no CA certificates**; it
  relies on the system store.
- **PEP 723 deps (cowsay), cold:** PASS. One-time uv download into the
  scrubbed `$HOME` cache, install, run. **Caveat:** the uv bootstrap runs
  `curl … uv-….tar.gz | tar -xz`, so it needs a **`gzip`** binary on `PATH`
  in addition to `sh`, `curl`, `tar`; with only `sh`/`curl`/`tar` present the
  bootstrap fails (`tar: gzip: Cannot exec`). Minimal runtime dep set for the
  dep-install path is therefore sh + curl + tar + gzip (plus a CA store for
  the TLS download).
- **PEP 723 deps, warm:** PASS. No install/download line on the second run.
- **numpy** (compiled wheel, matmul): PASS. numpy 2.5.1, correct result.
- **Kitchen sink** (argparse, dataclasses, enum, typing, asyncio, subprocess,
  multiprocessing): PASS. `multiprocessing.Pool` works via the default
  **fork** start method. The **spawn** start method FAILS loudly
  (`BrokenPipeError`) because `sys.executable` is empty in the embedded
  interpreter — fails visibly, not silently.
- **Traceback quality:** PASS. The script's own frames show full source lines
  with 3.13-style caret markers; stdlib frames show file/line/function only
  (bytecode-only zip, no source).
- **Exit codes:** PASS. `sys.exit(3)` → 3, uncaught `raise` → 1, success → 0.

**Verdict.** The "runs Python with zero system dependencies beyond glibc"
claim **holds for Python execution itself** — dep-free stdlib scripts run in a
genuinely `python3`-free, no-network container with only the binary present.
Two honest qualifications: (1) outbound TLS needs a system CA store (none is
bundled); (2) installing PEP 723 deps requires `uv`, and bootstrapping it when
absent shells out to system `curl` + `tar` + `gzip`. Neither undermines the
core claim, but "beyond glibc" is precisely: glibc for running Python; plus a
CA store for HTTPS and curl/tar/gzip for the one-time uv bootstrap.

### Regression follow-up (same day)

The +3.9 ms flagged above was chased down: ~2 ms was deflate decompression of
stdlib modules on every import — the stdlib zip is now built with
`ZIP_STORED` (uncompressed; binary grows 25→31MB, the right trade for a
runner). Re-measured warm: `taipan hello` = 9.7 ± 0.6 ms, `taipan run pure_dep` =
**17.3 ± 1.1 ms** (was 19.2). The remaining ~2 ms versus the pre-zip 15.3 ms
figure is the intrinsic cost of importing through zipimport rather than a
directory tree — accepted for now; frozen bootstrap modules are the proper
fix and are on the roadmap.

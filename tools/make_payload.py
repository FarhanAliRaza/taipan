"""Build the embedded runtime payloads. Runs under the vendored python so it
works identically on Linux, macOS, and Windows (no rsync/bash needed).

Usage: make_payload.py <vendor-cpython-dir> <posix|windows> <out-stdlib.zip> <out-extra.tar>

stdlib.zip — the stdlib as bytecode-only zip, imported via zipimport.
extra.tar  — Windows only: the DLLs/ dir (stdlib .pyd extensions + their
             support DLLs), python3.dll (stable-ABI forwarder for abi3
             wheels), and the vcruntime DLLs. Empty archive on POSIX.
"""

import compileall
import fnmatch
import os
import shutil
import sys
import tarfile
import tempfile
import zipfile

# Not needed at script runtime (or unusable from a zip): trims ~60% of size.
STDLIB_EXCLUDES = [
    "test", "idlelib", "tkinter", "turtledemo", "ensurepip", "venv",
    "config-3.13*", "lib-dynload", "site-packages", "__pycache__", "turtle.py",
]

# Windows DLLs/ entries we drop: debug info, CPython self-test modules, tk.
DLLS_EXCLUDES = ["*.pdb", "_test*", "_ctypes_test*", "_tkinter*", "tcl86t.dll", "tk86t.dll"]

ROOT_DLLS = ["python3.dll", "vcruntime140.dll", "vcruntime140_1.dll"]


def excluded(name, patterns):
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def build_stdlib_zip(src, out):
    tmp = tempfile.mkdtemp()
    try:
        lib = os.path.join(tmp, "lib")
        shutil.copytree(
            src, lib,
            ignore=lambda _, names: [n for n in names if excluded(n, STDLIB_EXCLUDES)],
        )
        # legacy=True writes os.pyc next to os.py — the layout zipimport
        # expects at the zip root.
        if not compileall.compile_dir(lib, quiet=2, legacy=True, workers=0):
            sys.exit("make_payload: compileall failed")
        # ZIP_STORED: uncompressed. Deflate saved ~6MB of binary size but cost
        # ~4ms of per-import decompression on warm starts — wrong trade.
        with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as zf:
            for dp, _, fns in os.walk(lib):
                for fn in sorted(fns):
                    if fn.endswith(".py"):
                        continue
                    p = os.path.join(dp, fn)
                    zf.write(p, os.path.relpath(p, lib))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build_extra_tar(vendor, plat, out):
    with tarfile.open(out, "w") as tf:
        if plat != "windows":
            return
        for name in ROOT_DLLS:
            tf.add(os.path.join(vendor, name), arcname=name)
        dlls = os.path.join(vendor, "DLLs")
        for fn in sorted(os.listdir(dlls)):
            if excluded(fn, DLLS_EXCLUDES) or fn == ".empty":
                continue
            tf.add(os.path.join(dlls, fn), arcname=f"DLLs/{fn}")


def main():
    vendor, plat, out_zip, out_tar = sys.argv[1:5]
    src = os.path.join(vendor, "Lib") if plat == "windows" else \
        os.path.join(vendor, "lib", "python3.13")
    build_stdlib_zip(src, out_zip)
    build_extra_tar(vendor, plat, out_tar)
    print(f"payload: stdlib {os.path.getsize(out_zip) >> 20}MB, "
          f"extra {os.path.getsize(out_tar) >> 20}MB", file=sys.stderr)


if __name__ == "__main__":
    main()

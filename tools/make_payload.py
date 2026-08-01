"""Build the embedded runtime payloads. Runs under the vendored python so it
works identically on Linux, macOS, and Windows (no rsync/bash needed).

Usage: make_payload.py <vendor-cpython-dir> <posix|windows> <out-stdlib.zip> <out-extra.tar> <out-frozen.c> <out-include.tar.gz>

stdlib.zip     — the stdlib as bytecode-only zip, imported via zipimport.
extra.tar      — Windows only: the DLLs/ dir (stdlib .pyd extensions + their
                 support DLLs), python3.dll (stable-ABI forwarder for abi3
                 wheels), and the vcruntime DLLs. Empty archive on POSIX.
frozen.c       — startup modules frozen as marshalled code, compiled into the
                 shim so a warm start never opens stdlib.zip.
include.tar.gz — the CPython headers, so uv can build a source-only
                 dependency against the embedded interpreter instead of
                 downloading one. Unpacked lazily, only when that happens.
"""

import compileall
import fnmatch
import gzip
import marshal
import os
import shutil
import sys
import tarfile
import tempfile
import zipfile

# Not needed at script runtime (or unusable from a zip): trims ~60% of size.
STDLIB_EXCLUDES = [
    "test", "idlelib", "tkinter", "turtledemo", "ensurepip", "venv",
    "config-3.*", "lib-dynload", "site-packages", "__pycache__", "turtle.py",
]

# Windows DLLs/ entries we drop: debug info, CPython self-test modules, tk.
DLLS_EXCLUDES = ["*.pdb", "_test*", "_ctypes_test*", "_tkinter*", "tcl86t.dll", "tk86t.dll"]

ROOT_DLLS = ["python3.dll", "vcruntime140.dll", "vcruntime140_1.dll"]

# Modules imported on every interpreter startup that are NOT already frozen
# inside libpython (CPython freezes io, os, codecs, ... itself). Freezing
# these too means a warm start of a dependency-free script never opens
# stdlib.zip at all. ascii/latin_1 cover the fs/stdio codecs of non-UTF-8
# locales; anything more exotic falls back to the zip via __path__ below.
FREEZE_COMMON = [
    "encodings", "encodings.aliases", "encodings.utf_8",
    "encodings.ascii", "encodings.latin_1",
]
# Windows stdio can fall back to the ANSI/OEM code pages when redirected.
FREEZE_WINDOWS = ["encodings.cp1252", "encodings.cp437", "encodings.mbcs", "encodings.oem"]

# Frozen packages start with an empty __path__, which would break the
# dynamic `import encodings.<codec>` done at codec lookup — including the
# filesystem-encoding lookup during core init, before any embedder code can
# run. taipan guarantees sys.path[0] is the stdlib (zip or dir), so the
# frozen copy of a package repairs its own __path__ at exec time; codecs we
# did not freeze keep loading from there.
PKG_PROLOGUE = "import sys; __path__ = [sys.path[0] + '/{name}']\n"


# python-build-standalone compiles CPython inside a build container: its
# _sysconfigdata names a clang toolchain under /tools and an install prefix of
# /install, and neither exists on a user's machine. A PEP 517 build of a
# source-only dependency reads exactly these variables to find a compiler and
# Python.h, so left alone they make the embedded interpreter unusable for
# building — which is the whole reason uv would otherwise have to download an
# interpreter of its own. Rewrite the toolchain to the platform defaults
# (distutils still lets $CC win at build time) and resolve the prefix at
# import time from sys.base_prefix, which the shim points at the runtime dir.
TOOL_NAMES = {"clang": "cc", "clang++": "c++", "llvm-ar": "ar",
              "llvm-ranlib": "ranlib", "llvm-strip": "strip", "llvm-nm": "nm",
              "llvm-readelf": "readelf"}
TOOL_KEYS = ["CC", "CXX", "LDSHARED", "LDCXXSHARED", "BLDSHARED", "LINKCC",
             "AR", "RANLIB", "READELF", "STRIP", "NM"]


def excluded(name, patterns):
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def patch_sysconfigdata(lib):
    """Rewrite _sysconfigdata in-place. Windows has no such module."""
    for fn in sorted(os.listdir(lib)):
        if not (fn.startswith("_sysconfigdata_") and fn.endswith(".py")):
            continue
        path = os.path.join(lib, fn)
        ns = {}
        with open(path, encoding="utf-8") as f:
            exec(compile(f.read(), path, "exec"), ns)
        v = dict(ns["build_time_vars"])

        for key in TOOL_KEYS:
            val = v.get(key)
            if not isinstance(val, str):
                continue
            # Only the driver is toolchain-specific; the flags after it are
            # understood by gcc too. Both "clang -pthread ..." and an absolute
            # "/tools/llvm/bin/llvm-ar" reduce to their basename first, so a
            # pbs that starts spelling the compiler as a path still matches.
            head, sep, rest = val.partition(" ")
            name = TOOL_NAMES.get(os.path.basename(head))
            if name is not None:
                v[key] = name + sep + rest

        # Read the build prefix out of the data rather than assuming "/install":
        # if pbs ever changes it, this fails loudly here instead of shipping a
        # payload whose INCLUDEPY points nowhere.
        prefix = v.get("prefix")
        if not (isinstance(prefix, str) and prefix.startswith("/") and len(prefix) > 1):
            sys.exit(f"make_payload: {fn} has no usable build prefix: {prefix!r}")

        with open(path, "w", encoding="utf-8") as f:
            f.write(
                "# Rewritten by taipan's make_payload.py: the build-container\n"
                "# toolchain is replaced above, the build prefix below.\n"
                "import sys as _sys\n"
                f"build_time_vars = {v!r}\n"
                f"_prefix = _sys.base_prefix or {prefix!r}\n"
                "build_time_vars = {\n"
                f"    _k: (_v.replace({prefix!r}, _prefix) if isinstance(_v, str) else _v)\n"
                "    for _k, _v in build_time_vars.items()\n"
                "}\n"
                "del _sys, _prefix\n"
            )
        break


def python_dirname(parent):
    """The `python3.X` directory under `parent`, for whichever CPython is
    vendored — so a version bump touches only tools/fetch_toolchain.sh."""
    names = [n for n in os.listdir(parent) if fnmatch.fnmatch(n, "python3.*")]
    if len(names) != 1:
        sys.exit(f"expected one python3.* directory in {parent}, found {names}")
    return names[0]


def build_include_tar(vendor, plat, out):
    """The CPython headers, at the path sysconfig reports for this platform.

    Compressed (2.4MB of headers become ~370KB) because unlike stdlib.zip this
    is never on a startup path: it is unpacked only when a source-only
    dependency has to be compiled. Timestamps and ownership are zeroed, and
    the gzip member carries no mtime, so the payload — and the binary
    embedding it — stays byte-identical across rebuilds.
    """
    if plat == "windows":
        src, arcname = os.path.join(vendor, "include"), "Include"
    else:
        name = python_dirname(os.path.join(vendor, "include"))
        src, arcname = os.path.join(vendor, "include", name), f"include/{name}"

    def normalize(ti):
        ti.mtime = 0
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        return ti

    with open(out, "wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w") as tf:
                tf.add(src, arcname=arcname, filter=normalize)


def build_stdlib_zip(src, out):
    tmp = tempfile.mkdtemp()
    try:
        lib = os.path.join(tmp, "lib")
        shutil.copytree(
            src, lib,
            ignore=lambda _, names: [n for n in names if excluded(n, STDLIB_EXCLUDES)],
        )
        patch_sysconfigdata(lib)
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


def build_frozen_c(src, plat, out):
    names = FREEZE_COMMON + (FREEZE_WINDOWS if plat == "windows" else [])
    with open(out, "w") as f:
        f.write(
            "/* Generated by make_payload.py. Startup modules frozen as marshalled\n"
            " * code objects; registered via PyImport_FrozenModules in embed.c. */\n"
            "#include <Python.h>\n\n"
        )
        entries = []
        for name in names:
            rel = name.replace(".", os.sep)
            pkg_init = os.path.join(src, rel, "__init__.py")
            is_pkg = os.path.exists(pkg_init)
            path = pkg_init if is_pkg else os.path.join(src, rel + ".py")
            with open(path, encoding="utf-8") as fh:
                source = fh.read()
            if is_pkg:
                source = PKG_PROLOGUE.format(name=name) + source
            code = compile(source, f"<frozen {name}>", "exec")
            data = marshal.dumps(code)
            sym = "frz_" + name.replace(".", "_")
            f.write(f"static const unsigned char {sym}[] = {{\n")
            for i in range(0, len(data), 24):
                f.write("    " + ",".join(str(b) for b in data[i:i + 24]) + ",\n")
            f.write("};\n")
            entries.append((name, sym, len(data), is_pkg))
        f.write("\nconst struct _frozen taipan_frozen_modules[] = {\n")
        for name, sym, size, is_pkg in entries:
            f.write(f'    {{"{name}", {sym}, {size}, {int(is_pkg)}, 0}},\n')
        f.write("    {0, 0, 0, 0, 0},\n};\n")


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
    vendor, plat, out_zip, out_tar, out_frozen, out_include = sys.argv[1:7]
    src = os.path.join(vendor, "Lib") if plat == "windows" else \
        os.path.join(vendor, "lib", python_dirname(os.path.join(vendor, "lib")))
    build_stdlib_zip(src, out_zip)
    build_extra_tar(vendor, plat, out_tar)
    build_frozen_c(src, plat, out_frozen)
    build_include_tar(vendor, plat, out_include)
    print(f"payload: stdlib {os.path.getsize(out_zip) >> 20}MB, "
          f"extra {os.path.getsize(out_tar) >> 20}MB, "
          f"frozen {os.path.getsize(out_frozen) >> 10}KB, "
          f"include {os.path.getsize(out_include) >> 10}KB", file=sys.stderr)


if __name__ == "__main__":
    main()

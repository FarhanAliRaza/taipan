const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Builds are native-only: vendor/cpython (see tools/fetch_toolchain.sh)
    // matches the host, and the payload script runs the vendored python.
    // On Windows pass -Dtarget=x86_64-windows-gnu so the shim links with
    // Zig's bundled mingw instead of requiring MSVC.
    const t = target.result;
    const is_macos = t.os.tag == .macos;
    const is_windows = t.os.tag == .windows;
    const python_platform = b.fmt("{s}-{s}", .{
        @tagName(t.cpu.arch),
        if (is_macos) "apple-darwin" else if (is_windows) "pc-windows-msvc" else "unknown-linux-gnu",
    });
    const libpython_name: []const u8 =
        if (is_windows) "python313.dll" else if (is_macos) "libpython3.13.dylib" else "libpython3.13.so.1.0";
    const shim_name: []const u8 =
        if (is_windows) "taipan_shim.dll" else if (is_macos) "libtaipan_shim.dylib" else "libtaipan_shim.so";
    const py_exe = if (is_windows) "vendor/cpython/python.exe" else "vendor/cpython/bin/python3";

    // stdlib.zip (bytecode-only stdlib) + extra.tar (Windows .pyd extensions
    // and support DLLs; empty elsewhere) + frozen.c (startup modules frozen
    // into the shim). The script is passed via addFileArg so its content is
    // a tracked input.
    const payload = b.addSystemCommand(&.{b.pathFromRoot(py_exe)});
    payload.addFileArg(b.path("tools/make_payload.py"));
    payload.addArg(b.pathFromRoot("vendor/cpython"));
    payload.addArg(if (is_windows) "windows" else "posix");
    const stdlib_zip = payload.addOutputFileArg("stdlib.zip");
    const extra_tar = payload.addOutputFileArg("extra.tar");
    const frozen_c = payload.addOutputFileArg("taipan_frozen.c");

    // The C shim (all Python.h usage) as a shared library. It is embedded in
    // the exe, extracted to the runtime cache next to libpython, and loaded
    // at runtime — rpath $ORIGIN/@loader_path resolves libpython from the
    // same dir on POSIX; on Windows the loader finds python313.dll by name
    // because taipan preloads it.
    const shim_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shim_mod.addCSourceFile(.{ .file = b.path("src/embed.c"), .flags = &.{"-std=c11"} });
    shim_mod.addCSourceFile(.{ .file = frozen_c, .flags = &.{"-std=c11"} });
    shim_mod.addIncludePath(b.path(if (is_windows) "vendor/cpython/include" else "vendor/cpython/include/python3.13"));
    shim_mod.addIncludePath(b.path("src"));
    if (is_windows) {
        shim_mod.addObjectFile(b.path("vendor/cpython/libs/python313.lib"));
    } else {
        shim_mod.addLibraryPath(b.path("vendor/cpython/lib"));
        shim_mod.linkSystemLibrary("python3.13", .{});
        shim_mod.addRPathSpecial(if (is_macos) "@loader_path" else "$ORIGIN");
    }
    const shim = b.addLibrary(.{
        .name = "taipan_shim",
        .linkage = .dynamic,
        .root_module = shim_mod,
    });

    // On Linux, python-build-standalone ships libpython unstripped (241MB of
    // debug info); strip to ~20MB before embedding. .dynsym survives
    // --strip-all. The macOS dylib (~18MB) and python313.dll (~6MB) ship
    // pre-stripped — embed as-is.
    const vendored_libpython = b.path(if (is_windows)
        "vendor/cpython/python313.dll"
    else
        b.fmt("vendor/cpython/lib/{s}", .{libpython_name}));
    const libpython_blob: std.Build.LazyPath = if (t.os.tag == .linux) blk: {
        const strip_libpython = b.addSystemCommand(&.{ "strip", "--strip-all", "-o" });
        const out = strip_libpython.addOutputFileArg(libpython_name);
        strip_libpython.addFileArg(vendored_libpython);
        break :blk out;
    } else vendored_libpython;

    const opts = b.addOptions();
    opts.addOption([]const u8, "runtime_tag", b.fmt("cpython-3.13.14-{s}", .{python_platform}));
    opts.addOption([]const u8, "python_version", "3.13");
    opts.addOption([]const u8, "python_platform", python_platform);
    opts.addOption([]const u8, "libpython_name", libpython_name);
    opts.addOption([]const u8, "shim_name", shim_name);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", opts);
    mod.addAnonymousImport("stdlib_zip", .{ .root_source_file = stdlib_zip });
    mod.addAnonymousImport("libpython_so", .{ .root_source_file = libpython_blob });
    mod.addAnonymousImport("shim_so", .{ .root_source_file = shim.getEmittedBin() });
    mod.addAnonymousImport("extra_tar", .{ .root_source_file = extra_tar });

    const exe = b.addExecutable(.{ .name = "taipan", .root_module = mod });
    b.installArtifact(exe);

    // `zig build test` — unit tests for the pure-Zig parts (no Python needed).
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/pep723.zig", "src/tarx.zig" }) |root| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}

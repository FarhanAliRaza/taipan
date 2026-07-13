const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Builds are native-only: vendor/cpython (see tools/fetch_toolchain.sh)
    // matches the host, and the payload script runs the vendored python.
    const t = target.result;
    const is_macos = t.os.tag == .macos;
    const python_platform = b.fmt("{s}-{s}", .{
        @tagName(t.cpu.arch),
        if (is_macos) "apple-darwin" else "unknown-linux-gnu",
    });
    const libpython_name: []const u8 = if (is_macos) "libpython3.13.dylib" else "libpython3.13.so.1.0";
    const shim_name: []const u8 = if (is_macos) "libtaipan_shim.dylib" else "libtaipan_shim.so";

    // The C shim (all Python.h usage) as a shared library. It is embedded in
    // the exe, extracted to the runtime cache next to libpython, and dlopen'd
    // — rpath $ORIGIN/@loader_path resolves libpython from the same dir.
    const shim_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shim_mod.addCSourceFile(.{ .file = b.path("src/embed.c"), .flags = &.{"-std=c11"} });
    shim_mod.addIncludePath(b.path("vendor/cpython/include/python3.13"));
    shim_mod.addIncludePath(b.path("src"));
    shim_mod.addLibraryPath(b.path("vendor/cpython/lib"));
    shim_mod.linkSystemLibrary("python3.13", .{});
    shim_mod.addRPathSpecial(if (is_macos) "@loader_path" else "$ORIGIN");
    const shim = b.addLibrary(.{
        .name = "taipan_shim",
        .linkage = .dynamic,
        .root_module = shim_mod,
    });

    // Bytecode-only stdlib zip. The script is passed via addFileArg so its
    // content is a tracked input — editing it triggers a payload rebuild.
    const payload = b.addSystemCommand(&.{"bash"});
    payload.addFileArg(b.path("tools/make_payload.sh"));
    const stdlib_zip = payload.addOutputFileArg("stdlib.zip");

    // On Linux, python-build-standalone ships libpython unstripped (241MB of
    // debug info); strip to ~20MB before embedding. .dynsym survives
    // --strip-all. The macOS dylib ships at ~18MB already — embed as-is
    // (Apple's strip takes different flags anyway).
    const vendored_libpython = b.path(b.fmt("vendor/cpython/lib/{s}", .{libpython_name}));
    const libpython_blob: std.Build.LazyPath = if (is_macos) vendored_libpython else blk: {
        const strip_libpython = b.addSystemCommand(&.{ "strip", "--strip-all", "-o" });
        const out = strip_libpython.addOutputFileArg(libpython_name);
        strip_libpython.addFileArg(vendored_libpython);
        break :blk out;
    };

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

    const exe = b.addExecutable(.{ .name = "taipan", .root_module = mod });
    b.installArtifact(exe);

    // `zig build test` — unit tests for the pure-Zig parts (no Python needed).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pep723.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

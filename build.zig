const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // The C shim (all Python.h usage) as a shared library. It is embedded in
    // the exe, extracted to the runtime cache next to libpython3.13.so.1.0,
    // and dlopen'd — rpath $ORIGIN resolves libpython from the same dir.
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
    shim_mod.addRPathSpecial("$ORIGIN");
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

    // python-build-standalone ships libpython unstripped (241MB of debug
    // info); strip to ~20MB before embedding. .dynsym survives --strip-all.
    const strip_libpython = b.addSystemCommand(&.{ "strip", "--strip-all", "-o" });
    const libpython_stripped = strip_libpython.addOutputFileArg("libpython3.13.so.1.0");
    strip_libpython.addFileArg(b.path("vendor/cpython/lib/libpython3.13.so.1.0"));

    const opts = b.addOptions();
    opts.addOption([]const u8, "runtime_tag", "cpython-3.13.14");
    opts.addOption([]const u8, "python_version", "3.13");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", opts);
    mod.addAnonymousImport("stdlib_zip", .{ .root_source_file = stdlib_zip });
    mod.addAnonymousImport("libpython_so", .{ .root_source_file = libpython_stripped });
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

const std = @import("std");
const build_options = @import("build_options");
const pep723 = @import("pep723.zig");

/// The full runtime, embedded and extracted to the cache on first run:
/// bytecode-only stdlib, libpython itself, and the C shim that drives it.
const stdlib_zip = @embedFile("stdlib_zip");
const libpython_so = @embedFile("libpython_so");
const shim_so = @embedFile("shim_so");

const RunFileFn = *const fn (
    stdlib_path: [*:0]const u8,
    extra_sys_path: [*:0]const u8,
    precompile_extra: c_int,
    script_path: [*:0]const u8,
    argc: c_int,
    argv: [*c][*c]u8,
) callconv(.c) c_int;

const usage = "usage: taipan run <script.py> [args...]\n";

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const args = try std.process.argsAlloc(alloc);

    // Accept both `taipan run script.py` and `taipan script.py`.
    var script_idx: usize = 1;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "run")) script_idx = 2;
    if (args.len <= script_idx) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
    const script_path = args[script_idx];

    const src = std.fs.cwd().readFileAlloc(alloc, script_path, 16 * 1024 * 1024) catch |err| {
        std.debug.print("taipan: cannot read {s}: {s}\n", .{ script_path, @errorName(err) });
        std.process.exit(1);
    };

    const cache_root = try cacheRoot(alloc);
    const rt = try ensureRuntime(alloc, cache_root);

    const deps = try pep723.parseDeps(alloc, src);
    var extra_path: []const u8 = "";
    var fresh_env = false;
    if (deps.len > 0) {
        const env = try ensureEnv(alloc, cache_root, deps);
        extra_path = env.dir;
        fresh_env = env.fresh;
    }

    // sys.argv = [script, script args...]
    const py_argc = args.len - script_idx;
    const argv_z = try alloc.alloc([*c]u8, py_argc);
    for (args[script_idx..], 0..) |a, i| {
        argv_z[i] = (try alloc.dupeZ(u8, a)).ptr;
    }

    // libpython first with RTLD_GLOBAL so manylinux extension modules
    // (which deliberately don't link libpython) can resolve Py* symbols;
    // then the shim, whose rpath $ORIGIN also points at the runtime dir.
    const run_file = loadShim(alloc, rt);

    const rc = run_file(
        (try alloc.dupeZ(u8, rt.stdlib_zip)).ptr,
        (try alloc.dupeZ(u8, extra_path)).ptr,
        @intFromBool(fresh_env),
        (try alloc.dupeZ(u8, script_path)).ptr,
        @intCast(py_argc),
        argv_z.ptr,
    );
    std.process.exit(if (rc < 0) 1 else @intCast(@min(rc, 255)));
}

fn cacheRoot(alloc: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(alloc, "TAIPAN_CACHE")) |dir| return dir else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    return std.fmt.allocPrint(alloc, "{s}/.cache/taipan", .{home});
}

const Runtime = struct {
    stdlib_zip: []const u8,
    libpython: []const u8,
    shim: []const u8,
};

/// Extract the embedded runtime (stdlib.zip, libpython, shim) to the
/// version-keyed cache dir, each file atomically (tmp + rename). No-op when
/// the completion marker is present.
fn ensureRuntime(alloc: std.mem.Allocator, cache_root: []const u8) !Runtime {
    const dir = try std.fmt.allocPrint(alloc, "{s}/runtime/{s}", .{ cache_root, build_options.runtime_tag });
    const rt: Runtime = .{
        .stdlib_zip = try std.fmt.allocPrint(alloc, "{s}/stdlib.zip", .{dir}),
        .libpython = try std.fmt.allocPrint(alloc, "{s}/libpython3.13.so.1.0", .{dir}),
        .shim = try std.fmt.allocPrint(alloc, "{s}/libtaipan_shim.so", .{dir}),
    };
    const marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-ok", .{dir});

    if (std.fs.cwd().access(marker, .{})) |_| {
        return rt;
    } else |_| {}

    try std.fs.cwd().makePath(dir);
    try extractFile(alloc, rt.stdlib_zip, stdlib_zip, false);
    try extractFile(alloc, rt.libpython, libpython_so, true);
    try extractFile(alloc, rt.shim, shim_so, true);
    (try std.fs.cwd().createFile(marker, .{})).close();
    return rt;
}

fn extractFile(alloc: std.mem.Allocator, dest: []const u8, data: []const u8, executable: bool) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ dest, std.os.linux.getpid() });
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .mode = if (executable) 0o755 else 0o644 });
        defer f.close();
        try f.writeAll(data);
    }
    try std.fs.cwd().rename(tmp, dest);
}

/// dlopen libpython (RTLD_NOW | RTLD_GLOBAL) then the shim, and resolve the
/// single entry point. Any failure here is fatal and unrecoverable.
fn loadShim(alloc: std.mem.Allocator, rt: Runtime) RunFileFn {
    return loadShimInner(alloc, rt) catch |err| {
        std.debug.print("taipan: failed to load runtime: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn loadShimInner(alloc: std.mem.Allocator, rt: Runtime) !RunFileFn {
    const flags: std.c.RTLD = .{ .NOW = true, .GLOBAL = true };
    if (std.c.dlopen((try alloc.dupeZ(u8, rt.libpython)).ptr, flags) == null) {
        std.debug.print("taipan: dlopen libpython: {s}\n", .{std.c.dlerror() orelse "?"});
        return error.DlopenLibpython;
    }
    const shim_handle = std.c.dlopen((try alloc.dupeZ(u8, rt.shim)).ptr, flags) orelse {
        std.debug.print("taipan: dlopen shim: {s}\n", .{std.c.dlerror() orelse "?"});
        return error.DlopenShim;
    };
    const sym = std.c.dlsym(shim_handle, "taipan_run_file") orelse return error.MissingSymbol;
    return @ptrCast(@alignCast(sym));
}

const EnvResult = struct { dir: []const u8, fresh: bool };

/// Return the content-addressed env dir for `deps`, populating it via
/// `uv pip install --target` on first use. Cache key = sorted dep list +
/// interpreter tag, so uv never runs on a warm start. `fresh` tells the
/// caller to precompile the env in-process.
fn ensureEnv(alloc: std.mem.Allocator, cache_root: []const u8, deps: [][]const u8) !EnvResult {
    const sorted = try alloc.dupe([]const u8, deps);
    std.mem.sort([]const u8, sorted, {}, strLessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(build_options.runtime_tag);
    hasher.update("\x00");
    for (sorted) |d| {
        hasher.update(d);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    const env_dir = try std.fmt.allocPrint(alloc, "{s}/envs/{s}", .{ cache_root, hex[0..16] });
    const marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-ok", .{env_dir});

    if (std.fs.cwd().access(marker, .{})) |_| {
        return .{ .dir = env_dir, .fresh = false };
    } else |_| {}

    std.debug.print("taipan: installing {d} dependencies into cache...\n", .{deps.len});

    const uv = try findUv(alloc, cache_root);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        uv,                  "pip",                      "install",
        "--quiet",           "--python-version",         build_options.python_version,
        "--python-platform", "x86_64-unknown-linux-gnu", "--target",
        env_dir,
    });
    try argv.appendSlice(alloc, deps);

    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("taipan: uv failed:\n{s}\n", .{res.stderr});
        std.process.exit(1);
    }

    (try std.fs.cwd().createFile(marker, .{})).close();
    return .{ .dir = env_dir, .fresh = true };
}

/// Locate uv: $TAIPAN_UV, then PATH, then the taipan cache — downloading a static
/// uv into the cache as a last resort so dep installs work on machines with
/// nothing installed.
fn findUv(alloc: std.mem.Allocator, cache_root: []const u8) ![]const u8 {
    if (std.process.getEnvVarOwned(alloc, "TAIPAN_UV")) |uv| return uv else |_| {}

    if (std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "uv", "--version" },
    })) |res| {
        switch (res.term) {
            .Exited => |code| if (code == 0) return "uv",
            else => {},
        }
    } else |_| {}

    const cached = try std.fmt.allocPrint(alloc, "{s}/bin/uv", .{cache_root});
    if (std.fs.cwd().access(cached, .{})) |_| return cached else |_| {}

    std.debug.print("taipan: downloading uv (one-time)...\n", .{});
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/bin", .{cache_root});
    try std.fs.cwd().makePath(bin_dir);
    const cmd = try std.fmt.allocPrint(alloc,
        \\set -e; curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz | tar -xz -C '{s}' --strip-components=1
    , .{bin_dir});
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "sh", "-c", cmd },
        .max_output_bytes = 1024 * 1024,
    });
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("taipan: could not download uv; install it or set TAIPAN_UV.\n{s}\n", .{res.stderr});
        std.process.exit(1);
    }
    return cached;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pep723 = @import("pep723.zig");
const tarx = @import("tarx.zig");
const entrypoints = @import("entrypoints.zig");

const is_windows = builtin.os.tag == .windows;

/// The full runtime, embedded and extracted to the cache on first run:
/// bytecode-only stdlib, libpython itself, the C shim that drives it, and
/// (Windows only) a tar of the stdlib .pyd extensions and support DLLs.
const stdlib_zip = @embedFile("stdlib_zip");
const libpython_so = @embedFile("libpython_so");
const shim_so = @embedFile("shim_so");
const extra_tar = @embedFile("extra_tar");
const include_tar_gz = @embedFile("include_tar_gz");

const RunFileFn = *const fn (
    executable_path: [*:0]const u8,
    stdlib_path: [*:0]const u8,
    extra_paths: [*c]const [*c]const u8,
    extra_path_count: c_int,
    precompile_dir: [*:0]const u8,
    script_path: [*:0]const u8,
    script_source: [*:0]const u8,
    pyc_path: [*:0]const u8,
    argc: c_int,
    argv: [*c][*c]u8,
) callconv(.c) c_int;

/// NUL-terminate each path for the shim's `const char *const *`.
fn dupeZPaths(alloc: std.mem.Allocator, paths: []const []const u8) ![]const [*c]const u8 {
    const out = try alloc.alloc([*c]const u8, paths.len);
    for (paths, out) |path, *slot| slot.* = (try alloc.dupeZ(u8, path)).ptr;
    return out;
}

const usage =
    \\usage:
    \\  taipan <script.py> [args...]
    \\  taipan run <script.py> [args...]
    \\  taipan build <script.py> [-o <output>] [--include-local] [--include <path>]...
    \\  taipan build <package|directory> [-e <console-script>] [-o <output>] [--include <path>]...
    \\
;

const bundle_magic = "TPNBNDL2";
const bundle_footer_len = bundle_magic.len + 3 * @sizeOf(u64) + 32;

const BundleFooter = struct {
    base_len: u64,
    source_len: u64,
    deps_len: u64,
    /// SHA-256 of runtime tag + script source + appended archive, computed
    /// at build time. Doubles as the target-side bundle cache key — a warm
    /// start never re-reads the payload — and as the integrity check on
    /// first extraction.
    digest: [32]u8,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const args = try std.process.argsAlloc(alloc);

    // CPython's multiprocessing helpers re-exec sys.executable with `-c` for
    // the resource tracker, fork server, and spawned workers, and uv probes
    // an interpreter the same way (`-I -B -c <query>`). Both modes are
    // deliberately enabled only by an env var taipan itself sets, so `-c`
    // remains an ordinary argument to a built application.
    const command_mode: ?CommandMode = if (std.process.hasEnvVarConstant("TAIPAN_PYTHON"))
        .build_interpreter
    else if (std.process.hasEnvVarConstant("TAIPAN_CHILD"))
        .worker
    else
        null;
    if (command_mode) |mode| {
        if (workerCommandIndex(args)) |i| try runCommand(alloc, args, i, mode);
    }

    // A built executable is the normal taipan launcher with a script and its
    // dependency environment appended. It always runs that embedded script;
    // every command-line argument belongs to the script.
    const maybe_footer = readBundleFooter(alloc) catch |err| switch (err) {
        error.InvalidBundle => {
            std.debug.print("taipan: this executable is corrupt (truncated or modified after `taipan build`)\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    if (maybe_footer) |footer| try runBundle(alloc, args, footer);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) {
        try buildCommand(alloc, args);
        return;
    }

    // Accept both `taipan run script.py` and `taipan script.py`.
    var script_idx: usize = 1;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "run")) script_idx = 2;
    if (args.len <= script_idx) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
    const script_path = args[script_idx];

    var src: []u8 = std.fs.cwd().readFileAlloc(alloc, script_path, 16 * 1024 * 1024) catch |err| {
        std.debug.print("taipan: cannot read {s}: {s}\n", .{ script_path, @errorName(err) });
        std.process.exit(1);
    };
    // The shim compiles from a UTF-8 string, where a BOM (which CPython's
    // file reader would skip) is a syntax error.
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];

    try runScript(alloc, args, script_idx, script_path, src);
}

/// Recognize CPython's re-exec shape — `sys.executable [interpreter flags]
/// -c <prog> ...` — and nothing else. TAIPAN_CHILD is inherited by every
/// descendant of a taipan runtime, including nested `taipan run ...`
/// invocations, so a `-c` that follows a non-flag argument (a subcommand or
/// a script path) must stay an ordinary argument.
fn workerCommandIndex(args: []const []const u8) ?usize {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) return if (i + 1 < args.len) i else null;
        // `-X opt` and `-W filter` carry their value as a separate argument.
        if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "-W")) {
            i += 1;
            continue;
        }
        if (arg.len < 2 or arg[0] != '-') return null;
    }
    return null;
}

fn runScript(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    script_idx: usize,
    script_path: []const u8,
    src: []u8,
) !noreturn {
    const cache_root = try cacheRoot(alloc);
    var extra_path: []const u8 = "";
    var fresh_env = false;
    const deps = try pep723.parseDeps(alloc, src);
    if (deps.len > 0) {
        const env = try ensureEnv(alloc, cache_root, deps);
        extra_path = env.dir;
        fresh_env = env.fresh;
    }
    try execResolved(alloc, cache_root, args, script_idx, script_path, src, extra_path, fresh_env);
}

/// Run the script embedded in this executable. A warm start reads only the
/// footer and the cached copy of the script: the footer digest already names
/// the extracted bundle dir, so the appended archive is never re-read.
fn runBundle(alloc: std.mem.Allocator, args: []const []const u8, footer: BundleFooter) !noreturn {
    const cache_root = try cacheRoot(alloc);
    const hex = std.fmt.bytesToHex(footer.digest, .lower);
    const dir = try std.fmt.allocPrint(alloc, "{s}/bundles/{s}", .{ cache_root, hex[0..16] });
    const marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-ok", .{dir});
    const script = try std.fmt.allocPrint(alloc, "{s}/.taipan-main.py", .{dir});

    var fresh = false;
    if (std.fs.cwd().access(marker, .{})) |_| {} else |_| {
        fresh = try extractBundle(alloc, footer, dir, marker);
    }

    const src = std.fs.cwd().readFileAlloc(alloc, script, 16 * 1024 * 1024) catch {
        std.debug.print("taipan: bundle cache at {s} is unreadable; delete it and rerun\n", .{dir});
        std.process.exit(1);
    };
    const extra_path: []const u8 = if (footer.deps_len > 0) dir else "";
    try execResolved(alloc, cache_root, args, 0, script, src, extra_path, fresh);
}

fn execResolved(
    alloc: std.mem.Allocator,
    cache_root: []const u8,
    args: []const []const u8,
    script_idx: usize,
    script_path: []const u8,
    src: []const u8,
    extra_path: []const u8,
    fresh_env: bool,
) !noreturn {
    // Absolute path (with '/' separators) for __file__ and traceback
    // filenames: it stays valid however the cwd changes, and it is part of
    // the compiled-script cache key.
    const abs_script = blk: {
        const cwd = try std.process.getCwdAlloc(alloc);
        const p = try std.fs.path.resolve(alloc, &.{ cwd, script_path });
        if (is_windows) std.mem.replaceScalar(u8, p, '\\', '/');
        break :blk p;
    };

    const rt = try ensureRuntime(alloc, cache_root);
    const pyc_path = scriptPycPath(alloc, cache_root, abs_script, src);

    // sys.argv = [script, script args...]
    const py_argc = args.len - script_idx;
    const argv_z = try alloc.alloc([*c]u8, py_argc);
    for (args[script_idx..], 0..) |a, i| {
        argv_z[i] = (try alloc.dupeZ(u8, a)).ptr;
    }

    // libpython first with RTLD_GLOBAL so wheel extension modules (which
    // deliberately don't link libpython on Linux and macOS) can resolve Py*
    // symbols; then the shim, whose rpath ($ORIGIN / @loader_path) also
    // points at the runtime dir.
    const run_file = loadShim(alloc, rt);
    const self_path = try std.fs.selfExePathAlloc(alloc);

    // A script run has at most the one dependency environment, and it is also
    // what a fresh install precompiles.
    const one = [_][]const u8{extra_path};
    const extra_z = try dupeZPaths(alloc, if (extra_path.len > 0) one[0..] else &.{});

    const rc = run_file(
        (try alloc.dupeZ(u8, self_path)).ptr,
        (try alloc.dupeZ(u8, rt.stdlib_zip)).ptr,
        extra_z.ptr,
        @intCast(extra_z.len),
        (try alloc.dupeZ(u8, if (fresh_env) extra_path else "")).ptr,
        (try alloc.dupeZ(u8, abs_script)).ptr,
        (try alloc.dupeZ(u8, src)).ptr,
        (try alloc.dupeZ(u8, pyc_path)).ptr,
        @intCast(py_argc),
        argv_z.ptr,
    );
    std.process.exit(if (rc < 0) 1 else @intCast(@min(rc, 255)));
}

/// Why this process is honouring a `-c`. Both are marked by an environment
/// variable taipan itself sets, and a build backend that uses multiprocessing
/// has both set at once — `build_interpreter` wins, because everything under
/// uv still needs the build environment on sys.path.
const CommandMode = enum { worker, build_interpreter };

/// uv runs PEP 517 build hooks as `<venv>/bin/python -c ...`, where that
/// python is a symlink to this executable. `selfExePath` resolves the symlink
/// and so loses the venv, but argv[0] still names it: a venv is the parent of
/// the directory holding the interpreter, marked by a pyvenv.cfg.
fn venvSitePackages(alloc: std.mem.Allocator, argv0: []const u8) !?[]const u8 {
    const bin_dir = std.fs.path.dirname(argv0) orelse return null;
    const root = std.fs.path.dirname(bin_dir) orelse return null;
    const cfg = try std.fmt.allocPrint(alloc, "{s}/pyvenv.cfg", .{root});
    std.fs.cwd().access(cfg, .{}) catch return null;
    return if (is_windows)
        try std.fmt.allocPrint(alloc, "{s}/Lib/site-packages", .{root})
    else
        try std.fmt.allocPrint(alloc, "{s}/lib/python{s}/site-packages", .{ root, build_options.python_version });
}

/// sys.path additions for a `-c` invocation: the dependency environment
/// carried across a multiprocessing re-exec, plus — under uv — the build
/// venv's site-packages and $PYTHONPATH. A stock python derives those two
/// from argv[0] and the environment; the embedded config is isolated and
/// imports no `site`, so they have to be added by hand.
fn commandSearchPath(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    mode: CommandMode,
) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    if (std.process.getEnvVarOwned(alloc, "TAIPAN_CHILD_PATH")) |p| {
        if (p.len > 0) try paths.append(alloc, p);
    } else |_| {}
    if (mode == .build_interpreter and args.len > 0) {
        if (try venvSitePackages(alloc, args[0])) |sp| try paths.append(alloc, sp);
        if (std.process.getEnvVarOwned(alloc, "PYTHONPATH")) |p| {
            var it = std.mem.tokenizeScalar(u8, p, if (is_windows) ';' else ':');
            while (it.next()) |entry| try paths.append(alloc, entry);
        } else |_| {}
    }
    return paths.items;
}

fn runCommand(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    command_idx: usize,
    mode: CommandMode,
) !noreturn {
    const cache_root = try cacheRoot(alloc);
    const rt = try ensureRuntime(alloc, cache_root);
    const extra_z = try dupeZPaths(alloc, try commandSearchPath(alloc, args, mode));

    // Interpreter flags preceding -c (e.g. -B/-E from CPython's
    // _args_from_interpreter_flags) are dropped: the embedded config is
    // already isolated, so they are no-ops here.
    // Python's `-c` argv excludes the command string itself.
    const py_argc = args.len - command_idx - 1;
    const argv_z = try alloc.alloc([*c]u8, py_argc);
    argv_z[0] = (try alloc.dupeZ(u8, "-c")).ptr;
    for (args[command_idx + 2 ..], 1..) |arg, i| argv_z[i] = (try alloc.dupeZ(u8, arg)).ptr;

    const self_path = try std.fs.selfExePathAlloc(alloc);
    const run_file = loadShim(alloc, rt);
    const rc = run_file(
        (try alloc.dupeZ(u8, self_path)).ptr,
        (try alloc.dupeZ(u8, rt.stdlib_zip)).ptr,
        extra_z.ptr,
        @intCast(extra_z.len),
        "",
        "<string>",
        (try alloc.dupeZ(u8, args[command_idx + 1])).ptr,
        "",
        @intCast(py_argc),
        argv_z.ptr,
    );
    std.process.exit(if (rc < 0) 1 else @intCast(@min(rc, 255)));
}

const BuildOptions = struct {
    output: ?[]const u8 = null,
    include_local: bool = false,
    includes: std.ArrayList([]const u8) = .empty,
    entrypoint: ?[]const u8 = null,
};

/// Everything the bundle writer needs, however the input was described.
const BuildInput = struct {
    /// Python source that becomes the bundle's `__main__`.
    src: []const u8,
    /// Installed environment to append to the bundle, if any.
    env_dir: ?[]const u8 = null,
    /// The input script, when building one: the output must not overwrite it,
    /// and `--include-local` walks its directory. Empty for a package build.
    abs_script: []const u8 = "",
    /// Output name when `-o` is absent, without any executable suffix.
    default_name: []const u8,
    /// Environment to delete once the build is written, for inputs that
    /// cannot be content-addressed and so are installed fresh every time.
    scratch_env: ?[]const u8 = null,
    /// Leading half of the "taipan: built ..." line.
    summary: []const u8,
};

fn buildCommand(alloc: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }

    const target = args[2];
    if (target.len == 0 or target[0] == '-') {
        std.debug.print("taipan: expected a script, directory or package before build options\n{s}", .{usage});
        std.process.exit(2);
    }
    var opts: BuildOptions = .{};
    var i: usize = 3;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (i + 1 >= args.len) {
                std.debug.print("taipan: missing value for {s}\n", .{args[i]});
                std.process.exit(2);
            }
            if (opts.output != null) {
                std.debug.print("taipan: output specified more than once\n", .{});
                std.process.exit(2);
            }
            opts.output = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "-e") or std.mem.eql(u8, args[i], "--entrypoint")) {
            if (i + 1 >= args.len) {
                std.debug.print("taipan: missing value for {s}\n", .{args[i]});
                std.process.exit(2);
            }
            if (opts.entrypoint != null) {
                std.debug.print("taipan: entry point specified more than once\n", .{});
                std.process.exit(2);
            }
            opts.entrypoint = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--include-local")) {
            opts.include_local = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--include")) {
            if (i + 1 >= args.len) {
                std.debug.print("taipan: missing value for --include\n", .{});
                std.process.exit(2);
            }
            try opts.includes.append(alloc, args[i + 1]);
            i += 2;
        } else {
            std.debug.print("taipan: unknown build option: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    const cache_root = try cacheRoot(alloc);

    // A script is built from its own source. Anything else — a project
    // directory or a requirement like `omniload==0.7.0` — is installed, and
    // the bundle is built around one of its console scripts. A path that ends
    // in .py is a script whether or not it exists, so a typo is reported as
    // the missing file it is rather than as an unresolvable requirement.
    const input = if (isRegularFile(target) or std.mem.endsWith(u8, target, ".py")) blk: {
        if (opts.entrypoint != null) {
            std.debug.print("taipan: -e applies to package builds, but {s} is a script\n", .{target});
            std.process.exit(2);
        }
        break :blk try prepareScriptBuild(alloc, cache_root, target);
    } else blk: {
        if (opts.include_local) {
            std.debug.print("taipan: --include-local applies to script builds; a package's own modules are installed by uv\n", .{});
            std.process.exit(2);
        }
        // All four are reported where they happen, and the scratch env is
        // released by errdefer on the way out; nothing is left to say here.
        break :blk preparePackageBuild(alloc, cache_root, target, opts.entrypoint) catch |err| switch (err) {
            error.InvalidEntryPointSpec => std.process.exit(2),
            error.InstallFailed,
            error.EnvironmentUnreadable,
            error.EntryPointUnavailable,
            => std.process.exit(1),
            else => return err,
        };
    };
    defer if (input.scratch_env) |dir| {
        std.fs.cwd().deleteTree(dir) catch {};
    };

    const src = input.src;

    const output_path = opts.output orelse if (is_windows)
        try std.fmt.allocPrint(alloc, "{s}.exe", .{input.default_name})
    else
        input.default_name;

    const cwd = try std.process.getCwdAlloc(alloc);
    const abs_output = try std.fs.path.resolve(alloc, &.{ cwd, output_path });
    const self_path = try std.fs.selfExePathAlloc(alloc);
    if (std.mem.eql(u8, abs_output, self_path) or std.mem.eql(u8, abs_output, input.abs_script)) {
        std.debug.print("taipan: refusing to overwrite the launcher or input script\n", .{});
        std.process.exit(1);
    }
    if (isDirectory(abs_output)) {
        std.debug.print("taipan: output {s} is a directory\n", .{output_path});
        std.process.exit(1);
    }

    const pid = if (is_windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ abs_output, pid });
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var launcher = try std.fs.openFileAbsolute(self_path, .{});
    defer launcher.close();
    const launcher_stat = try launcher.stat();
    {
        var output_file = try std.fs.createFileAbsolute(tmp_path, .{ .read = true, .mode = 0o755 });
        defer output_file.close();

        var write_buf: [64 * 1024]u8 = undefined;
        var out_writer = output_file.writerStreaming(&write_buf);
        var read_buf: [64 * 1024]u8 = undefined;
        var launcher_reader = std.fs.File.Reader.initSize(launcher, &read_buf, launcher_stat.size);
        _ = try out_writer.interface.sendFileAll(&launcher_reader, .unlimited);
        try out_writer.interface.writeAll(src);

        // The sections below form one continuous tar stream: tar entries are
        // self-delimiting, and std.tar.Writer never emits the two-zero-block
        // end-of-archive terminator (extraction relies on plain EOF). A
        // finish()/terminator between sections would truncate extraction.
        var seen = std.BufSet.init(alloc);
        const deps_start = launcher_stat.size + src.len;
        if (input.env_dir) |dir| try writeDirectoryTar(alloc, dir, &out_writer.interface, &seen);
        if (opts.include_local) {
            const script_dir = std.fs.path.dirname(input.abs_script) orelse cwd;
            try writeLocalPythonTar(alloc, script_dir, std.fs.path.basename(input.abs_script), &out_writer.interface, &seen);
        }
        for (opts.includes.items) |include_path| {
            const abs_include = try std.fs.path.resolve(alloc, &.{ cwd, include_path });
            try writeIncludedPathTar(alloc, abs_include, &out_writer.interface, &seen);
        }
        try out_writer.interface.flush();
        const payload_end = try output_file.getPos();
        const deps_len = payload_end - deps_start;

        // Hash the archive back from the temp file (it was streamed to disk,
        // never held in memory) through a separate handle so the writer's
        // file position is untouched.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(build_options.runtime_tag);
        hasher.update(src);
        {
            var check = try std.fs.openFileAbsolute(tmp_path, .{});
            defer check.close();
            try check.seekTo(deps_start);
            var remaining = deps_len;
            var chunk: [64 * 1024]u8 = undefined;
            while (remaining > 0) {
                const want: usize = @intCast(@min(chunk.len, remaining));
                if (try check.readAll(chunk[0..want]) != want) return error.UnexpectedEndOfFile;
                hasher.update(chunk[0..want]);
                remaining -= want;
            }
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        var footer: [bundle_footer_len]u8 = undefined;
        @memcpy(footer[0..bundle_magic.len], bundle_magic);
        std.mem.writeInt(u64, footer[8..16], launcher_stat.size, .little);
        std.mem.writeInt(u64, footer[16..24], src.len, .little);
        std.mem.writeInt(u64, footer[24..32], deps_len, .little);
        @memcpy(footer[32..64], &digest);
        try out_writer.interface.writeAll(&footer);
        try out_writer.end();
    }

    // Only replace an older output after the temporary executable is complete.
    std.fs.deleteFileAbsolute(abs_output) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(tmp_path, abs_output);
    if (!is_windows) {
        var built = try std.fs.openFileAbsolute(abs_output, .{ .mode = .read_write });
        defer built.close();
        try built.chmod(0o755);
    }
    std.debug.print("taipan: built {s} ({s}, {d} explicit includes)\n", .{ output_path, input.summary, opts.includes.items.len });
}

fn prepareScriptBuild(alloc: std.mem.Allocator, cache_root: []const u8, script_path: []const u8) !BuildInput {
    var src = std.fs.cwd().readFileAlloc(alloc, script_path, 16 * 1024 * 1024) catch |err| {
        std.debug.print("taipan: cannot read {s}: {s}\n", .{ script_path, @errorName(err) });
        std.process.exit(1);
    };
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];

    const cwd = try std.process.getCwdAlloc(alloc);
    const deps = try pep723.parseDeps(alloc, src);
    var env_dir: ?[]const u8 = null;
    if (deps.len > 0) env_dir = (try ensureEnv(alloc, cache_root, deps)).dir;

    return .{
        .src = src,
        .env_dir = env_dir,
        .abs_script = try std.fs.path.resolve(alloc, &.{ cwd, script_path }),
        .default_name = std.fs.path.stem(std.fs.path.basename(script_path)),
        .summary = try std.fmt.allocPrint(alloc, "{d} dependencies", .{deps.len}),
    };
}

/// Build around a distribution rather than a script: install `spec` — a
/// project directory or any requirement uv understands — then generate a
/// `__main__` that invokes one of its console scripts.
fn preparePackageBuild(
    alloc: std.mem.Allocator,
    cache_root: []const u8,
    spec: []const u8,
    requested: ?[]const u8,
) !BuildInput {
    const cwd = try std.process.getCwdAlloc(alloc);
    const local = isDirectory(spec);
    const requirement = if (local) try std.fs.path.resolve(alloc, &.{ cwd, spec }) else spec;

    // A directory's contents change between builds, so its install cannot be
    // content-addressed by the requirement string the way a pinned release
    // can. Install into a private directory and discard it afterwards; uv's
    // own cache still keeps the dependency downloads.
    const pid = if (is_windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    const scratch_env: ?[]const u8 = if (local)
        try std.fmt.allocPrint(alloc, "{s}/build/{d}", .{ cache_root, pid })
    else
        null;
    errdefer if (scratch_env) |dir| {
        std.fs.cwd().deleteTree(dir) catch {};
    };

    const env_dir = if (scratch_env) |dir| blk: {
        std.fs.cwd().deleteTree(dir) catch {};
        std.debug.print("taipan: installing {s}...\n", .{spec});
        try installEnv(alloc, cache_root, dir, &.{requirement});
        break :blk dir;
    } else (try ensureEnv(alloc, cache_root, &.{requirement})).dir;

    const installed = try collectEntryPoints(alloc, env_dir);

    // Which of the installed distributions is the one being packaged: for a
    // requirement, the name it starts with; for a directory, whichever
    // distribution records that it came from a path (PEP 610), falling back
    // to the name pyproject.toml declares.
    const target_dist: ?[]const u8 = blk: {
        if (!local) break :blk try entrypoints.requirementName(alloc, spec);
        if (installed.direct_dist) |dist| break :blk dist;
        const toml_path = try std.fmt.allocPrint(alloc, "{s}/pyproject.toml", .{requirement});
        const toml = std.fs.cwd().readFileAlloc(alloc, toml_path, 1024 * 1024) catch break :blk null;
        break :blk try entrypoints.projectName(alloc, toml);
    };

    const script = try resolveConsoleScript(installed, target_dist, requested, spec);

    return .{
        .src = try entrypoints.generateMain(alloc, script.name, script.target),
        .env_dir = env_dir,
        .default_name = script.name,
        .scratch_env = scratch_env,
        .summary = try std.fmt.allocPrint(
            alloc,
            "entry point {s} -> {s}:{s}, {d} packages",
            .{ script.name, script.target.module, script.target.attr, installed.dist_count },
        ),
    };
}

const ConsoleScript = struct { name: []const u8, target: entrypoints.Target };

/// Decide which console script the built executable runs, reporting to the
/// user on failure. `requested` is either a script name or, for packages that
/// declare no console script for what you want to run, a `module:function`
/// import target given directly.
fn resolveConsoleScript(
    installed: InstalledScripts,
    target_dist: ?[]const u8,
    requested: ?[]const u8,
    spec: []const u8,
) error{ InvalidEntryPointSpec, EntryPointUnavailable }!ConsoleScript {
    if (requested) |want| {
        if (std.mem.indexOfScalar(u8, want, ':') != null) {
            const target = entrypoints.parseTarget(want) orelse {
                std.debug.print("taipan: -e {s} is not a valid module:function target\n", .{want});
                return error.InvalidEntryPointSpec;
            };
            const dot = std.mem.indexOfScalar(u8, target.module, '.') orelse target.module.len;
            return .{ .name = target_dist orelse target.module[0..dot], .target = target };
        }
    }

    const ep = entrypoints.select(installed.entries, target_dist, requested) catch |err| {
        switch (err) {
            error.EntryPointNotFound => std.debug.print(
                "taipan: no installed console script is named {s}\n",
                .{requested.?},
            ),
            error.NoEntryPoints => std.debug.print(
                "taipan: {s} declares no console scripts; name one with -e, or -e module:function\n",
                .{spec},
            ),
            error.AmbiguousEntryPoint => std.debug.print(
                "taipan: more than one console script matches; choose one with -e\n",
                .{},
            ),
        }
        listConsoleScripts(installed.entries, target_dist);
        return error.EntryPointUnavailable;
    };
    const target = entrypoints.parseTarget(ep.value) orelse {
        std.debug.print("taipan: console script {s} has an unsupported target: {s}\n", .{ ep.name, ep.value });
        return error.EntryPointUnavailable;
    };
    return .{ .name = ep.name, .target = target };
}

fn listConsoleScripts(entries: []const entrypoints.EntryPoint, target_dist: ?[]const u8) void {
    if (entries.len == 0) return;
    std.debug.print("  available console scripts:\n", .{});
    for (entries) |e| {
        const own = if (target_dist) |d| std.mem.eql(u8, e.dist, d) else false;
        std.debug.print("    {s}{s} = {s}  (from {s})\n", .{
            if (own) "* " else "  ",
            e.name,
            e.value,
            e.dist,
        });
    }
}

const InstalledScripts = struct {
    entries: []entrypoints.EntryPoint,
    dist_count: usize,
    /// Normalized name of the one distribution installed from a path or URL,
    /// when exactly one was.
    direct_dist: ?[]const u8,
};

/// Read the `[console_scripts]` of every distribution installed in `env_dir`
/// — the same `*.dist-info/entry_points.txt` files `importlib.metadata` reads,
/// without needing an interpreter to read them.
fn collectEntryPoints(alloc: std.mem.Allocator, env_dir: []const u8) !InstalledScripts {
    var entries: std.ArrayList(entrypoints.EntryPoint) = .empty;
    var dist_count: usize = 0;
    var direct: ?[]const u8 = null;
    var direct_count: usize = 0;

    var dir = std.fs.cwd().openDir(env_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("taipan: cannot read the installed environment at {s}: {s}\n", .{ env_dir, @errorName(err) });
        return error.EnvironmentUnreadable;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const dist = try entrypoints.distFromDistInfo(alloc, entry.name) orelse continue;
        dist_count += 1;
        // PEP 610: only requirements given as a path or URL record their
        // origin, which is exactly the distribution being packaged.
        const url_path = try std.fmt.allocPrint(alloc, "{s}/direct_url.json", .{entry.name});
        if (dir.access(url_path, .{})) |_| {
            direct_count += 1;
            direct = dist;
        } else |_| {}
        const eps_path = try std.fmt.allocPrint(alloc, "{s}/entry_points.txt", .{entry.name});
        const text = dir.readFileAlloc(alloc, eps_path, 1024 * 1024) catch continue;
        try entrypoints.parseEntryPoints(alloc, dist, text, &entries);
    }
    return .{
        .entries = entries.items,
        .dist_count = dist_count,
        .direct_dist = if (direct_count == 1) direct else null,
    };
}

fn isRegularFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// The bundle's tar sections extract into one directory in order
/// (dependencies, local modules, explicit includes), and a repeated path is
/// silently overwritten by the last copy. Warn at build time instead of
/// surprising at run time.
fn noteBundlePath(seen: *std.BufSet, path: []const u8) !void {
    if (std.mem.eql(u8, path, ".taipan-ok") or std.mem.eql(u8, path, ".taipan-main.py")) {
        std.debug.print("taipan: warning: {s} is reserved by the taipan runtime and will be replaced\n", .{path});
        return;
    }
    if (seen.contains(path)) {
        std.debug.print("taipan: warning: {s} is bundled more than once; the last copy wins\n", .{path});
        return;
    }
    try seen.insert(path);
}

fn writeLocalPythonTar(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    entry_name: []const u8,
    writer: *std.Io.Writer,
    seen: *std.BufSet,
) !void {
    var root = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer root.close();
    var archive: std.tar.Writer = .{ .underlying_writer = writer };
    try writeLocalPythonDir(alloc, root, "", entry_name, &archive, seen);
}

fn writeLocalPythonDir(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    entry_name: []const u8,
    archive: *std.tar.Writer,
    seen: *std.BufSet,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (isIgnoredLocalDir(entry.name)) continue;
        const path = if (prefix.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                try archive.writeDir(path, .{});
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                try writeLocalPythonDir(alloc, child, path, entry_name, archive, seen);
            },
            .file => {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".py")) continue;
                if (prefix.len == 0 and std.mem.eql(u8, entry.name, entry_name)) continue;
                try noteBundlePath(seen, path);
                try writeTarFile(dir, entry.name, path, archive);
            },
            else => {},
        }
    }
}

fn isIgnoredLocalDir(name: []const u8) bool {
    for ([_][]const u8{
        ".git", ".hg",         ".svn",         ".venv",     "venv",
        "env",  "__pycache__", "node_modules", "zig-cache", "zig-out",
    }) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

fn writeIncludedPathTar(alloc: std.mem.Allocator, abs_path: []const u8, writer: *std.Io.Writer, seen: *std.BufSet) !void {
    const parent_path = std.fs.path.dirname(abs_path) orelse return error.InvalidIncludePath;
    const name = std.fs.path.basename(abs_path);
    var parent = try std.fs.openDirAbsolute(parent_path, .{ .iterate = true });
    defer parent.close();
    const stat = try parent.statFile(name);
    var archive: std.tar.Writer = .{ .underlying_writer = writer };
    switch (stat.kind) {
        .file => {
            try noteBundlePath(seen, name);
            try writeTarFile(parent, name, name, &archive);
        },
        .directory => {
            try archive.writeDir(name, .{});
            var child = try parent.openDir(name, .{ .iterate = true });
            defer child.close();
            try writeAllDir(alloc, child, name, &archive, seen);
        },
        else => return error.UnsupportedIncludeFileType,
    }
}

fn writeAllDir(alloc: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, archive: *std.tar.Writer, seen: *std.BufSet) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                try archive.writeDir(path, .{});
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                try writeAllDir(alloc, child, path, archive, seen);
            },
            .file => {
                try noteBundlePath(seen, path);
                try writeTarFile(dir, entry.name, path, archive);
            },
            .sym_link => {
                var target_buf: [4096]u8 = undefined;
                const target = try dir.readLink(entry.name, &target_buf);
                try noteBundlePath(seen, path);
                try archive.writeLink(path, target, .{});
            },
            else => return error.UnsupportedIncludeFileType,
        }
    }
}

fn writeTarFile(dir: std.fs.Dir, source_name: []const u8, archive_path: []const u8, archive: *std.tar.Writer) !void {
    var file = try dir.openFile(source_name, .{});
    defer file.close();
    const stat = try file.stat();
    var buf: [64 * 1024]u8 = undefined;
    var reader = std.fs.File.Reader.initSize(file, &buf, stat.size);
    try archive.writeFile(archive_path, &reader, 0);
}

fn writeDirectoryTar(alloc: std.mem.Allocator, path: []const u8, writer: *std.Io.Writer, seen: *std.BufSet) !void {
    var root = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer root.close();
    var walker = try root.walk(alloc);
    defer walker.deinit();
    var archive: std.tar.Writer = .{ .underlying_writer = writer };

    while (try walker.next()) |entry| {
        // This is the source environment's completion marker. The bundle has
        // its own marker which must only be written after extraction finishes.
        if (std.mem.eql(u8, entry.path, ".taipan-ok")) continue;
        const tar_path = try alloc.dupe(u8, entry.path);
        defer alloc.free(tar_path);
        if (is_windows) std.mem.replaceScalar(u8, tar_path, '\\', '/');
        switch (entry.kind) {
            .directory => try archive.writeDir(tar_path, .{}),
            .file => {
                var file = try entry.dir.openFile(entry.basename, .{});
                defer file.close();
                const stat = try file.stat();
                var buf: [64 * 1024]u8 = undefined;
                var reader = std.fs.File.Reader.initSize(file, &buf, stat.size);
                try noteBundlePath(seen, tar_path);
                // mtime 0, not stat.mtime: the archive bytes are the bundle
                // cache key on target machines, so the same dependency set
                // must produce the same bytes across rebuilds.
                try archive.writeFile(tar_path, &reader, 0);
            },
            .sym_link => {
                var target_buf: [4096]u8 = undefined;
                const target = try entry.dir.readLink(entry.basename, &target_buf);
                try noteBundlePath(seen, tar_path);
                try archive.writeLink(tar_path, target, .{});
            },
            else => return error.UnsupportedDependencyFileType,
        }
    }
}

fn readBundleFooter(alloc: std.mem.Allocator) !?BundleFooter {
    const self_path = try std.fs.selfExePathAlloc(alloc);
    var file = try std.fs.openFileAbsolute(self_path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    if (size < bundle_footer_len) return null;

    var footer: [bundle_footer_len]u8 = undefined;
    try file.seekTo(size - bundle_footer_len);
    if (try file.readAll(&footer) != footer.len) return null;
    if (!std.mem.eql(u8, footer[0..8], bundle_magic)) return null;
    const base_len = std.mem.readInt(u64, footer[8..16], .little);
    const source_len = std.mem.readInt(u64, footer[16..24], .little);
    const deps_len = std.mem.readInt(u64, footer[24..32], .little);
    const expected = std.math.add(u64, base_len, source_len) catch return error.InvalidBundle;
    const expected_payload = std.math.add(u64, expected, deps_len) catch return error.InvalidBundle;
    const expected_size = std.math.add(u64, expected_payload, bundle_footer_len) catch return error.InvalidBundle;
    if (expected_size != size or source_len > 16 * 1024 * 1024) return error.InvalidBundle;
    return .{
        .base_len = base_len,
        .source_len = source_len,
        .deps_len = deps_len,
        .digest = footer[32..64].*,
    };
}

/// Read the payload appended to this executable, verify it against the
/// footer digest, and stage it into `dir`. Returns true when this process
/// performed the extraction (the caller should precompile), false when a
/// concurrent launch won the race.
fn extractBundle(alloc: std.mem.Allocator, footer: BundleFooter, dir: []const u8, marker: []const u8) !bool {
    const self_path = try std.fs.selfExePathAlloc(alloc);
    var file = try std.fs.openFileAbsolute(self_path, .{});
    defer file.close();
    const source = try alloc.alloc(u8, @intCast(footer.source_len));
    const archive = try alloc.alloc(u8, @intCast(footer.deps_len));
    try file.seekTo(footer.base_len);
    const intact = blk: {
        if (try file.readAll(source) != source.len) break :blk false;
        if (try file.readAll(archive) != archive.len) break :blk false;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(build_options.runtime_tag);
        hasher.update(source);
        hasher.update(archive);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        break :blk std.mem.eql(u8, &digest, &footer.digest);
    };
    if (!intact) {
        std.debug.print("taipan: this executable is corrupt (truncated or modified after `taipan build`)\n", .{});
        std.process.exit(1);
    }

    // Stage into a pid-suffixed sibling and rename into place, so a
    // concurrent first launch never observes — or deletes — a half-extracted
    // bundle. The marker is written before the rename: a directory at the
    // final path is complete by construction.
    const pid = if (is_windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ dir, pid });
    errdefer std.fs.cwd().deleteTree(tmp) catch {};
    std.fs.cwd().deleteTree(tmp) catch {};
    try std.fs.cwd().makePath(tmp);
    if (archive.len > 0) {
        var dest = try std.fs.cwd().openDir(tmp, .{});
        defer dest.close();
        try tarx.extract(dest, archive);
    }
    {
        const tmp_script = try std.fmt.allocPrint(alloc, "{s}/.taipan-main.py", .{tmp});
        var out = try std.fs.cwd().createFile(tmp_script, .{});
        defer out.close();
        try out.writeAll(source);
    }
    const tmp_marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-ok", .{tmp});
    (try std.fs.cwd().createFile(tmp_marker, .{})).close();

    std.fs.cwd().rename(tmp, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Lost the race to a concurrent launch, or a partial directory
            // from a crashed extraction is in the way. Keep a completed
            // bundle; replace anything else.
            if (std.fs.cwd().access(marker, .{})) |_| {
                std.fs.cwd().deleteTree(tmp) catch {};
                return false;
            } else |_| {}
            std.fs.cwd().deleteTree(dir) catch {};
            try std.fs.cwd().rename(tmp, dir);
        },
        else => return err,
    };
    return true;
}

/// Cache root, always with '/' separators — they work in every Windows API
/// and sidestep '\' escaping when paths are spliced into Python source.
fn cacheRoot(alloc: std.mem.Allocator) ![]const u8 {
    const root = blk: {
        if (std.process.getEnvVarOwned(alloc, "TAIPAN_CACHE")) |dir| break :blk dir else |_| {}
        if (is_windows) {
            if (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA")) |dir| {
                break :blk try std.fmt.allocPrint(alloc, "{s}/taipan", .{dir});
            } else |_| {}
        }
        const home = try std.process.getEnvVarOwned(alloc, if (is_windows) "USERPROFILE" else "HOME");
        break :blk try std.fmt.allocPrint(alloc, "{s}/.cache/taipan", .{home});
    };
    if (is_windows) {
        const w = try alloc.dupe(u8, root);
        std.mem.replaceScalar(u8, w, '\\', '/');
        return w;
    }
    return root;
}

/// Cache path for the script's compiled code object, so warm startup never
/// pays source->bytecode cost. Keyed by runtime tag + absolute script path +
/// source content: an edit or move changes the key, so entries cannot go
/// stale. Returns "" (cache disabled) if the cache dir cannot be created.
fn scriptPycPath(alloc: std.mem.Allocator, cache_root: []const u8, abs_script: []const u8, src: []const u8) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(build_options.runtime_tag);
    hasher.update("\x00");
    hasher.update(abs_script);
    hasher.update("\x00");
    hasher.update(src);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    const dir = std.fmt.allocPrint(alloc, "{s}/scripts", .{cache_root}) catch return "";
    std.fs.cwd().makePath(dir) catch return "";
    return std.fmt.allocPrint(alloc, "{s}/{s}.pyc", .{ dir, hex[0..16] }) catch "";
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
        .libpython = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, build_options.libpython_name }),
        .shim = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, build_options.shim_name }),
    };
    const marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-ok", .{dir});

    if (std.fs.cwd().access(marker, .{})) |_| {
        return rt;
    } else |_| {}

    try std.fs.cwd().makePath(dir);
    try extractFile(alloc, rt.stdlib_zip, stdlib_zip, false);
    try extractFile(alloc, rt.libpython, libpython_so, true);
    try extractFile(alloc, rt.shim, shim_so, true);
    if (is_windows) {
        var dest = try std.fs.cwd().openDir(dir, .{});
        defer dest.close();
        try tarx.extract(dest, extra_tar);
    }
    (try std.fs.cwd().createFile(marker, .{})).close();
    return rt;
}

/// Make the runtime dir look enough like an installed CPython to compile
/// against: headers where sysconfig reports the include directory, and a
/// linkable libpython under the lib directory it reports. Kept out of
/// `ensureRuntime` and given a marker of its own, because a run that installs
/// nothing should not pay for several hundred files it will never open.
fn ensureBuildFiles(alloc: std.mem.Allocator, rt: Runtime) !void {
    const dir = std.fs.path.dirname(rt.stdlib_zip).?;
    const marker = try std.fmt.allocPrint(alloc, "{s}/.taipan-build-ok", .{dir});
    if (std.fs.cwd().access(marker, .{})) |_| return else |_| {}

    var dest = try std.fs.cwd().openDir(dir, .{});
    defer dest.close();
    try tarx.extractGzip(alloc, dest, include_tar_gz);
    try linkLibPython(alloc, dir);
    (try std.fs.cwd().createFile(marker, .{})).close();
}

/// The runtime keeps libpython at its root under the versioned name the
/// dynamic loader wants (`libpython3.13.so.1.0`). A linker asked for
/// `-lpython3.13` looks for the development name instead, in the `lib` dir
/// that sysconfig advertises as LIBDIR — so put one there pointing back.
/// Extension modules need none of this: on Linux and macOS they deliberately
/// don't link libpython and resolve Py* symbols from the loaded interpreter.
/// Packages that *embed* Python (uWSGI is the common one) do link it.
fn linkLibPython(alloc: std.mem.Allocator, runtime_dir: []const u8) !void {
    // Windows links against python313.lib, an import library the runtime does
    // not carry; an embedding build there needs a real CPython install.
    if (is_windows) return;

    const lib_dir = try std.fmt.allocPrint(alloc, "{s}/lib", .{runtime_dir});
    try std.fs.cwd().makePath(lib_dir);
    const suffix = if (builtin.os.tag == .macos) "dylib" else "so";
    const link = try std.fmt.allocPrint(
        alloc,
        "{s}/libpython{s}.{s}",
        .{ lib_dir, build_options.python_version, suffix },
    );
    const target = try std.fmt.allocPrint(alloc, "../{s}", .{build_options.libpython_name});
    std.fs.cwd().symLink(target, link, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn extractFile(alloc: std.mem.Allocator, dest: []const u8, data: []const u8, executable: bool) !void {
    const pid = if (is_windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ dest, pid });
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
    if (is_windows) {
        // LoadLibrary world: dependencies resolve by base name against the
        // already-loaded module list, so preload everything the shim and any
        // wheel .pyd may import — the vcruntimes, python313.dll, and the
        // stable-ABI forwarder python3.dll (abi3 wheels link against it).
        const dir = std.fs.path.dirname(rt.shim).?;
        const preload = [_][]const u8{ "vcruntime140.dll", "vcruntime140_1.dll", "python3.dll" };
        for (preload) |name| {
            const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
            _ = std.DynLib.open(p) catch |err| {
                std.debug.print("taipan: load {s}: {s}\n", .{ p, @errorName(err) });
                return error.DlopenLibpython;
            };
        }
        _ = std.DynLib.open(rt.libpython) catch |err| {
            std.debug.print("taipan: load {s}: {s}\n", .{ rt.libpython, @errorName(err) });
            return error.DlopenLibpython;
        };
        var shim = std.DynLib.open(rt.shim) catch |err| {
            std.debug.print("taipan: load {s}: {s}\n", .{ rt.shim, @errorName(err) });
            return error.DlopenShim;
        };
        return shim.lookup(RunFileFn, "taipan_run_file") orelse error.MissingSymbol;
    }

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
fn ensureEnv(alloc: std.mem.Allocator, cache_root: []const u8, deps: []const []const u8) !EnvResult {
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

    // A package build always installs exactly one requirement, and naming it
    // beats calling a package its own dependency.
    if (deps.len == 1) {
        std.debug.print("taipan: installing {s} into cache...\n", .{deps[0]});
    } else {
        std.debug.print("taipan: installing {d} dependencies into cache...\n", .{deps.len});
    }
    installEnv(alloc, cache_root, env_dir, deps) catch |err| switch (err) {
        error.InstallFailed => std.process.exit(1),
        else => return err,
    };

    (try std.fs.cwd().createFile(marker, .{})).close();
    return .{ .dir = env_dir, .fresh = true };
}

/// Populate `env_dir` with `requirements` and everything they need, resolved
/// for the embedded interpreter rather than for any Python on this machine.
///
/// uv is pointed at this executable as the interpreter, so everything it
/// decides — the tags it resolves against, and the Python that runs a PEP 517
/// build backend when a dependency ships only an sdist — comes from the
/// CPython embedded here. Describing the target with `--python-version` alone
/// would be enough for wheels and needs no interpreter at all, but it leaves
/// uv to find its own for anything that has to be compiled: it downloads a
/// second CPython and builds against that one instead of the one that will
/// run the code.
fn installEnv(
    alloc: std.mem.Allocator,
    cache_root: []const u8,
    env_dir: []const u8,
    requirements: []const []const u8,
) !void {
    const uv = try findUv(alloc, cache_root);
    const self_path = try std.fs.selfExePathAlloc(alloc);
    // uv probes the interpreter before resolving, and a build backend needs
    // the headers. Both want the runtime on disk, which a warm start would
    // otherwise not have needed yet.
    try ensureBuildFiles(alloc, try ensureRuntime(alloc, cache_root));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        uv,                  "pip",                         "install",
        "--quiet",           "--python",                    self_path,
        "--python-platform", build_options.python_platform, "--target",
        env_dir,
    });
    try argv.appendSlice(alloc, requirements);

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    // Lets the interpreter uv spawns recognize the `-c` it is invoked with;
    // outside this it stays an ordinary argument. See `workerCommandIndex`.
    try env.put("TAIPAN_PYTHON", "1");
    // Belt and braces on top of `--python`: no interpreter is fetched,
    // whatever uv would otherwise decide. Set through the environment rather
    // than as a flag, because a uv too old to know it ignores an unrecognized
    // variable but fails on an unrecognized option.
    try env.put("UV_PYTHON_DOWNLOADS", "never");

    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .env_map = &env,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("taipan: uv failed:\n{s}\n", .{res.stderr});
        return error.InstallFailed;
    }
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

    const cached = try std.fmt.allocPrint(alloc, "{s}/bin/{s}", .{ cache_root, if (is_windows) "uv.exe" else "uv" });
    if (std.fs.cwd().access(cached, .{})) |_| return cached else |_| {}

    std.debug.print("taipan: downloading uv (one-time)...\n", .{});
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/bin", .{cache_root});
    try std.fs.cwd().makePath(bin_dir);
    // No shell: curl and tar run directly, sidestepping cmd.exe quoting.
    // Both ship with Windows 10+ (tar is bsdtar there, which reads zip).
    const url = try std.fmt.allocPrint(
        alloc,
        "https://github.com/astral-sh/uv/releases/latest/download/uv-{s}.{s}",
        .{ build_options.python_platform, if (is_windows) "zip" else "tar.gz" },
    );
    const archive = try std.fmt.allocPrint(alloc, "{s}/uv-download.tmp", .{bin_dir});
    try runQuiet(alloc, &.{ "curl", "-fsSL", url, "-o", archive });
    if (is_windows) {
        // Explicitly System32's bsdtar: a PATH `tar` may be git-bash's GNU
        // tar, which can't read zip and parses C:/... as a remote host:file.
        const sysroot = std.process.getEnvVarOwned(alloc, "SYSTEMROOT") catch
            try alloc.dupe(u8, "C:/Windows");
        const systar = try std.fmt.allocPrint(alloc, "{s}/System32/tar.exe", .{sysroot});
        try runQuiet(alloc, &.{ systar, "-xf", archive, "-C", bin_dir });
    } else {
        try runQuiet(alloc, &.{ "tar", "-xzf", archive, "-C", bin_dir, "--strip-components=1" });
    }
    std.fs.cwd().deleteFile(archive) catch {};
    if (std.fs.cwd().access(cached, .{})) |_| return cached else |_| {
        std.debug.print("taipan: uv download produced no {s}; install uv or set TAIPAN_UV.\n", .{cached});
        std.process.exit(1);
    }
}

fn runQuiet(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        std.debug.print("taipan: cannot run {s}: {s}; install uv or set TAIPAN_UV.\n", .{ argv[0], @errorName(err) });
        std.process.exit(1);
    };
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("taipan: {s} failed; install uv or set TAIPAN_UV.\n{s}\n", .{ argv[0], res.stderr });
        std.process.exit(1);
    }
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

//! Console-script discovery for `taipan build <package>`.
//!
//! Everything here is pure string work over files an installer already wrote
//! into the environment (`*.dist-info/entry_points.txt`, `pyproject.toml`), so
//! no Python has to run at build time to answer "what does this package
//! invoke?" — the same question `importlib.metadata.entry_points()` answers.

const std = @import("std");

/// One `[console_scripts]` entry of an installed distribution. `value` is kept
/// verbatim so a malformed target can be reported against the name the user
/// asked for instead of silently disappearing during parsing.
pub const EntryPoint = struct {
    /// PEP 503 normalized name of the distribution providing the script.
    dist: []const u8,
    /// Script name, i.e. what the user passes to `-e`.
    name: []const u8,
    value: []const u8,
};

/// The import target behind an entry point value: `pkg.module:func.attr`.
pub const Target = struct {
    module: []const u8,
    attr: []const u8,
};

pub const SelectError = error{
    /// The environment (or the built distribution) declares no console scripts.
    NoEntryPoints,
    /// A `-e` name that no installed distribution provides.
    EntryPointNotFound,
    /// Several candidates and no way to tell which one was meant.
    AmbiguousEntryPoint,
};

/// PEP 503 normalization: lowercase, and runs of `-`, `_`, `.` collapse to a
/// single `-`. Distribution names compare equal only after this.
pub fn normalizeName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_sep = false;
    for (name) |c| {
        if (c == '-' or c == '_' or c == '.') {
            if (!prev_sep) try out.append(alloc, '-');
            prev_sep = true;
        } else {
            try out.append(alloc, std.ascii.toLower(c));
            prev_sep = false;
        }
    }
    return out.items;
}

/// Normalized distribution name of a `<name>-<version>.dist-info` directory,
/// or null for any other directory.
pub fn distFromDistInfo(alloc: std.mem.Allocator, dir_name: []const u8) !?[]u8 {
    const suffix = ".dist-info";
    if (!std.mem.endsWith(u8, dir_name, suffix)) return null;
    const stem = dir_name[0 .. dir_name.len - suffix.len];
    // `<name>-<version>`: the version never contains `-`, the escaped name may.
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    if (dash == 0) return null;
    return try normalizeName(alloc, stem[0..dash]);
}

/// Normalized distribution name of a requirement spec — `omniload==0.7.0`,
/// `omniload[cli]>=1`, `omniload @ https://...` all name `omniload`.
pub fn requirementName(alloc: std.mem.Allocator, spec: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t");
    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) switch (trimmed[end]) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.' => {},
        else => break,
    };
    if (end == 0) return null;
    return try normalizeName(alloc, trimmed[0..end]);
}

/// Append the `[console_scripts]` entries of one `entry_points.txt` to `out`.
/// `dist` is borrowed by every entry produced, as are slices of `text`.
pub fn parseEntryPoints(
    alloc: std.mem.Allocator,
    dist: []const u8,
    text: []const u8,
    out: *std.ArrayList(EntryPoint),
) !void {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            in_section = std.mem.eql(u8, line, "[console_scripts]");
            continue;
        }
        if (!in_section) continue;
        // These files are read with configparser, which splits on the first
        // `=` or `:` — and the value itself contains a `:`.
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse line.len;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const split = @min(eq, colon);
        if (split == line.len) continue;
        const name = std.mem.trim(u8, line[0..split], " \t");
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");
        if (name.len == 0 or value.len == 0) continue;
        try out.append(alloc, .{ .dist = dist, .name = name, .value = value });
    }
}

/// Split an entry point value into its import target. Returns null when the
/// value is not `module:attr` with dotted-identifier halves — which also makes
/// both halves safe to interpolate into generated Python source.
pub fn parseTarget(value: []const u8) ?Target {
    // `module:attr [extra1,extra2]`: extras only affect installation.
    var v = value;
    if (std.mem.indexOfScalar(u8, v, '[')) |i| v = v[0..i];
    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return null;
    const module = std.mem.trim(u8, v[0..colon], " \t");
    const attr = std.mem.trim(u8, v[colon + 1 ..], " \t");
    if (!isDottedName(module) or !isDottedName(attr)) return null;
    return .{ .module = module, .attr = attr };
}

fn isDottedName(s: []const u8) bool {
    if (s.len == 0) return false;
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part, 0..) |c, i| switch (c) {
            'A'...'Z', 'a'...'z', '_' => {},
            '0'...'9' => if (i == 0) return false,
            else => return false,
        };
    }
    return true;
}

/// Pick the console script to build. `target_dist` is the normalized name of
/// the distribution being packaged, when it could be determined; entries from
/// its dependencies are then only considered as a fallback.
pub fn select(
    entries: []const EntryPoint,
    target_dist: ?[]const u8,
    requested: ?[]const u8,
) SelectError!EntryPoint {
    if (requested) |want| {
        var matches: usize = 0;
        var first: ?EntryPoint = null;
        for (entries) |e| {
            if (!std.mem.eql(u8, e.name, want)) continue;
            // A dependency may ship a script of the same name; the package
            // being built wins outright.
            if (target_dist) |d| if (std.mem.eql(u8, e.dist, d)) return e;
            matches += 1;
            if (first == null) first = e;
        }
        if (matches == 0) return error.EntryPointNotFound;
        if (matches > 1) return error.AmbiguousEntryPoint;
        return first.?;
    }

    // No name given: the package being built must name itself unambiguously.
    // Nothing can win outright here, so a second match is already ambiguous.
    var only: ?EntryPoint = null;
    for (entries) |e| {
        if (target_dist) |d| if (!std.mem.eql(u8, e.dist, d)) continue;
        if (only != null) return error.AmbiguousEntryPoint;
        only = e;
    }
    return only orelse error.NoEntryPoints;
}

/// The `__main__` module a built package executable runs: the same import,
/// getattr walk and `sys.exit(...)` a pip-installed console script wrapper
/// would perform.
pub fn generateMain(alloc: std.mem.Allocator, name: []const u8, target: Target) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\# Generated by `taipan build` for the console script {s} ({s}:{s}).
        \\import sys
        \\
        \\
        \\def _taipan_console_script():
        \\    from importlib import import_module
        \\
        \\    target = import_module("{s}")
        \\    for _attr in "{s}".split("."):
        \\        target = getattr(target, _attr)
        \\    return target()
        \\
        \\
        \\if __name__ == "__main__":
        \\    sys.exit(_taipan_console_script())
        \\
    , .{ name, target.module, target.attr, target.module, target.attr });
}

/// Normalized `name` from a pyproject.toml `[project]` table, when it is
/// declared as a plain string there. Used only to recognize which installed
/// distribution is the one being built.
pub fn projectName(alloc: std.mem.Allocator, toml: []const u8) !?[]u8 {
    var in_project = false;
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_project = std.mem.eql(u8, line, "[project]");
            continue;
        }
        if (!in_project) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "name")) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len < 2) return null;
        const quote = value[0];
        if (quote != '"' and quote != '\'') return null;
        const end = std.mem.indexOfScalarPos(u8, value, 1, quote) orelse return null;
        return try normalizeName(alloc, value[1..end]);
    }
    return null;
}

const testing = std.testing;

test "PEP 503 name normalization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("omniload", try normalizeName(alloc, "OmniLoad"));
    try testing.expectEqualStrings("ruamel-yaml", try normalizeName(alloc, "ruamel.yaml"));
    try testing.expectEqualStrings("zope-interface", try normalizeName(alloc, "zope___Interface"));
}

test "distribution name from a dist-info directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("omniload", (try distFromDistInfo(alloc, "omniload-0.7.0.dist-info")).?);
    try testing.expectEqualStrings("typing-extensions", (try distFromDistInfo(alloc, "typing_extensions-4.12.2.dist-info")).?);
    try testing.expectEqual(@as(?[]u8, null), try distFromDistInfo(alloc, "omniload"));
    try testing.expectEqual(@as(?[]u8, null), try distFromDistInfo(alloc, "noversion.dist-info"));
}

test "distribution name from a requirement spec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("omniload", (try requirementName(alloc, "omniload==0.7.0")).?);
    try testing.expectEqualStrings("omniload", (try requirementName(alloc, "OmniLoad[cli] >= 1.0")).?);
    try testing.expectEqualStrings("omniload", (try requirementName(alloc, "omniload @ https://example.invalid/o.whl")).?);
    try testing.expectEqual(@as(?[]u8, null), try requirementName(alloc, "  "));
}

fn parseAll(alloc: std.mem.Allocator, dist: []const u8, text: []const u8) ![]EntryPoint {
    var out: std.ArrayList(EntryPoint) = .empty;
    try parseEntryPoints(alloc, dist, text, &out);
    return out.items;
}

test "console scripts are read, other groups ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const eps = try parseAll(arena.allocator(), "omniload",
        \\[console_scripts]
        \\omniload = omniload.main:main
        \\ol = omniload.main:short
        \\
        \\[gui_scripts]
        \\omniload-gui = omniload.gui:main
        \\
        \\[pytest11]
        \\omniload = omniload.plugin
    );
    try testing.expectEqual(@as(usize, 2), eps.len);
    try testing.expectEqualStrings("omniload", eps[0].name);
    try testing.expectEqualStrings("omniload.main:main", eps[0].value);
    try testing.expectEqualStrings("ol", eps[1].name);
}

test "colon delimiter, comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const eps = try parseAll(arena.allocator(), "d",
        \\# a comment
        \\[console_scripts]
        \\; another comment
        \\omniload: omniload.main:main
        \\
    );
    try testing.expectEqual(@as(usize, 1), eps.len);
    try testing.expectEqualStrings("omniload.main:main", eps[0].value);
}

test "entry point targets" {
    try testing.expectEqualStrings("omniload.main", parseTarget("omniload.main:main").?.module);
    try testing.expectEqualStrings("main", parseTarget("omniload.main:main").?.attr);
    try testing.expectEqualStrings("app.cli", parseTarget("pkg:app.cli [extra]").?.attr);
    try testing.expectEqual(@as(?Target, null), parseTarget("omniload.main"));
    try testing.expectEqual(@as(?Target, null), parseTarget("omniload.main:"));
    try testing.expectEqual(@as(?Target, null), parseTarget("os:system; import x"));
    try testing.expectEqual(@as(?Target, null), parseTarget("pkg:2bad"));
}

test "selection prefers the packaged distribution" {
    const entries = [_]EntryPoint{
        .{ .dist = "omniload", .name = "omniload", .value = "omniload.main:main" },
        .{ .dist = "rich", .name = "omniload", .value = "rich.impostor:main" },
        .{ .dist = "rich", .name = "rich", .value = "rich.__main__:main" },
    };
    try testing.expectEqualStrings("omniload.main:main", (try select(&entries, "omniload", "omniload")).value);
    try testing.expectEqualStrings("omniload.main:main", (try select(&entries, "omniload", null)).value);
    try testing.expectEqualStrings("rich.__main__:main", (try select(&entries, "omniload", "rich")).value);
    try testing.expectError(error.EntryPointNotFound, select(&entries, "omniload", "nope"));
    try testing.expectError(error.AmbiguousEntryPoint, select(&entries, null, "omniload"));
    try testing.expectError(error.AmbiguousEntryPoint, select(&entries, null, null));
    try testing.expectError(error.NoEntryPoints, select(&entries, "typer", null));
    try testing.expectError(error.NoEntryPoints, select(&.{}, null, null));
}

test "generated main imports and calls the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = try generateMain(arena.allocator(), "omniload", .{ .module = "omniload.main", .attr = "main" });
    try testing.expect(std.mem.indexOf(u8, src, "import_module(\"omniload.main\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"main\".split(\".\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "sys.exit(_taipan_console_script())") != null);
}

test "project name from pyproject.toml" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("omniload", (try projectName(alloc,
        \\[build-system]
        \\requires = ["hatchling"]
        \\
        \\[project]
        \\name = "OmniLoad"
        \\version = "0.7.0"
    )).?);
    // A `name` outside `[project]` is somebody else's key.
    try testing.expectEqual(@as(?[]u8, null), try projectName(alloc,
        \\[tool.poetry]
        \\name = "omniload"
    ));
    try testing.expectEqual(@as(?[]u8, null), try projectName(alloc,
        \\[project]
        \\dynamic = ["name"]
    ));
}

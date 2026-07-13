const std = @import("std");

/// Extract the dependency list from a PEP 723 `# /// script` block.
/// Minimal on purpose: finds `dependencies = [ ... ]` (may span lines) and
/// pulls out the quoted strings. Not a TOML parser.
pub fn parseDeps(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var toml: std.ArrayList(u8) = .empty;
    var in_block = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (!in_block) {
            if (std.mem.eql(u8, line, "# /// script")) in_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, "# ///")) break;
        if (!std.mem.startsWith(u8, line, "#")) break;
        var content = line[1..];
        if (std.mem.startsWith(u8, content, " ")) content = content[1..];
        try toml.appendSlice(alloc, content);
        try toml.append(alloc, '\n');
    }

    const t = toml.items;
    const key_pos = std.mem.indexOf(u8, t, "dependencies") orelse return &.{};
    const open = std.mem.indexOfScalarPos(u8, t, key_pos, '[') orelse return &.{};
    const close = std.mem.indexOfScalarPos(u8, t, open, ']') orelse return &.{};

    var deps: std.ArrayList([]const u8) = .empty;
    var i = open + 1;
    while (i < close) {
        const ch = t[i];
        if (ch == '"' or ch == '\'') {
            const end = std.mem.indexOfScalarPos(u8, t, i + 1, ch) orelse break;
            try deps.append(alloc, try alloc.dupe(u8, t[i + 1 .. end]));
            i = end + 1;
        } else {
            i += 1;
        }
    }
    return deps.items;
}

const testing = std.testing;

fn expectDeps(src: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deps = try parseDeps(arena.allocator(), src);
    try testing.expectEqual(expected.len, deps.len);
    for (expected, deps) |e, d| try testing.expectEqualStrings(e, d);
}

test "single dependency" {
    try expectDeps(
        \\# /// script
        \\# dependencies = ["cowsay"]
        \\# ///
        \\import cowsay
    , &.{"cowsay"});
}

test "multi-line, mixed quotes, versions" {
    try expectDeps(
        \\#!/usr/bin/env taipan
        \\# /// script
        \\# requires-python = ">=3.12"
        \\# dependencies = [
        \\#     "requests>=2.31",
        \\#     'rich',
        \\# ]
        \\# ///
    , &.{ "requests>=2.31", "rich" });
}

test "no block" {
    try expectDeps("print('hi')\n", &.{});
}

test "block without dependencies key" {
    try expectDeps(
        \\# /// script
        \\# requires-python = ">=3.12"
        \\# ///
    , &.{});
}

test "empty dependency list" {
    try expectDeps(
        \\# /// script
        \\# dependencies = []
        \\# ///
    , &.{});
}

test "malformed block (no closing fence) still terminates" {
    try expectDeps(
        \\# /// script
        \\# dependencies = ["a"]
        \\import os
    , &.{"a"});
}

test "requires-python is not mistaken for deps" {
    try expectDeps(
        \\# /// script
        \\# dependencies = ["b"]
        \\# requires-python = ">=3.12"
        \\# ///
    , &.{"b"});
}

test "crlf line endings" {
    try expectDeps("# /// script\r\n# dependencies = [\"x\"]\r\n# ///\r\n", &.{"x"});
}

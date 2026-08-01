const std = @import("std");

/// Extract an in-memory tar archive into `dir`. Used on Windows to unpack
/// the embedded DLLs payload into the runtime cache.
pub fn extract(dir: std.fs.Dir, bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    try std.tar.pipeToFileSystem(dir, &reader, .{});
}

/// As `extract`, for a gzip-compressed archive. Used for the CPython headers,
/// which compress ~6:1 and are unpacked only when something has to be built
/// from source.
pub fn extractGzip(alloc: std.mem.Allocator, dir: std.fs.Dir, bytes: []const u8) !void {
    var input: std.Io.Reader = .fixed(bytes);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, window);
    try std.tar.pipeToFileSystem(dir, &decompress.reader, .{});
}

test "extract writes nested files" {
    const sample = @embedFile("testdata/sample.tar");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try extract(tmp.dir, sample);
    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "DLLs/hello.txt", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("taipan\n", content);
}

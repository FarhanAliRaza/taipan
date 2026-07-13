const std = @import("std");

/// Extract an in-memory tar archive into `dir`. Used on Windows to unpack
/// the embedded DLLs payload into the runtime cache.
pub fn extract(dir: std.fs.Dir, bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    try std.tar.pipeToFileSystem(dir, &reader, .{});
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

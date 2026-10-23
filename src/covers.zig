//! Pictures of book covers: downloaded once into a cache on the reader, then drawn.

const std = @import("std");
const pb = @import("c");

const net = @import("net.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;

/// Inside the system folder, which the library does not scan for books
const cache_parent = "/mnt/ext1/system/cache";
const cache_dir = cache_parent ++ "/opds-connector";

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// The file the picture at `url` is kept in
pub fn cachePath(buf: []u8, url: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{x:0>16}.img", .{ cache_dir, std.hash.Wyhash.hash(0, url) }, 0);
}

/// Whether the picture at `url` is in the cache
pub fn isCached(url: []const u8) bool {
    var buf: [128]u8 = undefined;
    const path = cachePath(&buf, url) catch return false;
    return std.c.access(path.ptr, 0) == 0;
}

/// Downloads the picture at `url` into the cache, unless it is there already
pub fn fetch(url: [:0]const u8) !void {
    if (isCached(url)) return;
    _ = mkdir(cache_parent, 0o755);
    _ = mkdir(cache_dir, 0o755);

    var buf: [128]u8 = undefined;
    const path = try cachePath(&buf, url);
    const name = path[cache_dir.len + 1 ..];
    // Under a temporary name, so a download cut short is never taken for a picture
    var part_buf: [64]u8 = undefined;
    const part = try std.fmt.bufPrint(&part_buf, "{s}.part", .{name});
    try net.download(url, cache_dir, part, null);

    var from_buf: [128]u8 = undefined;
    const from = try std.fmt.bufPrintSentinel(&from_buf, "{s}/{s}", .{ cache_dir, part }, 0);
    if (std.c.rename(from.ptr, path.ptr) != 0) {
        _ = std.c.unlink(from.ptr);
        return error.CannotWriteFile;
    }
}

/// The cached picture at `url`, fitted into `width` x `height`, null if it is not in the cache
/// or cannot be read. Free it with `free`.
pub fn load(url: []const u8, width: c_int, height: c_int) ?*pb.ibitmap {
    var buf: [128]u8 = undefined;
    const path = cachePath(&buf, url) catch return null;
    if (std.c.access(path.ptr, 0) != 0) return null;

    const full = pb.LoadImageToFormat(path.ptr, pb.kFmtRGB24) orelse {
        trace("cover {s} cannot be read\n", .{path});
        // Not a picture, e.g. an error page: not tried again and again
        _ = std.c.unlink(path.ptr);
        return null;
    };
    defer free(full);
    return pb.BitmapStretchProportionally(full, width, height);
}

pub fn free(bitmap: *pb.ibitmap) void {
    std.c.free(bitmap);
}

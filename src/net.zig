const builtin = @import("builtin");
const std = @import("std");
const curl = @import("libcurl.zig");

const USER_AGENT = "pb-opds-connector/0.1.0";

/// Called while a download runs, with the bytes received so far and the total
/// or 0 if the server does not say.
pub const ProgressFn = *const fn (downloaded: u64, total: u64) void;

var currentProgress: ?ProgressFn = null;

const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
};

/// Target is used to decide if a response should be hold in memory
/// or if it should be streamed into a file.
/// This distinction is made between fetching a feed file (XML) or store an
/// ebook file physically on disk.
const Target = union(enum) {
    memory: *Buffer,
    file: *std.c.FILE,
};

fn curlWriteBuffer(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const buffer: *Buffer = @ptrCast(@alignCast(userdata));
    const len = size * nmemb;
    // Returning less than len makes curl abort the transfer
    buffer.bytes.appendSlice(buffer.allocator, ptr[0..len]) catch return 0;
    return len;
}

fn curlProgress(_: ?*anyopaque, dltotal: i64, dlnow: i64, _: i64, _: i64) callconv(.c) c_int {
    if (currentProgress) |report| report(@intCast(@max(dlnow, 0)), @intCast(@max(dltotal, 0)));
    // Anything but 0 aborts the transfer
    return 0;
}

fn perform(url: [:0]const u8, target: Target) !void {
    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, USER_AGENT);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 120));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    // Treat HTTP 4xx/5xx as an error instead of handing the error page to the caller
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FAILONERROR, @as(c_long, 1));

    switch (target) {
        .memory => |buffer| {
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, &curlWriteBuffer);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, buffer);
        },
        // Without a write function curl writes to the C file itself
        .file => |file| _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, file),
    }

    if (currentProgress != null) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_XFERINFOFUNCTION, &curlProgress);
    }

    if (builtin.mode == .debug) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_VERBOSE, @as(c_long, 1));
    }

    if (curl.curl_easy_perform(handle) != curl.CURLE_OK) {
        return error.RequestFailed;
    }
}

/// Fetch loads data coming from a URL into memory.
/// It shares the general settings like User-Agent and more with the `download`
/// function.
pub fn fetch(allocator: std.mem.Allocator, url: [:0]const u8) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    errdefer buffer.bytes.deinit(allocator);

    try perform(url, .{ .memory = &buffer });

    return buffer.bytes.toOwnedSlice(allocator);
}

/// Download streams the data from an URL into a file.
/// It shares the general settings like User-Agent and more with the `fetch`
/// function.
pub fn download(url: [:0]const u8, targetDir: []const u8, filename: []const u8, on_progress: ?ProgressFn) !void {
    currentProgress = on_progress;
    defer currentProgress = null;

    var pathBuf: [384]u8 = undefined;
    const targetPath = try std.fmt.bufPrintSentinel(&pathBuf, "{s}/{s}", .{ targetDir, filename }, 0);

    const fh = std.c.fopen(targetPath.ptr, "wb") orelse return error.CannotOpenFileForWriting;

    perform(url, .{ .file = fh }) catch |err| {
        _ = std.c.fclose(fh);
        _ = std.c.unlink(targetPath.ptr);
        return err;
    };

    if (std.c.fclose(fh) != 0) {
        _ = std.c.unlink(targetPath.ptr);
        return error.CannotWriteFile;
    }
}

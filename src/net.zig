const builtin = @import("builtin");
const std = @import("std");
const curl = @import("libcurl.zig");
const Server = @import("server.zig").Server;
const Failure = @import("failure.zig").Failure;

const user_agent = "pb-opds-connector/" ++ @import("build_options").version;

// For catalogs behind Cloudflare, as the original app does: a browser's identity and
// accepted types, HTTP/1.1 and the common TLS curves (see Server.Options.use_http_11)
const browser_user_agent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";
const browser_accept = "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
const ec_curves = "X25519:P-256";

/// The server the user is browsing
var server: ?Server = null;

/// Called while a download runs, with the bytes received so far and the total
/// or 0 if the server does not say.
pub const ProgressFn = *const fn (downloaded: u64, total: u64) void;

var current_progress: ?ProgressFn = null;

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

/// Seconds to wait for a connection, unless the server sets its own
const default_connect_timeout = 5;

/// Why the last request failed, see `lastFailure`
var failure: Failure = .{};
var failure_text: [curl.CURL_ERROR_SIZE]u8 = undefined;

/// Describes why the last request ended in error.RequestFailed
pub fn lastFailure(buf: []u8) []const u8 {
    return failure.describe(buf);
}

/// The server the user is browsing, null on the start screen
pub fn currentServer() ?Server {
    return server;
}

pub fn useServer(new_server: ?Server) void {
    server = new_server;
}

fn curlWriteBuffer(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const buffer: *Buffer = @ptrCast(@alignCast(userdata));
    const len = size * nmemb;
    // Returning less than len makes curl abort the transfer
    buffer.bytes.appendSlice(buffer.allocator, ptr[0..len]) catch return 0;
    return len;
}

fn curlProgress(_: ?*anyopaque, dltotal: i64, dlnow: i64, _: i64, _: i64) callconv(.c) c_int {
    if (current_progress) |report| report(@intCast(@max(dlnow, 0)), @intCast(@max(dltotal, 0)));
    // Anything but 0 aborts the transfer
    return 0;
}

fn perform(url: [:0]const u8, target: Target) !void {
    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    const as_browser = if (server) |s| s.options.use_http_11 else false;
    var headers: ?*curl.curl_slist = null;
    defer curl.curl_slist_free_all(headers);
    if (as_browser) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, browser_user_agent);
        headers = curl.curl_slist_append(null, browser_accept);
        if (headers != null) _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTP_VERSION, curl.CURL_HTTP_VERSION_1_1);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_SSL_EC_CURVES, ec_curves);
    } else {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, user_agent);
    }
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 120));
    const connect_timeout: c_long = if (server) |s| (if (s.options.timeout > 0) s.options.timeout else default_connect_timeout) else default_connect_timeout;
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT, connect_timeout);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    // Treat HTTP 4xx/5xx as an error instead of handing the error page to the caller
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FAILONERROR, @as(c_long, 1));

    if (server) |s| {
        if (s.hasLogin() and s.owns(url)) {
            var buf: [160]u8 = undefined;
            if (s.userpwd(&buf)) |userpwd| {
                // See Server.Options.calibre_web
                const auth = if (s.options.calibre_web) curl.CURLAUTH_BASIC else curl.CURLAUTH_ANY;
                _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPAUTH, auth);
                _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERPWD, userpwd.ptr);
            } else |_| {}
        }
    }

    switch (target) {
        .memory => |buffer| {
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, &curlWriteBuffer);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, buffer);
        },
        // Without a write function curl writes to the C file itself
        .file => |file| _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, file),
    }

    if (current_progress != null) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_XFERINFOFUNCTION, &curlProgress);
    }

    if (builtin.mode == .debug) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_VERBOSE, @as(c_long, 1));
    }

    var error_buf = std.mem.zeroes([curl.CURL_ERROR_SIZE]u8);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_ERRORBUFFER, &error_buf);

    const code = curl.curl_easy_perform(handle);
    if (code != curl.CURLE_OK) {
        var status: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, curl.CURLINFO_RESPONSE_CODE, &status);
        // The buffer goes away with this function, keep its text
        const text = std.mem.sliceTo(&error_buf, 0);
        @memcpy(failure_text[0..text.len], text);
        failure = .{ .http_status = status, .curl_text = failure_text[0..text.len], .curl_code = code };
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
pub fn download(url: [:0]const u8, target_dir: []const u8, filename: []const u8, on_progress: ?ProgressFn) !void {
    current_progress = on_progress;
    defer current_progress = null;

    var path_buf: [384]u8 = undefined;
    const target_path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ target_dir, filename }, 0);

    const fh = std.c.fopen(target_path.ptr, "wb") orelse return error.CannotOpenFileForWriting;

    perform(url, .{ .file = fh }) catch |err| {
        _ = std.c.fclose(fh);
        _ = std.c.unlink(target_path.ptr);
        return err;
    };

    if (std.c.fclose(fh) != 0) {
        _ = std.c.unlink(target_path.ptr);
        return error.CannotWriteFile;
    }
}

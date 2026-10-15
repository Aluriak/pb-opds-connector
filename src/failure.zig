//! Why a request failed, in words the user can act on.

const std = @import("std");

/// What is known about the last failed request
pub const Failure = struct {
    /// The HTTP status the server answered with, 0 if there was no answer
    http_status: c_long = 0,
    /// curl's own description of what went wrong, may be empty
    curl_text: []const u8 = "",
    /// curl's error code
    curl_code: c_int = 0,

    pub fn describe(failure: Failure, buf: []u8) []const u8 {
        const text = switch (failure.http_status) {
            0 => if (failure.curl_text.len > 0)
                std.fmt.bufPrint(buf, "{s}", .{failure.curl_text})
            else
                std.fmt.bufPrint(buf, "curl error {d}", .{failure.curl_code}),
            401, 403 => std.fmt.bufPrint(buf, "The server refused the login (HTTP {d}). Check the user name and password.", .{failure.http_status}),
            404 => std.fmt.bufPrint(buf, "Nothing found at this address (HTTP 404). Check the URL.", .{}),
            else => std.fmt.bufPrint(buf, "The server answered with an error (HTTP {d}).", .{failure.http_status}),
        };
        return text catch buf;
    }
};

fn expectDescription(expected: []const u8, failure: Failure) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, failure.describe(&buf));
}

test "describe names a refused login" {
    try expectDescription("The server refused the login (HTTP 401). Check the user name and password.", .{ .http_status = 401, .curl_code = 22 });
}

test "describe names a wrong address" {
    try expectDescription("Nothing found at this address (HTTP 404). Check the URL.", .{ .http_status = 404, .curl_code = 22 });
}

test "describe gives other HTTP errors with their status" {
    try expectDescription("The server answered with an error (HTTP 502).", .{ .http_status = 502, .curl_code = 22 });
}

test "describe passes on what curl says when the server did not answer" {
    try expectDescription("Failed to connect to 192.168.1.20 port 8083: Connection refused", .{ .curl_text = "Failed to connect to 192.168.1.20 port 8083: Connection refused", .curl_code = 7 });
}

test "describe falls back to the curl error code" {
    try expectDescription("curl error 28", .{ .curl_code = 28 });
}

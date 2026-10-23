const std = @import("std");
const HostName = std.Io.net.HostName;

/// The catalogs, aka OPDS servers
pub const Catalogs = struct {
    servers: std.ArrayList(Server) = .empty,

    /// Written into the configuration on the first start. From then on they are
    /// ordinary entries the user can edit or delete.
    pub const defaults = [_]struct { name: []const u8, url: []const u8 }{
        .{ .name = "Flibusta", .url = "http://flibusta.is/opds" },
        .{ .name = "Standard Ebooks (new releases)", .url = "https://standardebooks.org/feeds/atom/new-releases" },
        .{ .name = "ManyBooks", .url = "https://manybooks.net/opds/index.php" },
        .{ .name = "Project Gutenberg", .url = "https://www.gutenberg.org/ebooks.opds/" },
    };
};

pub const Server = struct {
    name: [:0]const u8,
    url: [:0]const u8,
    user: [:0]const u8 = "",
    password: [:0]const u8 = "",
    options: Options = .{},

    pub const Options = struct {
        /// Send the login right away. Without it curl first asks without one to learn the
        /// method, which Calibre-Web counts as a failed login (three a minute are allowed).
        calibre_web: bool = false,
        /// Seconds to wait for the connection to the server, 0 for the default
        timeout: u16 = 0,
        /// Lists of the catalog get a "Synchronize" row, which downloads all their books
        /// that are not on the reader yet
        sync: bool = false,
        /// Lists of books show the covers the catalog gives
        covers: bool = true,
    };

    /// Creates a server from what the user entered. This is the only place the address of a
    /// server is set: what was typed becomes the address of its catalog, with "http://" added
    /// when no scheme is given and the usual "/opds" path when there is none. An address with
    /// a path is kept as it was typed.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, address: []const u8, user: []const u8, password: []const u8, options: Options) !Server {
        const s_name = try allocator.dupeSentinel(u8, std.mem.trim(u8, name, " "), 0);
        errdefer allocator.free(s_name);

        const s_address = std.mem.trim(u8, address, " \t\r\n");
        const scheme = if (std.mem.indexOf(u8, s_address, "://") == null) "http://" else "";
        const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ scheme, s_address });
        defer allocator.free(full);

        const uri = std.Uri.parse(full) catch return error.InvalidAddress;
        const host = uri.host orelse return error.InvalidAddress;
        HostName.validate(host.percent_encoded) catch return error.InvalidAddress;

        const has_path = uri.path.percent_encoded.len > 1;
        const s_url = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{
            if (has_path) full else std.mem.trimEnd(u8, full, "/"),
            if (has_path) "" else "/opds",
        }, 0);
        errdefer allocator.free(s_url);

        const s_user = try allocator.dupeSentinel(u8, std.mem.trim(u8, user, " "), 0);
        errdefer allocator.free(s_user);
        // A password without a user name is of no use
        const s_password = try allocator.dupeSentinel(u8, if (s_user.len == 0) "" else password, 0);

        return .{ .name = s_name, .url = s_url, .user = s_user, .password = s_password, .options = options };
    }

    pub fn free(server: Server, allocator: std.mem.Allocator) void {
        allocator.free(server.name);
        allocator.free(server.url);
        allocator.free(server.user);
        allocator.free(server.password);
    }

    pub fn hasLogin(server: Server) bool {
        return server.user.len > 0;
    }

    /// Whether `url` points to this server. Feeds may link to other servers,
    /// and those must not see the password.
    pub fn owns(server: Server, url: []const u8) bool {
        const own = std.Uri.parse(server.url) catch return false;
        const other = std.Uri.parse(url) catch return false;
        const own_host = own.host orelse return false;
        const other_host = other.host orelse return false;

        return std.ascii.eqlIgnoreCase(own.scheme, other.scheme) and
            std.ascii.eqlIgnoreCase(own_host.percent_encoded, other_host.percent_encoded);
    }

    /// The login the way curl takes it: "user:password"
    pub fn userpwd(server: Server, buf: []u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}:{s}", .{ server.user, server.password }, 0);
    }
};

fn expectUrl(expected: []const u8, address: []const u8) !void {
    const server: Server = try .init(std.testing.allocator, "Test", address, "", "", .{});
    defer server.free(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, server.url);
}

test "init adds scheme and catalog path to a bare server" {
    try expectUrl("http://192.168.1.20:8080/opds", "192.168.1.20:8080");
    try expectUrl("http://calibre.lan/opds", "calibre.lan");
    try expectUrl("http://calibre.lan/opds", "  calibre.lan/ ");
}

test "init keeps a scheme the user typed" {
    try expectUrl("https://books.example.org/opds", "https://books.example.org");
    try expectUrl("https://books.example.org/opds", "https://books.example.org/");
}

test "init keeps a trailing slash after a path" {
    try expectUrl("http://calibre-web.lan:8083/opds/", "calibre-web.lan:8083/opds/");
    try expectUrl("https://example.org/calibre-web/opds/shelf/20", "https://example.org/calibre-web/opds/shelf/20");
}

test "init keeps the options" {
    const server: Server = try .init(std.testing.allocator, "Test", "calibre.lan", "", "", .{ .calibre_web = true, .timeout = 30 });
    defer server.free(std.testing.allocator);
    try std.testing.expect(server.options.calibre_web);
    try std.testing.expectEqual(30, server.options.timeout);
}

test "init keeps a path the user typed" {
    try expectUrl("http://calibre.lan:8080/opds", "calibre.lan:8080/opds");
    try expectUrl("https://example.org/calibre/opds/", "https://example.org/calibre/opds/");
    try expectUrl("http://example.org/feed.xml", "example.org/feed.xml");
}

test "init leaves an address it produced itself unchanged" {
    try expectUrl("http://192.168.1.20:8080/opds", "http://192.168.1.20:8080/opds");
    try expectUrl("http://192.168.1.20:8083/opds/", "http://192.168.1.20:8083/opds/");
}

test "init leaves the default catalogs unchanged" {
    for (Catalogs.defaults) |default| try expectUrl(default.url, default.url);
}

test "init trims name and user name and copies everything" {
    var name = "  My Calibre ".*;
    const server: Server = try .init(std.testing.allocator, &name, "calibre.lan", " alice ", "secret", .{});
    defer server.free(std.testing.allocator);
    // The server must not point into what it was created from
    @memset(&name, 'x');

    try std.testing.expectEqualStrings("My Calibre", server.name);
    try std.testing.expectEqualStrings("alice", server.user);
    try std.testing.expectEqualStrings("secret", server.password);
    try std.testing.expect(server.hasLogin());
}

test "init drops a password that comes without a user name" {
    const server: Server = try .init(std.testing.allocator, "Test", "calibre.lan", "  ", "secret", .{});
    defer server.free(std.testing.allocator);

    try std.testing.expectEqualStrings("", server.password);
    try std.testing.expect(!server.hasLogin());
}

test "owns compares the server, not the path" {
    const server: Server = .{ .name = "Test", .url = "http://calibre.lan:8080/opds" };

    try std.testing.expect(server.owns("http://calibre.lan:8080/get/epub/12"));
    try std.testing.expect(server.owns("http://Calibre.LAN:8080/opds/new?x=1"));
    try std.testing.expect(server.owns("http://user:secret@calibre.lan:8080/a"));
}

test "owns tells other servers apart" {
    const server: Server = .{ .name = "Test", .url = "http://calibre.lan/opds" };

    try std.testing.expect(!server.owns("http://evil.example/calibre.lan/opds"));
    try std.testing.expect(!server.owns("http://calibre.lan.evil.example/opds"));
    try std.testing.expect(!server.owns("not an address"));
    try std.testing.expect(!server.owns("https://calibre.lan/opds"));
}

test "init refuses what is not an address" {
    try std.testing.expectError(error.InvalidAddress, Server.init(std.testing.allocator, "Test", "calibre.lan:port", "", "", .{}));
    try std.testing.expectError(error.InvalidAddress, Server.init(std.testing.allocator, "Test", "http://", "", "", .{}));
    try std.testing.expectError(error.InvalidAddress, Server.init(std.testing.allocator, "Test", "this is wrong", "", "", .{}));
    try std.testing.expectError(error.InvalidAddress, Server.init(std.testing.allocator, "Test", "calibre_lan", "", "", .{}));
}

test "userpwd joins user name and password for curl" {
    var buf: [64]u8 = undefined;
    const server: Server = .{ .name = "Test", .url = "http://calibre.lan/opds", .user = "alice", .password = "s3cret" };

    try std.testing.expectEqualStrings("alice:s3cret", try server.userpwd(&buf));
}

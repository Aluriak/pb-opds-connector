const std = @import("std");
const pb = @import("c");

const Server = @import("server.zig").Server;
const Field = enum { name, url, user, password, use_http_11 };

/// PocketBooks location for storing configuration of applications.
pub const config_path = "/mnt/ext1/system/config/opds-connector.cfg";

/// Settings are stored as "server.<index>.<field>"
fn key(buf: *[32]u8, index: usize, field: Field) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, "server.{d}.{s}", .{ index, @tagName(field) }, 0) catch unreachable).ptr;
}

/// Load the configuration
pub fn load(allocator: std.mem.Allocator, servers: *std.ArrayList(Server)) !void {
    const config = pb.OpenConfig(config_path, null) orelse return;
    defer pb.CloseConfigNoSave(config);

    var i: usize = 0;
    while (true) : (i += 1) {
        var buf: [32]u8 = undefined;
        // The first index without an address is the end of the list
        if (pb.ReadString(config, key(&buf, i, .url), "")[0] == 0) break;
        const server = Server.init(
            allocator,
            std.mem.span(pb.ReadString(config, key(&buf, i, .name), "")),
            std.mem.span(pb.ReadString(config, key(&buf, i, .url), "")),
            std.mem.span(pb.ReadString(config, key(&buf, i, .user), "")),
            std.mem.span(pb.ReadString(config, key(&buf, i, .password), "")),
            pb.ReadInt(config, key(&buf, i, .use_http_11), 0) != 0,
        ) catch |err| switch (err) {
            // An invalid entry must not break the whole loading process.
            // Just skip it.
            error.InvalidAddress => continue,
            else => return err,
        };
        errdefer server.free(allocator);
        try servers.append(allocator, server);
    }
}

/// Store the configuration
pub fn store(servers: []const Server) void {
    const config = pb.OpenConfig(config_path, null) orelse return;
    defer pb.CloseConfig(config);

    for (servers, 0..) |server, i| {
        var buf: [32]u8 = undefined;
        pb.WriteString(config, key(&buf, i, .name), server.name.ptr);
        pb.WriteString(config, key(&buf, i, .url), server.url.ptr);
        pb.WriteString(config, key(&buf, i, .user), server.user.ptr);
        pb.WriteString(config, key(&buf, i, .password), server.password.ptr);
        pb.WriteInt(config, key(&buf, i, .use_http_11), @intFromBool(server.use_http_11));
    }

    // A deleted server leaves the entry after the last one behind.
    // We do not want that.
    var buf: [32]u8 = undefined;
    inline for (std.meta.tags(Field)) |field| {
        pb.DeleteString(config, key(&buf, servers.len, field));
    }

    _ = pb.SaveConfig(config);
}

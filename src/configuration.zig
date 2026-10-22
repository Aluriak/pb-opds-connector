const std = @import("std");
const pb = @import("c");

const Server = @import("server.zig").Server;
const Catalogs = @import("server.zig").Catalogs;
const Field = enum { name, url, user, password, use_http_11, basic_auth, timeout };

/// PocketBooks location for storing configuration of applications.
pub const config_path = "/mnt/ext1/system/config/opds-connector.cfg";

/// Set once the default catalogs were written into the configuration.
/// Without it they are added again, so deleting them all must not remove it.
const defaults_key = "defaults_added";

/// Settings are stored as "server.<index>.<field>"
fn key(buf: *[32]u8, index: usize, field: Field) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, "server.{d}.{s}", .{ index, @tagName(field) }, 0) catch unreachable).ptr;
}

/// Load the configuration. On the first start the default catalogs are put in
/// front of the servers found and written into it.
pub fn load(allocator: std.mem.Allocator, servers: *std.ArrayList(Server)) !void {
    if (try read(allocator, servers)) store(servers.items);
}

/// Reads the servers, returns whether this is the first start
fn read(allocator: std.mem.Allocator, servers: *std.ArrayList(Server)) !bool {
    const config = pb.OpenConfig(config_path, null) orelse {
        try addDefaults(allocator, servers);
        return true;
    };
    defer pb.CloseConfigNoSave(config);

    const first_start = pb.ReadInt(config, defaults_key, 0) == 0;
    if (first_start) try addDefaults(allocator, servers);

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
            .{
                .use_http_11 = pb.ReadInt(config, key(&buf, i, .use_http_11), 0) != 0,
                .basic_auth = pb.ReadInt(config, key(&buf, i, .basic_auth), 0) != 0,
                .timeout = std.math.cast(u16, pb.ReadInt(config, key(&buf, i, .timeout), 0)) orelse 0,
            },
        ) catch |err| switch (err) {
            // An invalid entry must not break the whole loading process.
            // Just skip it.
            error.InvalidAddress => continue,
            else => return err,
        };
        errdefer server.free(allocator);
        try servers.append(allocator, server);
    }
    return first_start;
}

fn addDefaults(allocator: std.mem.Allocator, servers: *std.ArrayList(Server)) !void {
    for (Catalogs.defaults) |default| {
        const server = try Server.init(allocator, default.name, default.url, "", "", .{});
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
        pb.WriteInt(config, key(&buf, i, .use_http_11), @intFromBool(server.options.use_http_11));
        pb.WriteInt(config, key(&buf, i, .basic_auth), @intFromBool(server.options.basic_auth));
        pb.WriteInt(config, key(&buf, i, .timeout), server.options.timeout);
    }

    // A deleted server leaves the entry after the last one behind.
    // We do not want that.
    var buf: [32]u8 = undefined;
    inline for (std.meta.tags(Field)) |field| {
        pb.DeleteString(config, key(&buf, servers.len, field));
    }
    pb.WriteInt(config, defaults_key, 1);

    _ = pb.SaveConfig(config);
}

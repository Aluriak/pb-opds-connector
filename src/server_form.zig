const std = @import("std");
const pb = @import("c");

const pocketbook = @import("pocketbook.zig");
const configuration = @import("configuration.zig");
const Server = @import("server.zig").Server;

var allocator: std.mem.Allocator = undefined;

/// Global config state needed for InkView
var config: ?*pb.iconfig = null;

/// Called when the form was left, with the server if one was entered
pub const DoneFn = *const fn (entered: anyerror!?Server) void;
var on_done: DoneFn = undefined;

const OnOff = enum {
    off,
    on,

    var variants: [names.len:null]?[*:0]u8 = blk: {
        var labels: [names.len:null]?[*:0]u8 = undefined;
        for (names, 0..) |name, i| labels[i] = @constCast(name.ptr);
        break :blk labels;
    };
    const names = std.meta.fieldNames(OnOff);
};

const ServerField = struct {
    label: [:0]const u8 = "",
    value: [:0]const u8 = "",
    type: c_int = pb.CFG_TEXT,
};
const ServerFields = struct {
    name: ServerField = .{ .label = "Name" },
    url: ServerField = .{ .label = "URL" },
    user: ServerField = .{ .label = "User name (optional)" },
    password: ServerField = .{ .label = "Password (optional)", .type = pb.CFG_PASSWORD },
    use_http_11: ServerField = .{ .label = "Use HTTP/1.1", .value = "0", .type = pb.CFG_INDEX },
    basic_auth: ServerField = .{ .label = "Send the login right away (Calibre-Web)", .value = "0", .type = pb.CFG_INDEX },
    timeout: ServerField = .{ .label = "Connection timeout in seconds (optional)" },

    const names = @typeInfo(ServerFields).@"struct".field_names;

    fn fromServer(server: Server) ServerFields {
        var fields: ServerFields = .{};
        fields.name.value = server.name;
        fields.url.value = server.url;
        fields.user.value = server.user;
        fields.password.value = server.password;
        fields.use_http_11.value = if (server.options.use_http_11) "1" else "0";
        fields.basic_auth.value = if (server.options.basic_auth) "1" else "0";
        fields.timeout.value = if (server.options.timeout > 0)
            std.fmt.bufPrintSentinel(&timeout_text, "{d}", .{server.options.timeout}, 0) catch ""
        else
            "";
        return fields;
    }

    fn getFormRows() [names.len + 1]pb.iconfigedit {
        const empty: ServerFields = .{};
        var rows: [names.len + 1]pb.iconfigedit = undefined;
        inline for (names, 0..) |field, i| {
            rows[i] = .{
                .type = @field(empty, field).type,
                .text = @constCast(@field(empty, field).label.ptr),
                .name = @constCast(field.ptr),
                .deflt = @constCast(""),
                // Every choice row is an on/off row
                .variants = if (@field(empty, field).type == pb.CFG_INDEX) @ptrCast(&OnOff.variants) else null,
            };
        }
        // An empty row ends the form
        rows[names.len] = .{};

        return rows;
    }

    // InkView's form stores password rows encrypted (WriteSecret), so they are
    // read and written the same way. Everything else is plain text.
    fn write(fields: ServerFields, cfg: *pb.iconfig) void {
        inline for (names) |field| {
            const f = @field(fields, field);
            if (f.type == pb.CFG_PASSWORD) {
                pb.WriteSecret(cfg, field, f.value.ptr);
            } else {
                pb.WriteString(cfg, field, f.value.ptr);
            }
        }
    }

    fn read(cfg: *pb.iconfig) ServerFields {
        var fields: ServerFields = .{};
        inline for (names) |field| {
            const f = &@field(fields, field);
            f.value = std.mem.span(if (f.type == pb.CFG_PASSWORD)
                pb.ReadSecret(cfg, field, no_secret)
            else
                pb.ReadString(cfg, field, ""));
        }
        return fields;
    }

    fn delete(cfg: *pb.iconfig) void {
        inline for (names) |field| {
            pb.DeleteString(cfg, field);
        }
    }
};

/// What ReadSecret returns when there is nothing to decrypt. Everything else it
/// returns was allocated and must be freed.
const no_secret: [:0]const u8 = "";

/// The timeout of the server being edited, as text for the form
var timeout_text: [8]u8 = undefined;

var form_rows = ServerFields.getFormRows();

/// Shows the "Add server" form
pub fn open(gpa: std.mem.Allocator, server: ?Server, done: DoneFn) void {
    const cfg = pb.OpenConfig(configuration.config_path, null) orelse {
        pocketbook.showError("Could not open the form", error.NoSettingsFile);
        return;
    };
    const fields: ServerFields = if (server) |s| .fromServer(s) else .{};
    fields.write(cfg);
    config = cfg;

    allocator = gpa;
    on_done = done;

    const title = if (server == null) "Add server" else "Edit server";
    pb.OpenConfigEditor(title, cfg, &form_rows, @ptrCast(&closed), changed);
}

/// Called by InkView for every field the user changed
fn changed(_: [*c]u8) callconv(.c) void {}

/// Called by InkView when the user leaves the form
fn closed() callconv(.c) void {
    const open_config = config orelse return;
    config = null;
    on_done(closeForm(open_config));
}

/// Takes what was entered into the form and closes its settings file.
fn closeForm(open_config: *pb.iconfig) !?Server {
    defer {
        ServerFields.delete(open_config);
        _ = pb.SaveConfig(open_config);
        pb.CloseConfig(open_config);
    }

    const fields = ServerFields.read(open_config);
    defer if (fields.password.value.ptr != no_secret.ptr) std.c.free(@constCast(fields.password.value.ptr));
    const name = std.mem.trim(u8, fields.name.value, " ");
    const address = std.mem.trim(u8, fields.url.value, " ");
    const options: Server.Options = .{
        .use_http_11 = std.mem.eql(u8, fields.use_http_11.value, "1"),
        .basic_auth = std.mem.eql(u8, fields.basic_auth.value, "1"),
        // Anything but a number keeps the default
        .timeout = std.fmt.parseInt(u16, std.mem.trim(u8, fields.timeout.value, " "), 10) catch 0,
    };
    if (name.len == 0 or address.len == 0) return null;

    return try Server.init(
        allocator,
        name,
        address,
        fields.user.value,
        fields.password.value,
        options,
    );
}

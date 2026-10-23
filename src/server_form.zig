const std = @import("std");
const pb = @import("c");

const pocketbook = @import("pocketbook.zig");
const i18n = @import("i18n.zig");
const t = i18n.t;
const configuration = @import("configuration.zig");
const Server = @import("server.zig").Server;

var allocator: std.mem.Allocator = undefined;

/// Global config state needed for InkView
var config: ?*pb.iconfig = null;

/// Called when the form was left, with the server if one was entered
pub const DoneFn = *const fn (entered: anyerror!?Server) void;
var on_done: DoneFn = undefined;

const ServerField = struct {
    /// Set when the form opens, in the language of the app
    label: [:0]const u8 = "",
    value: [:0]const u8 = "",
    kind: c_int = pb.CFG_TEXT,
};
const ServerFields = struct {
    name: ServerField = .{},
    url: ServerField = .{},
    user: ServerField = .{},
    // InkView keeps password fields encrypted in the settings file
    password: ServerField = .{ .kind = pb.CFG_PASSWORD },
    // The index of the chosen answer, "0" or "1"
    calibre_web: ServerField = .{ .value = "0", .kind = pb.CFG_INDEX },
    timeout: ServerField = .{},
    sync: ServerField = .{ .value = "0", .kind = pb.CFG_INDEX },
    covers: ServerField = .{ .value = "1", .kind = pb.CFG_INDEX },

    const names = @typeInfo(ServerFields).@"struct".field_names;

    fn fromServer(server: Server) ServerFields {
        var fields: ServerFields = .{};
        fields.name.value = server.name;
        fields.url.value = server.url;
        fields.user.value = server.user;
        fields.password.value = server.password;
        fields.calibre_web.value = if (server.options.calibre_web) "1" else "0";
        fields.sync.value = if (server.options.sync) "1" else "0";
        fields.covers.value = if (server.options.covers) "1" else "0";
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
            const f = @field(empty, field);
            rows[i] = .{
                .type = f.kind,
                .text = @constCast(f.label.ptr),
                .name = @constCast(field.ptr),
                .deflt = @constCast(f.value.ptr),
                .variants = if (f.kind == pb.CFG_INDEX) @ptrCast(&no_yes) else null,
            };
        }
        // An empty row ends the form
        rows[names.len] = .{};

        return rows;
    }

    fn write(fields: ServerFields, cfg: *pb.iconfig) void {
        inline for (names) |field| {
            const f = @field(fields, field);
            if (f.kind == pb.CFG_PASSWORD) {
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
            f.value = std.mem.span(if (f.kind == pb.CFG_PASSWORD)
                pb.ReadSecret(cfg, field, no_secret)
            else
                pb.ReadString(cfg, field, f.value.ptr));
        }
        return fields;
    }

    fn delete(cfg: *pb.iconfig) void {
        inline for (names) |field| {
            pb.DeleteString(cfg, field);
        }
    }
};

/// Whether a yes/no row was answered with "Yes", its index being 1
fn isYes(value: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, value, " "), "1");
}

/// The timeout of the server being edited, as text for the form
var timeout_text: [8]u8 = undefined;

/// What ReadSecret returns when there is nothing to decrypt. Everything else it
/// returns was allocated and must be freed.
const no_secret: [:0]const u8 = "";

/// The answers of a yes/no row, InkView stores the index of the chosen one
var no_yes = [_:null]?[*:0]const u8{ "No", "Yes" };

var form_rows = ServerFields.getFormRows();

/// Puts the labels of the form in the language of the app
fn translateForm() void {
    const labels = [_][:0]const u8{
        t(.field_name),        t(.field_url),     t(.field_user), t(.field_password),
        t(.field_calibre_web), t(.field_timeout), t(.field_sync), t(.field_covers),
    };
    comptime std.debug.assert(labels.len == ServerFields.names.len);
    for (labels, 0..) |label, i| form_rows[i].text = @constCast(label.ptr);
    no_yes[0] = t(.no);
    no_yes[1] = t(.yes);
}

/// Shows the "Add server" form
pub fn open(gpa: std.mem.Allocator, server: ?Server, done: DoneFn) void {
    const cfg = pb.OpenConfig(configuration.config_path, null) orelse {
        pocketbook.showError(t(.form_error), error.NoSettingsFile);
        return;
    };
    const fields: ServerFields = if (server) |s| .fromServer(s) else .{};
    fields.write(cfg);
    config = cfg;

    allocator = gpa;
    on_done = done;

    translateForm();
    const title = if (server == null) t(.form_add) else t(.form_edit);
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
    if (name.len == 0 or address.len == 0) return null;

    const options: Server.Options = .{
        .calibre_web = isYes(fields.calibre_web.value),
        .sync = isYes(fields.sync.value),
        .covers = isYes(fields.covers.value),
        // Anything but a number keeps the default
        .timeout = std.fmt.parseInt(u16, std.mem.trim(u8, fields.timeout.value, " "), 10) catch 0,
    };
    return try Server.init(allocator, name, address, fields.user.value, fields.password.value, options);
}

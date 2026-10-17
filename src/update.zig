//! Updating the app from the releases of its GitHub repository, when the user asks for it.
//! See update_check.zig for which build is offered.

const std = @import("std");
const pb = @import("c");
const build_options = @import("build_options");

const check = @import("update_check.zig");
const net = @import("net.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;

const app_title = build_options.app_name;
const repo = build_options.update_repo;

/// Builds that do not know where they come from offer no updates
pub const enabled = repo.len > 0;

/// Where the app is installed, should it not be able to find out itself
const default_path = "/mnt/ext1/applications/" ++ app_title ++ ".app";

/// Holds the version files while the dialog is open, `offered` points into them
var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var offered: check.Info = .{};
var dialog_text: [512]u8 = undefined;

/// The build this app is
pub fn installed() check.Info {
    return .{
        .channel = std.meta.stringToEnum(check.Channel, build_options.channel) orelse .dev,
        .version = build_options.version,
        .commit = build_options.commit,
    };
}

/// "Installed: 0.3.1 (nightly, 9606907)", for the start screen
pub fn describeInstalled(buf: []u8) [:0]const u8 {
    var info_buf: [96]u8 = undefined;
    return std.fmt.bufPrintSentinel(buf, "Installed: {s}", .{installed().describe(&info_buf)}, 0) catch "";
}

/// Looks for a newer build and, if there is one, asks whether to install it
pub fn checkForUpdate(policy: check.Policy) void {
    if (!pocketbook.ensureNetwork()) {
        pocketbook.showError("Could not look for updates", error.NoNetwork);
        return;
    }
    // GitHub must not get the login of the last catalog
    net.useServer(null);
    _ = arena.reset(.retain_capacity);

    pb.ShowHourglassForce();
    var failure: ?anyerror = null;
    const nightly = if (policy == .all) fetchInfo("download/nightly", &failure) else null;
    // "latest" is the newest release that is not a pre-release, so never the nightly build
    const release = fetchInfo("latest/download", &failure);
    pb.HideHourglass();

    if (nightly == null and release == null) {
        pocketbook.showError("Could not look for updates", failure orelse error.NoRelease);
        return;
    }

    const found = check.choose(installed(), policy, nightly, release) orelse {
        var buf: [160]u8 = undefined;
        var info_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, "The app is up to date.\nInstalled: {s}", .{installed().describe(&info_buf)}, 0) catch "The app is up to date.";
        pb.Message(pb.ICON_INFORMATION, app_title, msg.ptr, 5000);
        return;
    };

    offered = found;
    var new_buf: [96]u8 = undefined;
    var old_buf: [96]u8 = undefined;
    const kind = switch (found.channel) {
        .release => "a release",
        .nightly => "a nightly build, made from the latest changes and less tested",
        .dev => "a development build",
    };
    const text = std.fmt.bufPrintSentinel(&dialog_text, "New version: {s}\nThis is {s}.\nInstalled: {s}\n\nInstall it?", .{
        found.describe(&new_buf),
        kind,
        installed().describe(&old_buf),
    }, 0) catch return;
    pb.Dialog(pb.ICON_QUESTION, app_title, text.ptr, "Install", "Cancel", installAnswered);
}

/// Reads the version.txt of a release, null if there is none
fn fetchInfo(comptime path: []const u8, failure: *?anyerror) ?check.Info {
    const url = "https://github.com/" ++ repo ++ "/releases/" ++ path ++ "/version.txt";
    const body = net.fetch(arena.allocator(), url) catch |err| {
        trace("update: {s} failed: {s}\n", .{ url, @errorName(err) });
        failure.* = err;
        return null;
    };
    return check.Info.parse(body) catch |err| {
        trace("update: {s} unreadable: {s}\n", .{ url, @errorName(err) });
        failure.* = err;
        return null;
    };
}

/// Called by InkView with the number of the button that was pressed
fn installAnswered(button: c_int) callconv(.c) void {
    if (button != 1) return;

    pb.ShowHourglassForce();
    const installed_ok = install(offered);
    pb.HideHourglass();

    installed_ok catch |err| {
        pocketbook.showError("Could not install the update", err);
        return;
    };

    var buf: [192]u8 = undefined;
    var info_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "Installed {s}.\nClose the app and open it again to use it.", .{offered.describe(&info_buf)}, 0) catch "Installed. Close the app and open it again.";
    pb.Message(pb.ICON_INFORMATION, app_title, msg.ptr, 10000);
}

/// Downloads the new app next to the running one, checks it and puts it in its place.
/// The running app goes on with the old file, the new one is used from the next start.
fn install(info: check.Info) !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrintSentinel(&url_buf, "https://github.com/{s}/releases/download/{s}/opds-connector-{s}.bin", .{ repo, info.tag, build_options.platform }, 0);

    var exe_buf: [256]u8 = undefined;
    const exe = ownPath(&exe_buf);
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return error.UnknownInstallPath;
    const dir = exe[0..slash];

    var part_name_buf: [128]u8 = undefined;
    const part_name = try std.fmt.bufPrint(&part_name_buf, "{s}.part", .{exe[slash + 1 ..]});
    var part_buf: [256]u8 = undefined;
    const part = try std.fmt.bufPrintSentinel(&part_buf, "{s}/{s}", .{ dir, part_name }, 0);
    errdefer _ = std.c.unlink(part.ptr);

    trace("update: {s} -> {s}\n", .{ url, part });
    try net.download(url, dir, part_name, null);

    if (!startsLikeApp(part)) return error.NotAnApp;

    var exe_z_buf: [256]u8 = undefined;
    const exe_z = try std.fmt.bufPrintSentinel(&exe_z_buf, "{s}", .{exe}, 0);
    if (std.c.rename(part.ptr, exe_z.ptr) != 0) return error.CannotReplaceApp;
}

/// The file the running app was started from
fn ownPath(buf: []u8) []const u8 {
    const len = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (len <= 0 or len >= buf.len) return default_path;
    return buf[0..@intCast(len)];
}

/// Whether the downloaded file is an ARM program, and not an error page
fn startsLikeApp(path: [:0]const u8) bool {
    const file = std.c.fopen(path.ptr, "rb") orelse return false;
    defer _ = std.c.fclose(file);

    var head: [20]u8 = undefined;
    if (std.c.fread(&head, 1, head.len, file) != head.len) return false;
    return check.isArmExecutable(&head);
}

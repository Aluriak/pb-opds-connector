const std = @import("std");

const net = @import("net.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;
const utils = @import("utils.zig");
const xml = @import("xml.zig");

const pb = @import("c");

const app_title = @import("build_options").app_name;

/// All downloads are stored into the "Downloads" folder.
/// The PocketBook scanner is asked to only re-scan this folder after a download.
const download_dir = "/mnt/ext1/Downloads";

// The format menu. InkView keeps pointers into these while the menu is open
var menu_items: [xml.max_downloads + 2]pb.imenu = undefined;
var menu_texts: [xml.max_downloads][160]u8 = undefined;
var menu_entry: xml.Entry = .{};

/// "Step" means a tenth of the file (or a megabyte, when the server doesn't give the size).
/// So the variable is what turns thousands of progress calls into about ten screen updates per download,
/// which matters on e-ink where each update is slow.
var progress_step: u64 = 0;

/// Downloads the book of `entry`. If it comes in several formats, the user picks one first.
pub fn start(entry: xml.Entry) void {
    switch (entry.downloads.len) {
        0 => {},
        1 => downloadBook(entry, entry.downloads[0]),
        else => openMenu(entry),
    }
}

/// Lets the user pick one of several formats of the same book
fn openMenu(entry: xml.Entry) void {
    menu_entry = entry;

    menu_items[0] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast("Download"), .submenu = null };
    for (entry.downloads, 0..) |download, i| {
        const text = download.description(&menu_texts[i]);
        menu_items[i + 1] = .{ .type = pb.ITEM_ACTIVE, .index = @intCast(i + 1), .text = @constCast(text.ptr), .submenu = null };
    }
    // A zeroed item ends the menu
    menu_items[entry.downloads.len + 1] = .{ .type = 0, .index = 0, .text = null, .submenu = null };

    pb.OpenMenu(&menu_items, 1, @divTrunc(pb.ScreenWidth(), 8), @divTrunc(pb.ScreenHeight(), 3), menuHandler);
}

fn menuHandler(index: c_int) callconv(.c) void {
    trace("menu index={d}\n", .{index});

    // Anything else means the menu was closed without a choice
    if (index < 1 or index > menu_entry.downloads.len) return;
    downloadBook(menu_entry, menu_entry.downloads[@intCast(index - 1)]);
}

fn downloadBook(entry: xml.Entry, download: xml.Download) void {
    var name_buf: [xml.max_filename]u8 = undefined;
    const filename = entry.saveName(&name_buf, download.format);

    if (!pocketbook.ensureNetwork()) {
        pocketbook.showError("Could not download the book", error.NoNetwork);
        return;
    }

    progress_step = 0;
    pb.OpenProgressbar(pb.ICON_INFORMATION, "Downloading", entry.title.ptr, 0, null);
    net.download(download.url, download_dir, filename, onProgress) catch |err| {
        pb.CloseProgressbar();
        pocketbook.showError("Could not download the book", err);
        return;
    };
    pb.CloseProgressbar();
    pocketbook.rescanLibrary(download_dir);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&msg_buf, "Saved to Downloads:\n{s}", .{filename}, 0) catch "Saved to Downloads.";
    pb.Message(pb.ICON_INFORMATION, app_title, msg.ptr, 3000);
}

fn onProgress(downloaded: u64, total: u64) void {
    // Steps of 10 percent, or of 1 MB when the server does not tell the size
    const step = if (total > 0) downloaded * 10 / total else downloaded / (1024 * 1024);
    if (step == progress_step) return;
    progress_step = step;

    var buf: [64]u8 = undefined;
    var size_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{utils.formatSize(&size_buf, downloaded)}, 0) catch return;
    const percent: c_int = if (total > 0) @intCast(@min(100, downloaded * 100 / total)) else 0;
    _ = pb.UpdateProgressbar(text.ptr, percent);
}

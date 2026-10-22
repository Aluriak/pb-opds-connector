const std = @import("std");

const net = @import("net.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;
const utils = @import("utils.zig");
const files = @import("files.zig");
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

/// The name a book is saved under. Books of a catalog that is synchronized carry the tag of
/// their id, so the sync finds them again whether they were downloaded by hand or not.
fn fileName(entry: xml.Entry, format: xml.BookFormat, buf: *[xml.max_sync_name]u8) []const u8 {
    const synced = if (net.currentServer()) |s| s.options.sync else false;
    if (synced and entry.id.len > 0) return entry.syncName(buf, format.extension());
    return entry.saveName(buf[0..xml.max_filename], format);
}

fn downloadBook(entry: xml.Entry, download: xml.Download) void {
    var name_buf: [xml.max_sync_name]u8 = undefined;
    const filename = fileName(entry, download.format, &name_buf);

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
    const msg = std.fmt.bufPrintSentinel(&msg_buf, "Saved to Downloads:\n{s}", .{entry.title}, 0) catch "Saved to Downloads.";
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

/// What a synchronization did
const SyncResult = struct {
    downloaded: usize = 0,
    present: usize = 0,
    /// Books on the reader that got their current name, e.g. after a change of title
    renamed: usize = 0,
    failed: usize = 0,
    /// Books without an id cannot be found again, so they are left out
    skipped: usize = 0,
};

/// Downloads every book of `entries` that is not on the reader yet, one after the other.
/// Nothing on the reader is deleted or replaced.
pub fn synchronize(entries: []const xml.Entry) void {
    if (!pocketbook.ensureNetwork()) {
        pocketbook.showError("Could not synchronize", error.NoNetwork);
        return;
    }

    var books: usize = 0;
    for (entries) |entry| {
        if (entry.downloads.len > 0) books += 1;
    }

    var result: SyncResult = .{};
    var done: usize = 0;
    pb.OpenProgressbar(pb.ICON_INFORMATION, "Synchronizing", "", 0, null);

    for (entries) |entry| {
        if (entry.downloads.len == 0) continue;
        done += 1;

        if (entry.id.len == 0) {
            result.skipped += 1;
            continue;
        }
        if (findPresent(entry)) |present| {
            result.present += 1;
            if (present.renamed) result.renamed += 1;
            continue;
        }

        var text_buf: [192]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&text_buf, "{d}/{d}: {s}", .{ done, books, entry.title }, 0) catch "";
        _ = pb.UpdateProgressbar(text.ptr, @intCast(done * 100 / books));

        syncBook(entry, preferred(entry.downloads)) catch |err| {
            trace("sync of {s} failed: {s}\n", .{ entry.id, @errorName(err) });
            result.failed += 1;
            continue;
        };
        result.downloaded += 1;
    }

    pb.CloseProgressbar();
    if (result.downloaded > 0 or result.renamed > 0) pocketbook.rescanLibrary(download_dir);

    var renamed_buf: [48]u8 = undefined;
    const renamed = if (result.renamed > 0) std.fmt.bufPrint(&renamed_buf, " ({d} renamed)", .{result.renamed}) catch "" else "";
    var msg_buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(
        &msg_buf,
        "Synchronized: {d} downloaded, {d} already on the reader{s}, {d} failed{s}",
        .{ result.downloaded, result.present, renamed, result.failed, if (result.skipped > 0) ", some books have no id and were left out." else "." },
        0,
    ) catch "Synchronized.";
    pb.Message(if (result.failed > 0) pb.ICON_WARNING else pb.ICON_INFORMATION, app_title, msg.ptr, 10000);
}

/// EPUB if the catalog offers it, the first format otherwise
fn preferred(downloads: []const xml.Download) xml.Download {
    for (downloads) |download| {
        if (download.format == .epub) return download;
    }
    return downloads[0];
}

const Present = struct { renamed: bool };

/// Whether the book is on the reader, in any format and under any title: its file is found
/// by the tag of its id. A file whose name is not the current one is renamed, so names follow
/// the catalog and files named the earlier way ("opds-<tag>.epub") become readable.
fn findPresent(entry: xml.Entry) ?Present {
    const tag = entry.syncTag();
    var found_buf: [512]u8 = undefined;
    const found = files.findTagged(&found_buf, download_dir, &tag) orelse return null;

    const extension = files.tagExtension(found, &tag);
    // An extension the app does not know cannot be from a sync, leave the file alone
    if (extension.len == 0 or extension.len > ".fb2.zip".len) return .{ .renamed = false };

    // The current name, keeping the extension of the file found
    var wanted_buf: [xml.max_sync_name]u8 = undefined;
    const wanted = entry.syncName(&wanted_buf, extension);
    if (std.mem.eql(u8, found, wanted)) return .{ .renamed = false };

    var from_buf: [600]u8 = undefined;
    var to_buf: [600]u8 = undefined;
    const from = std.fmt.bufPrintSentinel(&from_buf, "{s}/{s}", .{ download_dir, found }, 0) catch return .{ .renamed = false };
    const to = std.fmt.bufPrintSentinel(&to_buf, "{s}/{s}", .{ download_dir, wanted }, 0) catch return .{ .renamed = false };
    // A failed rename leaves the book where it is, it is still on the reader
    return .{ .renamed = std.c.rename(from.ptr, to.ptr) == 0 };
}

/// Downloads under a temporary name first, so a download cut short is never taken for a book
fn syncBook(entry: xml.Entry, download: xml.Download) !void {
    var name_buf: [xml.max_sync_name]u8 = undefined;
    const name = entry.syncName(&name_buf, download.format.extension());

    var part_buf: [xml.max_sync_name + ".part".len]u8 = undefined;
    const part = try std.fmt.bufPrint(&part_buf, "{s}.part", .{name});
    try net.download(download.url, download_dir, part, null);

    var from_buf: [600]u8 = undefined;
    var to_buf: [600]u8 = undefined;
    const from = try std.fmt.bufPrintSentinel(&from_buf, "{s}/{s}", .{ download_dir, part }, 0);
    const to = try std.fmt.bufPrintSentinel(&to_buf, "{s}/{s}", .{ download_dir, name }, 0);
    if (std.c.rename(from.ptr, to.ptr) != 0) {
        _ = std.c.unlink(from.ptr);
        return error.CannotWriteFile;
    }
}

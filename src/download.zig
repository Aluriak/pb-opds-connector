const std = @import("std");

const net = @import("net.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;
const utils = @import("utils.zig");
const files = @import("files.zig");
const xml = @import("xml.zig");
const manifest = @import("manifest.zig");
const i18n = @import("i18n.zig");
const t = i18n.t;

const pb = @import("c");

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

    menu_items[0] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast(t(.download).ptr), .submenu = null };
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
        pocketbook.showError(t(.download_error), error.NoNetwork);
        return;
    }

    progress_step = 0;
    pb.OpenProgressbar(pb.ICON_INFORMATION, t(.downloading), entry.title.ptr, 0, null);
    net.download(download.url, download_dir, filename, onProgress) catch |err| {
        pb.CloseProgressbar();
        pocketbook.showError(t(.download_error), err);
        return;
    };
    pb.CloseProgressbar();
    pocketbook.rescanLibrary(download_dir);

    var msg_buf: [256]u8 = undefined;
    const msg = i18n.fmt(&msg_buf, .saved, .{entry.title});
    pb.Message(pb.ICON_INFORMATION, t(.app_title), msg.ptr, 3000);
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
    /// Books found on the reader under another name, e.g. copied over USB, and taken over
    adopted: usize = 0,
    failed: usize = 0,
    /// Books without an id cannot be found again, so they are left out
    skipped: usize = 0,
};

/// A synchronization going on. It runs one book per timer call, so the reader handles the
/// stop button of the progress bar between two books.
const Sync = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const xml.Entry,
    /// The key of the list in the manifest
    list: manifest.Tag,
    /// The next entry to look at
    next: usize = 0,
    /// Books of the list, and books looked at so far
    books: usize = 0,
    done: usize = 0,
    /// The files that are not from a sync, candidates for books already on the reader
    untagged: [][]const u8 = &.{},
    result: SyncResult = .{},
    stopped: bool = false,
    on_done: *const fn () void,
};

var sync: ?Sync = null;

/// Downloads every book of `entries`, the list at `list_url`, that is not on the reader yet,
/// one after the other. Then offers to delete exact copies of the books, and the books that
/// left the list since the last synchronization. `on_done` is called once the downloads are
/// over, before the questions; until then `entries` must stay.
pub fn synchronize(entries: []const xml.Entry, list_url: []const u8, on_done: *const fn () void) void {
    if (sync != null) return;
    if (!pocketbook.ensureNetwork()) {
        pocketbook.showError(t(.sync_error), error.NoNetwork);
        return on_done();
    }

    var state: Sync = .{ .arena = .init(std.heap.c_allocator), .entries = entries, .list = manifest.listKey(list_url), .on_done = on_done };
    for (entries) |entry| {
        if (entry.downloads.len > 0) state.books += 1;
    }
    state.untagged = untaggedFiles(state.arena.allocator()) catch &.{};
    sync = state;

    // With a handler, the progress bar has a button to stop
    pb.OpenProgressbar(pb.ICON_INFORMATION, t(.synchronizing), "", 0, syncStopped);
    pb.SetHardTimer("opds-sync", @ptrCast(&syncStep), 0);
}

/// Called by InkView when the button of the progress bar is pressed
fn syncStopped(button: c_int) callconv(.c) void {
    trace("sync stop button={d}\n", .{button});
    if (sync) |*state| state.stopped = true;
}

/// Looks at the next entries, until one book was downloaded, then lets the reader breathe
fn syncStep() callconv(.c) void {
    if (sync == null) return;
    const state = &sync.?;
    while (state.next < state.entries.len and !state.stopped) {
        const entry = state.entries[state.next];
        state.next += 1;
        if (entry.downloads.len == 0) continue;
        state.done += 1;

        if (entry.id.len == 0) {
            state.result.skipped += 1;
            continue;
        }
        if (findPresent(entry)) |present| {
            state.result.present += 1;
            if (present.renamed) state.result.renamed += 1;
            continue;
        }

        const download = preferred(entry.downloads);
        if (adopt(entry, download, &state.untagged)) {
            state.result.adopted += 1;
            continue;
        }

        var text_buf: [192]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&text_buf, "{d}/{d}: {s}", .{ state.done, state.books, entry.title }, 0) catch "";
        const answer = pb.UpdateProgressbar(text.ptr, @intCast(state.done * 100 / state.books));
        trace("progress bar answer={d}\n", .{answer});

        syncBook(entry, download) catch |err| {
            trace("sync of {s} failed: {s}\n", .{ entry.id, @errorName(err) });
            state.result.failed += 1;
            continue;
        };
        state.result.downloaded += 1;
        // The next book after the reader had a chance to handle the stop button
        pb.SetHardTimer("opds-sync", @ptrCast(&syncStep), 10);
        return;
    }
    finishSync();
}

fn finishSync() void {
    if (sync == null) return;
    const state = &sync.?;
    defer {
        state.arena.deinit();
        sync = null;
    }
    pb.CloseProgressbar();
    const result = state.result;
    if (result.downloaded > 0 or result.renamed > 0 or result.adopted > 0) pocketbook.rescanLibrary(download_dir);
    state.on_done();

    var renamed_buf: [48]u8 = undefined;
    const renamed = if (result.renamed > 0) i18n.fmt(&renamed_buf, .sync_renamed, .{result.renamed}) else "";
    var adopted_buf: [80]u8 = undefined;
    const adopted = if (result.adopted > 0) i18n.fmt(&adopted_buf, .sync_adopted, .{result.adopted}) else "";
    const summary = i18n.fmt(
        &summary_text,
        .sync_done,
        .{
            if (state.stopped) t(.sync_stopped) else "",
            result.downloaded,
            result.present,
            renamed,
            adopted,
            result.failed,
            if (result.skipped > 0) t(.sync_skipped) else ".",
        },
    );

    findCopies() catch |err| trace("looking for copies failed: {s}\n", .{@errorName(err)});
    findRemoved(state) catch |err| trace("looking for removed books failed: {s}\n", .{@errorName(err)});
    pending_summary = summary;
    if (copies.len == 0 and removed.len == 0) {
        pb.Message(if (result.failed > 0) pb.ICON_WARNING else pb.ICON_INFORMATION, t(.app_title), summary.ptr, 10000);
        pending_summary = null;
        return;
    }
    askNext();
}

var summary_text: [320]u8 = undefined;
/// The summary of the synchronization, shown with the first question
var pending_summary: ?[:0]const u8 = null;

/// Books synchronized from the list before that left it, kept while the user is asked
/// whether to delete them
var removed_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var removed: []const [:0]const u8 = &.{};

/// Finds the books that left the list, and writes down the books of the list now. A stopped
/// synchronization saw only part of the list: it adds the books it saw, removes nothing.
fn findRemoved(state: *const Sync) !void {
    _ = removed_arena.reset(.retain_capacity);
    removed = &.{};
    const allocator = removed_arena.allocator();

    const lines = try manifest.load(allocator, manifest.default_path);
    var current: std.ArrayList(manifest.Tag) = .empty;
    for (state.entries[0..state.next]) |entry| {
        if (entry.downloads.len > 0 and entry.id.len > 0) try current.append(allocator, entry.syncTag());
    }

    if (!state.stopped) {
        var found: std.ArrayList([:0]const u8) = .empty;
        for (try manifest.removed(allocator, lines, state.list, current.items)) |tag| {
            var name_buf: [512]u8 = undefined;
            const name = files.findTagged(&name_buf, download_dir, &tag) orelse continue;
            try found.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ download_dir, name }, 0));
        }
        removed = try found.toOwnedSlice(allocator);
    } else {
        // Keeps the books of the list it did not get to
        for (lines) |line| {
            if (std.mem.eql(u8, &line.list, &state.list)) try current.append(allocator, line.book);
        }
    }
    // Whether the removed books are deleted or kept, they are not of the list anymore
    try manifest.store(manifest.default_path, try manifest.replace(allocator, lines, state.list, current.items));
}

/// Asks the next question after a synchronization: exact copies first, then removed books
fn askNext() void {
    if (copies.len > 0) return offerToDeleteCopies();
    if (removed.len > 0) return offerToDeleteRemoved();
    if (pending_summary) |summary| {
        pb.Message(pb.ICON_INFORMATION, t(.app_title), summary.ptr, 10000);
        pending_summary = null;
    }
}

/// The start of the dialog text: the summary for the first question, nothing after
fn takeSummary() []const u8 {
    const summary = pending_summary orelse return "";
    pending_summary = null;
    return summary;
}

/// Up to three file names from `paths`, one per line
fn listNames(buf: []u8, paths: []const [:0]const u8) []const u8 {
    var len: usize = 0;
    for (paths[0..@min(paths.len, 3)]) |path| {
        const name = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];
        const line = std.fmt.bufPrint(buf[len..], "\n- {s}", .{name}) catch break;
        len += line.len;
    }
    return buf[0..len];
}

fn offerToDeleteRemoved() void {
    var names_buf: [256]u8 = undefined;
    const names = listNames(&names_buf, removed);
    const more = if (removed.len > 3) "\n- …" else "";
    const text = if (removed.len == 1)
        i18n.fmt(&dialog_text, .removed_found, .{ takeSummary(), names, more })
    else
        i18n.fmt(&dialog_text, .removed_found_many, .{ takeSummary(), removed.len, names, more });
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), text.ptr, t(.delete), t(.keep), removedAnswered);
}

/// Called by InkView with the number of the button that was pressed
fn removedAnswered(button: c_int) callconv(.c) void {
    const paths = removed;
    removed = &.{};
    if (button != 1) return;
    var deleted: usize = 0;
    for (paths) |path| {
        if (std.c.unlink(path.ptr) == 0) deleted += 1;
    }
    pocketbook.rescanLibrary(download_dir);
    var buf: [64]u8 = undefined;
    pb.Message(pb.ICON_INFORMATION, t(.app_title), i18n.fmt(&buf, .removed_deleted, .{deleted}).ptr, 3000);
}

/// The files of the Downloads folder that are not from a sync
fn untaggedFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (try files.list(allocator, download_dir)) |name| {
        if (!files.isTagged(name)) try names.append(allocator, name);
    }
    return names.toOwnedSlice(allocator);
}

/// Takes over a file that holds the book already, e.g. copied over USB: it is renamed to the
/// name of a synchronized book instead of downloading the book again. A file is only taken
/// when it has the format and the exact size the catalog gives, and the title in its name.
/// The adopted name is removed from `untagged`.
fn adopt(entry: xml.Entry, download: xml.Download, untagged: *[][]const u8) bool {
    if (download.size == 0) return false;
    const extension = download.format.extension();

    for (untagged.*, 0..) |name, i| {
        if (name.len <= extension.len + 1 or !std.mem.endsWith(u8, name, extension) or name[name.len - extension.len - 1] != '.') continue;
        if (!files.nameHasTitle(name, entry.title)) continue;

        var from_buf: [600]u8 = undefined;
        const from = std.fmt.bufPrintSentinel(&from_buf, "{s}/{s}", .{ download_dir, name }, 0) catch continue;
        if (files.size(from) != download.size) continue;

        var name_buf: [xml.max_sync_name]u8 = undefined;
        var to_buf: [600]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&to_buf, "{s}/{s}", .{ download_dir, entry.syncName(&name_buf, extension) }, 0) catch continue;
        if (std.c.rename(from.ptr, to.ptr) != 0) continue;

        trace("adopted {s}\n", .{name});
        untagged.*[i] = untagged.*[untagged.len - 1];
        untagged.len -= 1;
        return true;
    }
    return false;
}

/// Files of the Downloads folder that are exact copies of a synchronized book, kept while
/// the user is asked whether to delete them
var copies_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var copies: []const [:0]const u8 = &.{};

/// Finds the files that hold the same bytes as a synchronized book. Only exact copies count,
/// so nothing that differs in any way is ever offered for deletion.
fn findCopies() !void {
    _ = copies_arena.reset(.retain_capacity);
    copies = &.{};
    const allocator = copies_arena.allocator();

    const names = try files.list(allocator, download_dir);
    var tagged: std.ArrayList([:0]const u8) = .empty;
    var tagged_sizes: std.ArrayList(u64) = .empty;
    for (names) |name| {
        if (!files.isTagged(name)) continue;
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ download_dir, name }, 0);
        try tagged.append(allocator, path);
        try tagged_sizes.append(allocator, files.size(path) orelse 0);
    }

    var found: std.ArrayList([:0]const u8) = .empty;
    for (names) |name| {
        if (files.isTagged(name)) continue;
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ download_dir, name }, 0);
        const size = files.size(path) orelse continue;
        for (tagged.items, tagged_sizes.items) |other, other_size| {
            if (size == other_size and files.sameContent(path, other)) {
                try found.append(allocator, path);
                break;
            }
        }
    }
    copies = try found.toOwnedSlice(allocator);
}

var dialog_text: [1024]u8 = undefined;

fn offerToDeleteCopies() void {
    var names_buf: [256]u8 = undefined;
    const names = listNames(&names_buf, copies);
    const more = if (copies.len > 3) "\n- …" else "";
    const text = if (copies.len == 1)
        i18n.fmt(&dialog_text, .copy_found, .{ takeSummary(), names, more })
    else
        i18n.fmt(&dialog_text, .copies_found, .{ takeSummary(), copies.len, names, more });
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), text.ptr, t(.delete), t(.keep), copiesAnswered);
}

/// Called by InkView with the number of the button that was pressed
fn copiesAnswered(button: c_int) callconv(.c) void {
    const paths = copies;
    copies = &.{};
    if (button == 1) {
        var deleted: usize = 0;
        for (paths) |path| {
            if (std.c.unlink(path.ptr) == 0) deleted += 1;
        }
        pocketbook.rescanLibrary(download_dir);
        if (removed.len == 0) {
            var buf: [64]u8 = undefined;
            pb.Message(pb.ICON_INFORMATION, t(.app_title), i18n.fmt(&buf, .copies_deleted, .{deleted}).ptr, 3000);
            return;
        }
    }
    askNext();
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

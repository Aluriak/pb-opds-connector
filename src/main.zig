const builtin = @import("builtin");
const std = @import("std");
const net = @import("net.zig");
const utils = @import("utils.zig");
const xml = @import("xml.zig");

const pb = @import("c");

const APP_TITLE = @import("build_options").appName;

const CATALOGS = [_]xml.Entry{
    .{ .title = "Flibusta", .author = "flibusta.is", .nav_url = "http://flibusta.is/opds" },
    .{ .title = "Standard Ebooks (new releases)", .author = "standardebooks.org", .nav_url = "https://standardebooks.org/feeds/atom/new-releases" },
    .{ .title = "ManyBooks", .author = "manybooks.net", .nav_url = "https://manybooks.net/opds/index.php" },
    .{ .title = "Project Gutenberg", .author = "gutenberg.org", .nav_url = "https://www.gutenberg.org/ebooks.opds/" },
};

/// All downloads are stored into the "Downloads" folder.
/// The PocketBook scanner is asked to only re-scan this folder after a download.
const DOWNLOAD_DIR = "/mnt/ext1/Downloads";

const MAX_AUTHOR_IN_FILENAME = 60;
const MAX_TITLE_IN_FILENAME = 120;
/// "<author> - <title>.<ext>" at its longest
const MAX_FILENAME = MAX_AUTHOR_IN_FILENAME + " - ".len + MAX_TITLE_IN_FILENAME + ".fb2.zip".len;

const Feed = struct {
    /// Owns the entries and all their strings
    arena: std.heap.ArenaAllocator,
    entries: []const xml.Entry,
    /// Selected item, restored when coming back from a sub feed
    pos: c_int = 0,
};

// InkView callbacks carry no user pointer, so the app state lives here
var gpa: std.mem.Allocator = undefined;
var feeds: std.ArrayList(Feed) = .empty;
var started = false;

var item_height: c_int = 0;
var padding: c_int = 0;
var title_font: ?*pb.ifont = null;
var author_font: ?*pb.ifont = null;

// The format menu. InkView keeps pointers into these while the menu is open
var menu_items: [xml.MAX_DOWNLOADS + 2]pb.imenu = undefined;
var menu_texts: [xml.MAX_DOWNLOADS][160]u8 = undefined;
var menu_entry: xml.Entry = .{};

/// "Step" means a tenth of the file (or a megabyte, when the server doesn't give the size).
/// So the variable is what turns thousands of progress calls into about ten screen updates per download,
/// which matters on e-ink where each update is slow.
var progressStep: u64 = 0;

fn mainHandler(event_type: c_int, par1: c_int, par2: c_int) callconv(.c) c_int {
    trace("main event={d} par1={d} par2={d}\n", .{ event_type, par1, par2 });

    switch (event_type) {
        pb.EVT_INIT => {
            _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, APP_TITLE, null);

            item_height = @divTrunc(pb.ScreenHeight(), 10);
            padding = @divTrunc(item_height, 8);
            title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 4), 1);
            author_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(item_height, 5), 1);
        },
        pb.EVT_SHOW => {
            if (started) return 0;
            started = true;

            // The catalog list is the bottom of the feed stack, so Back from a catalog returns here
            feeds.append(gpa, .{ .arena = .init(gpa), .entries = &CATALOGS }) catch {
                pb.CloseApp();
                return 0;
            };
            showList();
        },
        pb.EVT_KEYPRESS => {
            // Only reached while no list is open
            if (par1 == pb.IV_KEY_BACK) pb.CloseApp();
        },
        pb.EVT_EXIT => {
            for (feeds.items) |*feed| feed.arena.deinit();
            feeds.deinit(gpa);
            if (title_font) |f| pb.CloseFont(f);
            if (author_font) |f| pb.CloseFont(f);
        },
        else => {},
    }

    return 0;
}

fn listHandler(action: c_int, x: c_int, y: c_int, idx: c_int, state: c_int) callconv(.c) c_int {
    trace("list action={d} idx={d} feeds={d}\n", .{ action, idx, feeds.items.len });

    if (feeds.items.len == 0) return 0;
    const feed = &feeds.items[feeds.items.len - 1];

    switch (action) {
        pb.LIST_PAINT => {
            if (idx < 0 or idx >= feed.entries.len) return 0;
            const entry = feed.entries[@intCast(idx)];

            const width = pb.ScreenWidth();
            const text_width = width - 2 * padding;
            const line_height = @divTrunc(item_height - 2 * padding, 2);
            const flags = pb.ALIGN_LEFT | pb.VALIGN_MIDDLE | pb.DOTS;

            pb.SetFont(title_font, pb.BLACK);
            _ = pb.DrawTextRect(x + padding, y + padding, text_width, line_height, entry.title.ptr, flags);
            pb.SetFont(author_font, pb.DGRAY);
            var detail_buf: [256]u8 = undefined;
            const detail = entryDetail(&detail_buf, entry);
            _ = pb.DrawTextRect(x + padding, y + padding + line_height, text_width, line_height, detail.ptr, flags);

            pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
            if (state != 0) pb.DrawSelection(x, y, width, item_height, pb.BLACK);
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= feed.entries.len) return 0;
            feed.pos = idx;
            const entry = feed.entries[@intCast(idx)];

            if (entry.downloads.len == 1) {
                downloadBook(entry, entry.downloads[0]);
            } else if (entry.downloads.len > 1) {
                openDownloadMenu(entry);
            } else if (entry.nav_url) |url| {
                // Pushes onto feeds, `feed` must not be used afterwards
                openFeed(url);
            } else {
                pb.Message(pb.ICON_INFORMATION, APP_TITLE, "Nothing to open for this entry.", 3000);
            }
        },
        pb.LIST_EXIT => {
            _ = pb.SetEventHandler(mainHandler);
            goBack();
        },
        else => return 0,
    }

    return 1;
}

fn showList() void {
    const feed = &feeds.items[feeds.items.len - 1];
    pb.OpenList(APP_TITLE, null, pb.ScreenWidth(), item_height, @intCast(feed.entries.len), feed.pos, listHandler);
}

fn goBack() void {
    var feed = feeds.pop() orelse return;
    feed.arena.deinit();

    if (feeds.items.len == 0) {
        pb.CloseApp();
        return;
    }

    showList();
}

fn openFeed(url: [:0]const u8) void {
    trace("openFeed {s}\n", .{url});

    loadFeed(url) catch |err| {
        trace("loadFeed failed: {s}\n", .{@errorName(err)});
        utils.showError(pb, APP_TITLE, "Could not open the catalog", err);
        return;
    };

    showList();
}

fn loadFeed(url: [:0]const u8) !void {
    if (!ensureNetwork()) return error.NoNetwork;

    pb.ShowHourglass();
    defer pb.HideHourglass();

    trace("network ok, fetching\n", .{});
    const body = try net.fetch(gpa, url);
    defer gpa.free(body);
    trace("fetched {d} bytes\n", .{body.len});

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const entries = try xml.parseOPDSFeed(arena.allocator(), body, url);
    trace("parsed {d} entries\n", .{entries.len});
    if (entries.len == 0) return error.EmptyFeed;

    try feeds.append(gpa, .{ .arena = arena, .entries = entries });
}

/// Second line of a row: the author, for book files followed by the formats on offer
fn entryDetail(buf: []u8, entry: xml.Entry) [:0]const u8 {
    if (entry.downloads.len == 0) return if (entry.author.len > 0) entry.author else entry.summary;

    // Leave room for the terminating zero
    const room = buf.len - 1;
    var len: usize = 0;
    if (std.fmt.bufPrint(buf[0..room], "{s}", .{entry.author})) |part| {
        len += part.len;
    } else |_| {}

    var formats: usize = 0;
    for (entry.downloads, 0..) |download, i| {
        // Several downloads of the same format are one format to the user
        const seen = for (entry.downloads[0..i]) |earlier| {
            if (earlier.format == download.format) break true;
        } else false;
        if (seen) continue;

        var format_buf: [16]u8 = undefined;
        const format = std.ascii.upperString(&format_buf, download.format.extension());

        const separator = if (formats > 0) ", " else if (len > 0) " - " else "";
        const part = std.fmt.bufPrint(buf[len..room], "{s}{s}", .{ separator, format }) catch break;
        len += part.len;
        formats += 1;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

/// Name and size of a download, e.g. "EPUB (no images), 0.5 MB". A download the catalog
/// gives no name is called after its format, e.g. "FB2.ZIP".
fn downloadText(buf: []u8, download: xml.Download) [:0]const u8 {
    var format_buf: [16]u8 = undefined;
    const name = if (download.label.len > 0)
        download.label
    else
        std.ascii.upperString(&format_buf, download.format.extension());

    if (download.size == 0) return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch "Download";

    const tenths_of_mb = download.size * 10 / (1024 * 1024);
    return std.fmt.bufPrintSentinel(buf, "{s}, {d}.{d} MB", .{ name, tenths_of_mb / 10, tenths_of_mb % 10 }, 0) catch "Download";
}

/// Lets the user pick one of several formats of the same book
fn openDownloadMenu(entry: xml.Entry) void {
    menu_entry = entry;

    menu_items[0] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast("Download"), .submenu = null };
    for (entry.downloads, 0..) |download, i| {
        const text = downloadText(&menu_texts[i], download);
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

fn onDownloadProgress(downloaded: u64, total: u64) void {
    // Steps of 10 percent, or of 1 MB when the server does not tell the size
    const step = if (total > 0) downloaded * 10 / total else downloaded / (1024 * 1024);
    if (step == progressStep) return;
    progressStep = step;

    var buf: [64]u8 = undefined;
    const tenths_of_mb = downloaded * 10 / (1024 * 1024);
    const text = std.fmt.bufPrintSentinel(&buf, "{d}.{d} MB", .{ tenths_of_mb / 10, tenths_of_mb % 10 }, 0) catch return;
    const percent: c_int = if (total > 0) @intCast(@min(100, downloaded * 100 / total)) else 0;
    _ = pb.UpdateProgressbar(text.ptr, percent);
}

fn downloadBook(entry: xml.Entry, download: xml.Download) void {
    var name_buf: [MAX_FILENAME]u8 = undefined;
    const filename = bookFilename(&name_buf, entry, download.format);

    if (!ensureNetwork()) {
        utils.showError(pb, APP_TITLE, "Could not download the book", error.NoNetwork);
        return;
    }

    progressStep = 0;
    pb.OpenProgressbar(pb.ICON_INFORMATION, "Downloading", entry.title.ptr, 0, null);
    net.download(download.url, DOWNLOAD_DIR, filename, onDownloadProgress) catch |err| {
        pb.CloseProgressbar();
        utils.showError(pb, APP_TITLE, "Could not download the book", err);
        return;
    };
    pb.CloseProgressbar();
    rescanLibrary();

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&msg_buf, "Saved to Downloads:\n{s}", .{filename}, 0) catch "Saved to Downloads.";
    pb.Message(pb.ICON_INFORMATION, APP_TITLE, msg.ptr, 3000);
}

/// Asks the reader's library scanner to index the download folder, so a new book shows up
/// in the library right away instead of after the next reboot.
fn rescanLibrary() void {
    const task = pb.FindTaskByAppName("scanner.app");
    trace("scanner task={d}\n", .{task});
    if (task == -1) return;

    // InkView wants a writable buffer
    var request = ("-scan:" ++ DOWNLOAD_DIR).*;
    const result = pb.SendRequestTo(task, pb.REQ_OPENBOOK, &request, request.len + 1, 0, 2000);
    trace("scan request result={d}\n", .{result});
}

/// Builds "<author> - <title>.<ext>". Hrefs often end in ids like /get/epub/12, so they make bad file names.
fn bookFilename(buf: *[MAX_FILENAME]u8, entry: xml.Entry, format: xml.BookFormat) []const u8 {
    var len = utils.cleanName(buf[0..MAX_AUTHOR_IN_FILENAME], entry.author, true);
    if (len > 0) {
        @memcpy(buf[len..][0..3], " - ");
        len += 3;
    }

    const title_len = utils.cleanName(buf[len..][0..MAX_TITLE_IN_FILENAME], entry.title, false);
    if (title_len > 0) {
        len += title_len;
    } else {
        @memcpy(buf[len..][0..4], "book");
        len += 4;
    }

    const ext = std.fmt.bufPrint(buf[len..], ".{s}", .{format.extension()}) catch unreachable;
    return buf[0 .. len + ext.len];
}

fn ensureNetwork() bool {
    if (pb.QueryNetwork() & pb.NET_CONNECTED != 0) return true;

    return pb.NetConnect(null) == pb.NET_OK;
}

/// Zig's own I/O layer makes system calls the reader's 3.10 kernel lacks, so write through libc.
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

pub fn main() void {
    trace("main started\n", .{});
    gpa = std.heap.c_allocator;
    pb.InkViewMain(mainHandler);
}

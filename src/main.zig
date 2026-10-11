const std = @import("std");

const net = @import("net.zig");
const utils = @import("utils.zig");
const xml = @import("xml.zig");
const server_form = @import("server_form.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;

const configuration = @import("configuration.zig");
const Server = @import("server.zig").Server;

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

const Feed = struct {
    /// Owns the entries and all their strings
    arena: std.heap.ArenaAllocator,
    entries: []const xml.Entry,
    /// Selected item, restored when coming back from a sub feed
    pos: c_int = 0,
    /// Where the catalog continues this list, null once everything is loaded
    next_url: ?[:0]const u8 = null,
    /// First entry of the screen the list currently shows
    top: c_int = 0,

    /// Appends the next page of the catalog to the entries
    fn loadMore(feed: *Feed) !void {
        const url = feed.next_url orelse return;

        const body = try net.fetch(gpa, url);
        defer gpa.free(body);

        const allocator = feed.arena.allocator();
        const parsed = try xml.parseOPDSFeed(allocator, body, url);

        feed.entries = try std.mem.concat(allocator, xml.Entry, &.{ feed.entries, parsed.entries });
        feed.next_url = if (parsed.entries.len == 0) null else parsed.next_url;
    }
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
/// Servers the user added, shown after the built-in catalogs
var custom_servers: std.ArrayList(Server) = .empty;
/// Rows of the start screen: built-in catalogs, custom servers, and the "Add server" row
var catalog_rows: std.ArrayList(xml.Entry) = .empty;
/// The custom server a delete question is open for
var server_index: ?usize = null;
var delete_text: [128]u8 = undefined;
/// Set while the next page of a list is waiting to be loaded
var more_pending = false;

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

            if (configuration.load(gpa)) |saved| {
                custom_servers = .fromOwnedSlice(saved);
            } else |err| trace("loading servers failed: {s}\n", .{@errorName(err)});

            // The catalog list is the bottom of the feed stack, so Back from a catalog returns here
            feeds.append(gpa, .{ .arena = .init(gpa), .entries = &.{} }) catch {
                pb.CloseApp();
                return 0;
            };
            rebuildCatalogRows() catch {
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
        pb.LIST_BEGINPAINT => feed.top = idx,
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
            const detail = entry.detail(&detail_buf);
            _ = pb.DrawTextRect(x + padding, y + padding + line_height, text_width, line_height, detail.ptr, flags);

            pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
            if (state != 0) pb.DrawSelection(x, y, width, item_height, pb.BLACK);

            // The last loaded entry is on screen: get the next page before the user runs out
            if (idx == feed.entries.len - 1 and feed.next_url != null and !more_pending) {
                more_pending = true;
                // Not from inside the painting, InkView has to finish this screen first.
                // The cast is needed because the C header declares timer functions without a parameter list
                pocketbook.later(loadMoreTimer);
            }
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= feed.entries.len) return 0;
            feed.pos = idx;
            const entry = feed.entries[@intCast(idx)];

            if (feeds.items.len == 1) {
                switch (catalogRow(@intCast(idx))) {
                    .add => {
                        // Necessarry, as we otherwise would overwrite the previously entred data.
                        server_index = null;
                        if (!server_form.open(gpa, null, serverEntered)) {
                            utils.showError(pb, APP_TITLE, "Could not open the form", error.NoSettingsFile);
                        }
                        return 1;
                    },
                    .custom => |server| net.useServer(server),
                    .builtin => net.useServer(null),
                }
            }

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
        pb.LIST_MENU => {
            // Long press or menu key: custom servers can be deleted
            if (feeds.items.len != 1 or idx < 0 or idx >= feed.entries.len) return 0;
            if (catalogRow(@intCast(idx)) != .custom) return 0;
            openServerMenu(@as(usize, @intCast(idx)) - CATALOGS.len);
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

const CatalogRow = union(enum) { builtin, custom: Server, add };

/// What a row of the start screen is. The order is the one rebuildCatalogRows puts them in.
fn catalogRow(row: usize) CatalogRow {
    if (row < CATALOGS.len) return .builtin;
    if (row < CATALOGS.len + custom_servers.items.len) return .{ .custom = custom_servers.items[row - CATALOGS.len] };
    return .add;
}

/// Puts the start screen together again after servers were loaded, added or deleted
fn rebuildCatalogRows() !void {
    catalog_rows.clearRetainingCapacity();
    try catalog_rows.appendSlice(gpa, &CATALOGS);
    for (custom_servers.items) |server| {
        try catalog_rows.append(gpa, .{ .title = server.name, .author = server.url, .nav_url = server.url });
    }
    try catalog_rows.append(gpa, .{ .title = "+ Add server", .summary = "Calibre or another OPDS server" });

    const start_screen = &feeds.items[0];
    start_screen.entries = catalog_rows.items;
    start_screen.pos = @min(start_screen.pos, @as(c_int, @intCast(catalog_rows.items.len - 1)));
}

/// Lets the user pick what to do with a server they added
fn openServerMenu(index: usize) void {
    server_index = index;

    menu_items[0] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast(custom_servers.items[index].name.ptr), .submenu = null };
    menu_items[1] = .{ .type = pb.ITEM_ACTIVE, .index = 1, .text = @constCast("Edit"), .submenu = null };
    menu_items[2] = .{ .type = pb.ITEM_ACTIVE, .index = 2, .text = @constCast("Delete"), .submenu = null };
    // A zeroed item ends the menu
    menu_items[3] = .{ .type = 0, .index = 0, .text = null, .submenu = null };

    pb.OpenMenu(&menu_items, 1, @divTrunc(pb.ScreenWidth(), 8), @divTrunc(pb.ScreenHeight(), 3), serverMenuHandler);
}

fn serverMenuHandler(index: c_int) callconv(.c) void {
    trace("server menu index={d}\n", .{index});
    const selected = server_index orelse return;

    switch (index) {
        1 => {
            if (!server_form.open(gpa, custom_servers.items[selected], serverEntered)) {
                utils.showError(pb, APP_TITLE, "Could not open the form", error.NoSettingsFile);
            }
        },
        2 => askDeleteServer(selected),
        // Anything else means the menu was closed without a choice
        else => {},
    }
}

/// Called when the "Add server" form was left
fn serverEntered(server: anyerror!?Server) void {
    trace("form closed\n", .{});
    saveServer(server) catch |err| utils.showError(pb, APP_TITLE, "Could not save the server", err);
    pocketbook.later(showListLater);
}

fn saveServer(entered: anyerror!?Server) !void {
    // No server means the form was left without a name or an address
    const server = (try entered) orelse return;
    trace("save server [{s}] {s} user=[{s}]\n", .{ server.name, server.url, server.user });

    if (server_index) |index| {
        custom_servers.items[index].free(gpa);
        custom_servers.items[index] = server;
        // The network layer may still point to the strings just released
        net.useServer(null);
    } else {
        errdefer server.free(gpa);
        try custom_servers.append(gpa, server);
    }
    configuration.store(custom_servers.items);
    try rebuildCatalogRows();
}

fn askDeleteServer(index: usize) void {
    const text = std.fmt.bufPrintSentinel(&delete_text, "Delete the server \"{s}\"?", .{custom_servers.items[index].name}, 0) catch "Delete this server?";
    pb.Dialog(pb.ICON_QUESTION, APP_TITLE, text.ptr, "Delete", "Cancel", deleteAnswered);
}

/// Called by InkView with the number of the button that was pressed
fn deleteAnswered(button: c_int) callconv(.c) void {
    trace("delete server answer={d}\n", .{button});
    const index = server_index orelse return;
    if (button != 1 or index >= custom_servers.items.len) return;

    custom_servers.orderedRemove(index).free(gpa);
    net.useServer(null);
    configuration.store(custom_servers.items);
    rebuildCatalogRows() catch return;
    pocketbook.later(showListLater);
}

fn showListLater() callconv(.c) void {
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
    if (!pocketbook.ensureNetwork()) return error.NoNetwork;

    pb.ShowHourglass();
    defer pb.HideHourglass();

    trace("network ok, fetching\n", .{});
    const body = try net.fetch(gpa, url);
    defer gpa.free(body);
    trace("fetched {d} bytes\n", .{body.len});

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const parsed = try xml.parseOPDSFeed(arena.allocator(), body, url);
    trace("parsed {d} entries, next={?s}\n", .{ parsed.entries.len, parsed.next_url });
    if (parsed.entries.len == 0) return error.EmptyFeed;

    try feeds.append(gpa, .{ .arena = arena, .entries = parsed.entries, .next_url = parsed.next_url });
}

/// Lets the user pick one of several formats of the same book
fn openDownloadMenu(entry: xml.Entry) void {
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

fn onDownloadProgress(downloaded: u64, total: u64) void {
    // Steps of 10 percent, or of 1 MB when the server does not tell the size
    const step = if (total > 0) downloaded * 10 / total else downloaded / (1024 * 1024);
    if (step == progressStep) return;
    progressStep = step;

    var buf: [64]u8 = undefined;
    var size_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{utils.formatSize(&size_buf, downloaded)}, 0) catch return;
    const percent: c_int = if (total > 0) @intCast(@min(100, downloaded * 100 / total)) else 0;
    _ = pb.UpdateProgressbar(text.ptr, percent);
}

/// Called by InkView shortly after the last loaded entry was painted.
/// Loads the next page and shows the same screen again, now with more behind it.
fn loadMoreTimer() callconv(.c) void {
    more_pending = false;
    if (feeds.items.len == 0) return;
    const feed = &feeds.items[feeds.items.len - 1];
    if (feed.next_url == null) return;

    pb.ShowHourglass();
    const loaded = if (pocketbook.ensureNetwork()) feed.loadMore() else error.NoNetwork;
    pb.HideHourglass();

    loaded catch |err| {
        trace("loadMore failed: {s}\n", .{@errorName(err)});
        // Do not try again on every repaint
        feed.next_url = null;
        utils.showError(pb, APP_TITLE, "Could not load more entries", err);
        return;
    };
    pb.OpenList(APP_TITLE, null, pb.ScreenWidth(), item_height, @intCast(feed.entries.len), feed.top, listHandler);
}

fn downloadBook(entry: xml.Entry, download: xml.Download) void {
    var name_buf: [xml.MAX_FILENAME]u8 = undefined;
    const filename = entry.saveName(&name_buf, download.format);

    if (!pocketbook.ensureNetwork()) {
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
    pocketbook.rescanLibrary(DOWNLOAD_DIR);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&msg_buf, "Saved to Downloads:\n{s}", .{filename}, 0) catch "Saved to Downloads.";
    pb.Message(pb.ICON_INFORMATION, APP_TITLE, msg.ptr, 3000);
}

pub fn main() void {
    trace("main started\n", .{});
    gpa = std.heap.c_allocator;
    pb.InkViewMain(mainHandler);
}

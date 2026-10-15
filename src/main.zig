const std = @import("std");
const net = @import("net.zig");
const xml = @import("xml.zig");
const server_form = @import("server_form.zig");
const download = @import("download.zig");
const search = @import("search.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;

const configuration = @import("configuration.zig");
const Server = @import("server.zig").Server;
const Catalogs = @import("server.zig").Catalogs;

const pb = @import("c");

const app_title = @import("build_options").app_name;

const Feed = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const xml.Entry,
    /// Selected item, restored when coming back from a sub feed
    pos: c_int = 0,
    /// Where the catalog continues this list, null once everything is loaded
    next_url: ?[:0]const u8 = null,
    /// First entry of the screen the list currently shows
    top: c_int = 0,
    /// How the catalog of this list is searched. If set, the first entry is the "Search" row
    search: ?search.Search = null,

    /// Appends the next page of the catalog to the entries
    fn loadMore(feed: *Feed) !void {
        const url = feed.next_url orelse return;

        const body = try net.fetch(gpa, url);
        defer gpa.free(body);

        const allocator = feed.arena.allocator();
        const parsed = try xml.parseOpdsFeed(allocator, body, url);

        feed.entries = try std.mem.concat(allocator, xml.Entry, &.{ feed.entries, parsed.entries });
        feed.next_url = if (parsed.entries.len == 0) null else parsed.next_url;
    }
};

/// InkView callbacks carry no user pointer, so the app state lives here
var gpa: std.mem.Allocator = undefined;

/// The app's navigation history: a stack of the list openend, one Feed per level
/// Whenever a new view is opened, it is pushed into this stack. Going back
/// is just a matter of popping out the top most view.
var feeds: std.ArrayList(Feed) = .empty;

var item_height: c_int = 0;
var padding: c_int = 0;
var title_font: ?*pb.ifont = null;
var author_font: ?*pb.ifont = null;

/// A list of servers, that show up on the start screen
var catalogs: Catalogs = .{};

/// The server an action (edit, delete) is ongoing for
var server_index: ?usize = null;
/// Set while the next page of a list is waiting to be loaded
var more_pending = false;
/// InkView writes what the user types on the keyboard into this
var search_text: [128]u8 = undefined;
// The menu of a server. InkView keeps pointers into it while the menu is open
var server_menu: [4]pb.imenu = undefined;

fn mainHandler(event_type: c_int, par1: c_int, par2: c_int) callconv(.c) c_int {
    trace("main event={d} par1={d} par2={d}\n", .{ event_type, par1, par2 });

    switch (event_type) {
        pb.EVT_INIT => {
            _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, app_title, null);

            item_height = @divTrunc(pb.ScreenHeight(), 10);
            padding = @divTrunc(item_height, 8);
            title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 4), 1);
            author_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(item_height, 5), 1);

            configuration.load(gpa, &catalogs.servers) catch |err| trace("loading servers failed: {s}\n", .{@errorName(err)});

            // The catalog list is the bottom of the feed stack, so Back from a catalog returns here
            feeds.append(gpa, .{ .arena = .init(gpa), .entries = &.{} }) catch {
                pb.CloseApp();
                return 0;
            };
            rebuildCatalogRows() catch {
                pb.CloseApp();
                return 0;
            };
        },
        // Also sent when the app comes back to the front, the list on top is shown again then
        pb.EVT_SHOW => if (feeds.items.len > 0) showList(),
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
                pb.SetWeakTimer("opds-step", @ptrCast(&loadMoreTimer), 100);
            }
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= feed.entries.len) return 0;
            feed.pos = idx;
            const entry = feed.entries[@intCast(idx)];

            if (feeds.items.len == 1) {
                // The row after the last catalog is "Add server"
                if (idx == catalogs.servers.items.len) {
                    // Necessarry, as we otherwise would overwrite the previously entered data.
                    server_index = null;
                    server_form.open(gpa, null, serverEntered);
                    return 1;
                }
                net.useServer(catalogs.servers.items[@intCast(idx)]);
            }

            if (entry.action == .search) {
                search_text[0] = 0;
                pb.OpenKeyboard("Search", &search_text, search_text.len - 1, pb.KBD_NORMAL, searchEntered);
            } else if (entry.action == .sync) {
                synchronize(feed);
                showList();
            } else if (entry.downloads.len > 0) {
                download.start(entry);
            } else if (entry.nav_url) |url| {
                // Pushes onto feeds, `feed` must not be used afterwards
                openFeed(url);
            } else {
                pb.Message(pb.ICON_INFORMATION, app_title, "Nothing to open for this entry.", 3000);
            }
        },
        pb.LIST_MENU => {
            // Long press or menu key: servers can be edited or deleted
            if (feeds.items.len != 1 or idx < 0 or idx >= catalogs.servers.items.len) return 0;
            server_index = @intCast(idx);
            openServerMenu();
        },
        // Handle the "back" action of a user, f. ex. clicking the _back_ button.
        // This can lead to the previous screen or closing the app.
        pb.LIST_EXIT => {
            _ = pb.SetEventHandler(mainHandler);

            var closed = feeds.pop() orelse return 1;
            closed.arena.deinit();

            // Close the app, if there is no feed left to display
            if (feeds.items.len == 0) {
                pb.CloseApp();
                return 1;
            }

            // Show the previous screen
            showList();
        },
        else => return 0,
    }

    return 1;
}

fn showList() void {
    const feed = &feeds.items[feeds.items.len - 1];
    pb.OpenList(listTitle(), null, pb.ScreenWidth(), item_height, @intCast(feed.entries.len), feed.pos, listHandler);
}

/// Inside a catalog the header names it, the start screen shows the name of the app
fn listTitle() [*:0]const u8 {
    if (feeds.items.len > 1) {
        if (net.currentServer()) |server| return server.name.ptr;
    }
    return app_title;
}

/// Loads the rest of the list, then downloads its books that are not on the reader yet
fn synchronize(feed: *Feed) void {
    if (feed.next_url != null) {
        if (!pocketbook.ensureNetwork()) {
            pocketbook.showError("Could not synchronize", error.NoNetwork);
            return;
        }
        pb.ShowHourglassForce();
        defer pb.HideHourglass();
        while (feed.next_url != null) {
            feed.loadMore() catch |err| {
                pocketbook.showError("Could not load the whole list", err);
                return;
            };
        }
    }
    download.synchronize(feed.entries);
}

/// Puts the start screen together again after servers were loaded, added or deleted
fn rebuildCatalogRows() !void {
    const start_screen = &feeds.items[0];
    // The rows live in the arena of the start screen, the old ones are dropped
    _ = start_screen.arena.reset(.retain_capacity);

    const rows = try start_screen.arena.allocator().alloc(xml.Entry, catalogs.servers.items.len + 1);
    for (catalogs.servers.items, 0..) |server, i| {
        rows[i] = .{ .title = server.name, .author = server.url, .nav_url = server.url };
    }
    rows[rows.len - 1] = .{ .title = "+ Add server", .summary = "Calibre or another OPDS server" };

    start_screen.entries = rows;
    start_screen.pos = @min(start_screen.pos, @as(c_int, @intCast(rows.len - 1)));
}

/// Lets the user pick what to do with a server
fn openServerMenu() void {
    const server = catalogs.servers.items[server_index.?];

    server_menu[0] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast(server.name.ptr), .submenu = null };
    server_menu[1] = .{ .type = pb.ITEM_ACTIVE, .index = 1, .text = @constCast("Edit"), .submenu = null };
    server_menu[2] = .{ .type = pb.ITEM_ACTIVE, .index = 2, .text = @constCast("Delete"), .submenu = null };
    // A zeroed item ends the menu
    server_menu[3] = .{ .type = 0, .index = 0, .text = null, .submenu = null };

    pb.OpenMenu(&server_menu, 1, @divTrunc(pb.ScreenWidth(), 8), @divTrunc(pb.ScreenHeight(), 3), serverMenuHandler);
}

fn serverMenuHandler(index: c_int) callconv(.c) void {
    trace("server menu index={d}\n", .{index});
    const selected = server_index orelse return;

    switch (index) {
        1 => server_form.open(gpa, catalogs.servers.items[selected], serverEntered),
        2 => pb.Dialog(pb.ICON_QUESTION, app_title, "Delete this server?", "Delete", "Cancel", deleteAnswered),
        // Anything else means the menu was closed without a choice
        else => {},
    }
}

/// Called when the "Add server" form was left
fn serverEntered(server: anyerror!?Server) void {
    saveServer(server) catch |err| pocketbook.showError("Could not save the server", err);
    showList();
}

fn saveServer(entered: anyerror!?Server) !void {
    // No server means the form was left without a name or an address
    const server = (try entered) orelse return;
    trace("save server [{s}] {s} user=[{s}]\n", .{ server.name, server.url, server.user });

    if (server_index) |index| {
        catalogs.servers.items[index].free(gpa);
        catalogs.servers.items[index] = server;
        // The network layer may still point to the strings just released
        net.useServer(null);
    } else {
        errdefer server.free(gpa);
        try catalogs.servers.append(gpa, server);
    }
    configuration.store(catalogs.servers.items);
    try rebuildCatalogRows();
}

/// Called by InkView with the number of the button that was pressed
fn deleteAnswered(button: c_int) callconv(.c) void {
    trace("delete server answer={d}\n", .{button});
    const index = server_index orelse return;
    if (button != 1 or index >= catalogs.servers.items.len) return;

    catalogs.servers.orderedRemove(index).free(gpa);
    net.useServer(null);
    configuration.store(catalogs.servers.items);
    rebuildCatalogRows() catch return;
    showList();
}

fn openFeed(url: [:0]const u8) void {
    trace("openFeed {s}\n", .{url});

    loadFeed(url) catch |err| {
        trace("loadFeed failed: {s}\n", .{@errorName(err)});
        pocketbook.showError("Could not open the catalog", err);
        return;
    };

    showList();
}

fn loadFeed(url: [:0]const u8) !void {
    if (!pocketbook.ensureNetwork()) return error.NoNetwork;

    // Use InkViews forced version to show the hourglass.
    // It did not work with the normal one.
    pb.ShowHourglassForce();
    defer pb.HideHourglass();

    trace("network ok, fetching\n", .{});
    const body = try net.fetch(gpa, url);
    defer gpa.free(body);
    trace("fetched {d} bytes\n", .{body.len});

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const parsed = try xml.parseOpdsFeed(arena.allocator(), body, url);
    trace("parsed {d} entries, next={?s}\n", .{ parsed.entries.len, parsed.next_url });
    if (parsed.entries.len == 0) return error.EmptyFeed;

    // A catalog that can be searched gets the "Search" row in front, a list of books of a
    // catalog that may be synchronized the "Synchronize" row
    const search_row: xml.Entry = .{ .action = .search, .title = "Search", .summary = "Search this catalog" };
    const sync_row: xml.Entry = .{ .action = .sync, .title = "Synchronize", .summary = "Download all books of this list that are not on the reader yet" };
    const has_books = for (parsed.entries) |entry| {
        if (entry.downloads.len > 0) break true;
    } else false;
    const may_sync = if (net.currentServer()) |server| server.options.sync else false;

    const rows: []const xml.Entry = if (parsed.search != null and has_books and may_sync)
        &.{ search_row, sync_row }
    else if (parsed.search != null)
        &.{search_row}
    else if (has_books and may_sync)
        &.{sync_row}
    else
        &.{};
    const entries = try std.mem.concat(arena.allocator(), xml.Entry, &.{ rows, parsed.entries });

    try feeds.append(gpa, .{ .arena = arena, .entries = entries, .next_url = parsed.next_url, .search = parsed.search });
}

/// Called by InkView when the keyboard of the search was closed, without a text if it was cancelled
fn searchEntered(typed: [*c]u8) callconv(.c) void {
    if (typed == null) return;
    const text = std.mem.trim(u8, std.mem.span(typed), " ");
    trace("search [{s}]\n", .{text});

    if (text.len > 0) {
        loadSearch(text) catch |err| switch (err) {
            error.EmptyFeed => pb.Message(pb.ICON_INFORMATION, app_title, "Nothing found.", 3000),
            else => pocketbook.showError("Could not search the catalog", err),
        };
    }
    showList();
}

/// Loads the results for `text` and puts them on top as a new list
fn loadSearch(text: []const u8) !void {
    const feed = &feeds.items[feeds.items.len - 1];
    const how = feed.search orelse return;

    const template = switch (how) {
        .template => |template| template,
        .description => |file_url| found: {
            if (!pocketbook.ensureNetwork()) return error.NoNetwork;
            const body = try net.fetch(gpa, file_url);
            defer gpa.free(body);

            const template = try search.readDescription(feed.arena.allocator(), body, file_url);
            // Kept, so the description file is loaded only once per list
            feed.search = .{ .template = template };
            break :found template;
        },
    };

    const url = try search.fill(gpa, template, text);
    defer gpa.free(url);
    // Pushes onto feeds, `feed` must not be used afterwards
    try loadFeed(url);
}

/// Called by InkView shortly after the last loaded entry was painted.
/// Loads the next page and shows the same screen again, now with more behind it.
fn loadMoreTimer() callconv(.c) void {
    more_pending = false;
    if (feeds.items.len == 0) return;
    const feed = &feeds.items[feeds.items.len - 1];
    if (feed.next_url == null) return;

    // Use InkViews forced version to show the hourglass.
    // It did not work with the normal one.
    pb.ShowHourglassForce();
    const loaded = if (pocketbook.ensureNetwork()) feed.loadMore() else error.NoNetwork;
    pb.HideHourglass();

    loaded catch |err| {
        trace("loadMore failed: {s}\n", .{@errorName(err)});
        // Do not try again on every repaint
        feed.next_url = null;
        pocketbook.showError("Could not load more entries", err);
        return;
    };
    pb.OpenList(listTitle(), null, pb.ScreenWidth(), item_height, @intCast(feed.entries.len), feed.top, listHandler);
}

pub fn main() void {
    trace("main started\n", .{});
    gpa = std.heap.c_allocator;
    pb.InkViewMain(mainHandler);
}

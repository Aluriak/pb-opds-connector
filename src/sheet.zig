//! The sheet of a book, shown before downloading it: its cover, title, author, details and
//! description, with a button to download it and one to go back. A long description goes
//! on over several pages: touching it, or the page keys, turns them.

const std = @import("std");
const pb = @import("c");

const covers = @import("covers.zig");
const download = @import("download.zig");
const i18n = @import("i18n.zig");
const pocketbook = @import("pocketbook.zig");
const xml = @import("xml.zig");
const t = i18n.t;
const trace = pocketbook.trace;

/// Called when the sheet is left, to show the list again
pub const CloseFn = *const fn () void;

var entry: xml.Entry = .{};
var on_close: CloseFn = undefined;
var cover: ?*pb.ibitmap = null;
var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
/// The lines of details under the author
var details: [:0]const u8 = "";

/// Where each page of the description starts; the last one is the page shown
var pages: [64]usize = undefined;
var page: usize = 0;
/// Whether the description goes on after the page shown
var more = false;

var title_font: ?*pb.ifont = null;
var text_font: ?*pb.ifont = null;
var small_font: ?*pb.ifont = null;

/// Where things are on screen, for the touches
const Rect = struct {
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,

    fn contains(r: Rect, x: c_int, y: c_int) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};
var download_button: Rect = .{};
var back_button: Rect = .{};
var description_area: Rect = .{};

/// Shows the sheet of `book`. Its strings must stay until `close` is called.
pub fn open(book: xml.Entry, close_fn: CloseFn, online: bool) void {
    entry = book;
    on_close = close_fn;
    pages[0] = 0;
    page = 0;
    _ = arena.reset(.retain_capacity);
    details = describe(arena.allocator()) catch "";

    const height = pb.ScreenHeight();
    title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(height, 38), 1);
    text_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(height, 48), 1);
    small_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(height, 56), 1);

    const box = coverBox();
    if (entry.cover_url orelse entry.thumbnail_url) |url| {
        if (!covers.isCached(url) and online) {
            pb.ShowHourglassForce();
            covers.fetch(url) catch |err| trace("cover not loaded: {s}\n", .{@errorName(err)});
            pb.HideHourglass();
        }
        cover = covers.load(url, box.w, box.h);
    }

    _ = pb.SetEventHandler(handler);
}

fn close() void {
    if (cover) |bitmap| covers.free(bitmap);
    cover = null;
    inline for (.{ &title_font, &text_font, &small_font }) |font| {
        if (font.*) |f| pb.CloseFont(f);
        font.* = null;
    }
    on_close();
}

fn handler(event_type: c_int, par1: c_int, par2: c_int) callconv(.c) c_int {
    switch (event_type) {
        pb.EVT_SHOW => draw(),
        pb.EVT_KEYPRESS => switch (par1) {
            pb.IV_KEY_BACK, pb.IV_KEY_MENU => close(),
            pb.IV_KEY_NEXT, pb.IV_KEY_NEXT2 => nextPage(),
            pb.IV_KEY_PREV, pb.IV_KEY_PREV2 => previousPage(),
            pb.IV_KEY_OK => download.start(entry),
            else => return 0,
        },
        pb.EVT_POINTERUP => {
            if (back_button.contains(par1, par2)) {
                close();
            } else if (download_button.contains(par1, par2)) {
                download.start(entry);
            } else if (description_area.contains(par1, par2)) {
                // The upper half goes back, the lower half goes on
                if (par2 < description_area.y + @divTrunc(description_area.h, 2) and page > 0) previousPage() else nextPage();
            } else return 0;
        },
        else => return 0,
    }
    return 1;
}

fn nextPage() void {
    if (!more or page + 1 >= pages.len) {
        // After the last page, the first one again
        if (page == 0) return;
        page = 0;
    } else {
        page += 1;
    }
    draw();
}

fn previousPage() void {
    if (page == 0) return;
    page -= 1;
    draw();
}

fn margin() c_int {
    return @divTrunc(pb.ScreenWidth(), 24);
}

fn coverBox() Rect {
    const m = margin();
    const w = @divTrunc(pb.ScreenWidth() * 9, 25);
    return .{ .x = m, .y = m, .w = w, .h = @divTrunc(w * 3, 2) };
}

/// The lines under the author: year, language, publisher, tags, formats with their size
fn describe(allocator: std.mem.Allocator) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const facts = [_][]const u8{ entry.year, entry.language, entry.publisher };
    var first = true;
    for (facts) |fact| {
        if (fact.len == 0) continue;
        if (!first) try out.appendSlice(allocator, " · ");
        try out.appendSlice(allocator, fact);
        first = false;
    }
    if (entry.categories.len > 0) {
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, entry.categories);
    }
    for (entry.downloads) |file| {
        var buf: [160]u8 = undefined;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, file.description(&buf));
    }
    return allocator.dupeSentinel(u8, out.items, 0);
}

fn draw() void {
    const width = pb.ScreenWidth();
    const height = pb.ScreenHeight();
    const m = margin();
    pb.ClearScreen();

    // The cover, or an empty frame in its place
    const box = coverBox();
    if (cover) |bitmap| {
        const bw: c_int = bitmap.width;
        const bh: c_int = bitmap.height;
        pb.DrawBitmap(box.x + @divTrunc(box.w - bw, 2), box.y + @divTrunc(box.h - bh, 2), bitmap);
    } else {
        pb.DrawRect(box.x, box.y, box.w, box.h, pb.LGRAY);
    }

    // Title, author and details beside it
    const x = box.x + box.w + m;
    const w = width - x - m;
    var y = box.y;
    const top = pb.ALIGN_LEFT | pb.VALIGN_TOP | pb.DOTS;
    pb.SetFont(title_font, pb.BLACK);
    const title_h = @min(pb.TextRectHeight(w, entry.title.ptr, 0), @divTrunc(box.h, 3));
    _ = pb.DrawTextRect(x, y, w, title_h, entry.title.ptr, top);
    y += title_h + @divTrunc(m, 2);
    if (entry.author.len > 0) {
        pb.SetFont(text_font, pb.DGRAY);
        const author_h = @min(pb.TextRectHeight(w, entry.author.ptr, 0), @divTrunc(box.h, 5));
        _ = pb.DrawTextRect(x, y, w, author_h, entry.author.ptr, top);
        y += author_h + @divTrunc(m, 2);
    }
    if (details.len > 0 and y < box.y + box.h) {
        pb.SetFont(small_font, pb.DGRAY);
        _ = pb.DrawTextRect(x, y, w, box.y + box.h - y, details.ptr, top);
    }

    // The buttons at the bottom
    const button_h = @divTrunc(height, 14);
    const button_w = @divTrunc(width - 3 * m, 2);
    const button_y = height - m - button_h;
    download_button = .{ .x = m, .y = button_y, .w = button_w, .h = button_h };
    back_button = .{ .x = 2 * m + button_w, .y = button_y, .w = button_w, .h = button_h };
    drawButton(download_button, t(.download), true);
    drawButton(back_button, t(.back), false);

    // The description between them, one page of it
    description_area = .{ .x = m, .y = box.y + box.h + m, .w = width - 2 * m, .h = button_y - m - (box.y + box.h + m) };
    const text = if (entry.description.len > 0) entry.description else entry.summary;
    pb.SetFont(text_font, pb.BLACK);
    const hint_h = @divTrunc(height, 40);
    const start = @min(pages[page], text.len);
    const rest = text[start..];
    const shown_h = description_area.h - hint_h;
    const stop = pb.DrawTextRect(description_area.x, description_area.y, description_area.w, shown_h, rest.ptr, pb.ALIGN_LEFT | pb.VALIGN_TOP);
    // DrawTextRect tells where it stopped: the next page starts there
    const used: usize = if (stop) |p| @intFromPtr(p) - @intFromPtr(rest.ptr) else rest.len;
    more = used > 0 and used < rest.len;
    if (more and page + 1 < pages.len) pages[page + 1] = start + used;
    if (more or page > 0) {
        pb.SetFont(small_font, pb.DGRAY);
        var hint_buf: [96]u8 = undefined;
        const hint = if (more) i18n.fmt(&hint_buf, .sheet_more, .{page + 1}) else i18n.fmt(&hint_buf, .sheet_end, .{page + 1});
        _ = pb.DrawTextRect(description_area.x, description_area.y + shown_h, description_area.w, hint_h, hint.ptr, pb.ALIGN_RIGHT | pb.VALIGN_MIDDLE);
    }

    pb.FullUpdate();
}

fn drawButton(r: Rect, text: [:0]const u8, main: bool) void {
    if (main) {
        pb.FillArea(r.x, r.y, r.w, r.h, pb.BLACK);
        pb.SetFont(text_font, pb.WHITE);
    } else {
        pb.DrawRect(r.x, r.y, r.w, r.h, pb.BLACK);
        pb.DrawRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, pb.BLACK);
        pb.SetFont(text_font, pb.BLACK);
    }
    _ = pb.DrawTextRect(r.x, r.y, r.w, r.h, text.ptr, pb.ALIGN_CENTER | pb.VALIGN_MIDDLE);
}

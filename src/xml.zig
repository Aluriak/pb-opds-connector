const std = @import("std");
const zigxml = @import("xml");
const utils = @import("utils.zig");

const REL_ACQUISITION = "http://opds-spec.org/acquisition";
const TYPE_ATOM = "application/atom+xml";

const MAX_AUTHOR_IN_FILENAME = 60;
const MAX_TITLE_IN_FILENAME = 120;
/// "<author> - <title>.<ext>" at its longest
pub const MAX_FILENAME = MAX_AUTHOR_IN_FILENAME + " - ".len + MAX_TITLE_IN_FILENAME + ".fb2.zip".len;

/// Upper bound per entry, so the format menu always fits on the screen
pub const MAX_DOWNLOADS = 8;

pub const BookFormat = enum {
    epub,
    pdf,
    fb2,
    fb2_zip,

    pub fn fromMime(mime: []const u8) ?BookFormat {
        if (std.mem.startsWith(u8, mime, "application/epub")) return .epub;
        if (std.mem.startsWith(u8, mime, "application/pdf")) return .pdf;
        if (std.mem.startsWith(u8, mime, "application/fb2+zip")) return .fb2_zip;
        if (std.mem.startsWith(u8, mime, "application/fb2")) return .fb2;
        if (std.mem.startsWith(u8, mime, "application/x-fictionbook")) return .fb2;
        return null;
    }

    pub fn extension(self: BookFormat) []const u8 {
        return switch (self) {
            .epub => "epub",
            .pdf => "pdf",
            .fb2 => "fb2",
            .fb2_zip => "fb2.zip",
        };
    }
};

/// Downlaod defines a single file for a single entry element.
/// As one entry may provide different files in different formats, the different
/// types are stored as download element per entry.
pub const Download = struct {
    label: [:0]const u8 = "",
    url: [:0]const u8,
    format: BookFormat,
    /// Size of the book file in bytes
    size: u64 = 0,

    /// Name and size for the format menu, e.g. "EPUB (no images), 547 KB".
    /// When there is no name it is called after its format, e.g. "FB2.ZIP".
    pub fn description(download: Download, buf: []u8) [:0]const u8 {
        var format_buf: [16]u8 = undefined;
        const name = if (download.label.len > 0)
            download.label
        else
            std.ascii.upperString(&format_buf, download.format.extension());

        if (download.size == 0) return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch "Download";

        var size_buf: [16]u8 = undefined;
        return std.fmt.bufPrintSentinel(buf, "{s}, {s}", .{ name, utils.formatSize(&size_buf, download.size) }, 0) catch "Download";
    }
};

/// This mirrors the structure of an entry element defined for the opds.
/// See: https://specs.opds.io/opds-1.1.html
pub const Entry = struct {
    title: [:0]const u8 = "",
    author: [:0]const u8 = "",
    nav_url: ?[:0]const u8 = null,
    downloads: []const Download = &.{},
    /// Plain text description coming from the interface.
    /// Some catalogs (Project Gutenberg) put the author of a listed book here.
    summary: [:0]const u8 = "",

    /// Second line of the entry in a list: the author, for book files followed by the formats
    /// on offer. Entries without an author show their description.
    pub fn detail(entry: Entry, buf: []u8) [:0]const u8 {
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

    /// Takes over what a link inside the entry points to: a book file to download,
    /// or another feed to open. The reader has to be at that link element.
    fn readLink(
        entry: *Entry,
        allocator: std.mem.Allocator,
        reader: *zigxml.Reader,
        base: std.Uri,
        downloads: *std.ArrayList(Download),
    ) !void {
        // Raw values are slices of the feed. rel and type never contain entities, the href may (&amp;)
        const rel = if (reader.attributeIndex("rel")) |i| reader.attributeValueRaw(i) else "";
        const mime = if (reader.attributeIndex("type")) |i| reader.attributeValueRaw(i) else "";
        const href_index = reader.attributeIndex("href") orelse return;

        // Different feeds use different fields:
        //   - Standard Books: Plain atom - enclosure
        //   - Others: XML feed - acquisition
        const is_acquisition = std.mem.startsWith(u8, rel, REL_ACQUISITION) or std.mem.eql(u8, rel, "enclosure");
        // Unknown types (e.g. text/html shop pages) are not downloadable books
        const format = if (is_acquisition) BookFormat.fromMime(mime) orelse return else null;
        if (!is_acquisition and !std.mem.startsWith(u8, mime, TYPE_ATOM)) return;

        const href = try reader.attributeValueAlloc(allocator, href_index);
        defer allocator.free(href);

        if (is_acquisition) {
            if (downloads.items.len >= MAX_DOWNLOADS) return;

            try downloads.append(allocator, .{
                .url = try resolveUrl(allocator, base, href),
                .format = format.?,
                .label = if (reader.attributeIndex("title")) |i|
                    try allocator.dupeSentinel(u8, try reader.attributeValue(i), 0)
                else
                    "",
                .size = if (reader.attributeIndex("length")) |i|
                    std.fmt.parseInt(u64, reader.attributeValueRaw(i), 10) catch 0
                else
                    0,
            });
        } else if (entry.nav_url == null) {
            entry.nav_url = try resolveUrl(allocator, base, href);
        }
    }

    /// Builds the name a download of this entry is saved under: "<author> - <title>.<ext>".
    pub fn saveName(entry: Entry, buf: *[MAX_FILENAME]u8, format: BookFormat) []const u8 {
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
};

/// This mirrors the structure of feed element defined for the opds.
/// See: https://specs.opds.io/opds-1.1.html
pub const Feed = struct {
    entries: []Entry = &.{},
    /// Catalogs deliver long lists in pages, this is the address of the next one
    next_url: ?[:0]const u8 = null,

    fn setEntries(feed: *Feed, allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) !void {
        feed.entries = try entries.toOwnedSlice(allocator);
    }

    fn readNextPageLink(feed: *Feed, allocator: std.mem.Allocator, reader: *zigxml.Reader, base: std.Uri) !void {
        const rel = if (reader.attributeIndex("rel")) |i| reader.attributeValueRaw(i) else "";
        if (!std.mem.eql(u8, rel, "next")) return;

        const href_index = reader.attributeIndex("href") orelse return;
        const href = try reader.attributeValueAlloc(allocator, href_index);
        defer allocator.free(href);

        feed.next_url = try resolveUrl(allocator, base, href);
    }
};

/// All strings of the returned entries are allocated with `allocator` and never freed
/// individually, so pass an arena.
pub fn parseOPDSFeed(allocator: std.mem.Allocator, xml_data: []const u8, base_url: []const u8) !Feed {
    const base = try std.Uri.parse(base_url);

    var feed: Feed = .{};
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var static_reader: zigxml.Reader.Static = .init(allocator, xml_data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var current: ?Entry = null;
    var downloads: std.ArrayList(Download) = .empty;
    defer downloads.deinit(allocator);

    var inside_author = false;

    while (true) {
        switch (try reader.read()) {
            .eof => break,
            .element_start => {
                // Local name, so prefixed feeds (<atom:entry>) work too
                const name = reader.elementNameNs().local;

                if (std.mem.eql(u8, name, "entry")) {
                    downloads.clearRetainingCapacity();
                    current = .{};
                    inside_author = false;
                    continue;
                }

                const entry = if (current) |*e| e else {
                    if (std.mem.eql(u8, name, "link")) try feed.readNextPageLink(allocator, reader, base);
                    continue;
                };

                if (std.mem.eql(u8, name, "title")) {
                    if (entry.title.len == 0) entry.title = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "author")) {
                    inside_author = true;
                } else if (inside_author and std.mem.eql(u8, name, "name")) {
                    if (entry.author.len == 0) entry.author = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "content") or std.mem.eql(u8, name, "summary")) {
                    // Only plain text, HTML descriptions are of no use in a list row
                    const kind = if (reader.attributeIndex("type")) |i| reader.attributeValueRaw(i) else "text";
                    if (entry.summary.len == 0 and std.mem.eql(u8, kind, "text")) {
                        entry.summary = try readText(allocator, reader);
                    }
                } else if (std.mem.eql(u8, name, "link")) {
                    try entry.readLink(allocator, reader, base, &downloads);
                }
            },
            .element_end => {
                const name = reader.elementNameNs().local;

                if (std.mem.eql(u8, name, "entry")) {
                    if (current) |*entry| {
                        if (sameBook(entries.items, entry.*, downloads.items)) |previous| {
                            // One row per book, the format menu offers all its downloads
                            previous.downloads = try std.mem.concat(allocator, Download, &.{ previous.downloads, downloads.items });
                        } else {
                            entry.downloads = try allocator.dupe(Download, downloads.items);
                            try entries.append(allocator, entry.*);
                        }
                    }
                    current = null;
                } else if (std.mem.eql(u8, name, "author")) {
                    inside_author = false;
                }
            },
            else => {},
        }
    }

    try feed.setEntries(allocator, &entries);
    return feed;
}

/// Some catalogs (Project Gutenberg) list a book once per variant, e.g. with and without images.
/// Returns the entry before `entry` if both are downloads of the same book.
fn sameBook(entries: []Entry, entry: Entry, downloads: []const Download) ?*Entry {
    if (entries.len == 0 or downloads.len == 0) return null;

    const previous = &entries[entries.len - 1];
    if (previous.downloads.len == 0) return null;
    if (previous.downloads.len + downloads.len > MAX_DOWNLOADS) return null;
    if (!std.mem.eql(u8, previous.title, entry.title)) return null;
    if (!std.mem.eql(u8, previous.author, entry.author)) return null;

    return previous;
}

fn readText(allocator: std.mem.Allocator, reader: *zigxml.Reader) ![:0]const u8 {
    const text = try reader.readElementText();

    return allocator.dupeSentinel(u8, std.mem.trim(u8, text, " \t\r\n"), 0);
}

/// Feeds mostly use relative hrefs, resolve them against the URL of the feed.
fn resolveUrl(allocator: std.mem.Allocator, base: std.Uri, href: []const u8) ![:0]const u8 {
    // resolveInPlace needs room behind the href for the merged path
    const buf = try allocator.alloc(u8, href.len * 2 + base.path.percent_encoded.len + 1);
    defer allocator.free(buf);

    @memcpy(buf[0..href.len], href);
    var aux_buf: []u8 = buf;
    const resolved = try base.resolveInPlace(href.len, &aux_buf);

    return std.fmt.allocPrintSentinel(allocator, "{f}", .{resolved.fmt(.all)}, 0);
}

/// TEST
fn expectSaveName(expected: []const u8, entry: Entry, format: BookFormat) !void {
    var buf: [MAX_FILENAME]u8 = undefined;
    try std.testing.expectEqualStrings(expected, entry.saveName(&buf, format));
}

test "saveName joins author, title and extension" {
    try expectSaveName("Austen, Jane - Pride and Prejudice.epub", .{ .author = "Austen, Jane", .title = "Pride and Prejudice" }, .epub);
}

test "saveName uses the extension of the format" {
    const entry: Entry = .{ .author = "Austen, Jane", .title = "Emma" };
    try expectSaveName("Austen, Jane - Emma.pdf", entry, .pdf);
    try expectSaveName("Austen, Jane - Emma.fb2", entry, .fb2);
    try expectSaveName("Austen, Jane - Emma.fb2.zip", entry, .fb2_zip);
}

test "saveName leaves out the author part when there is no author" {
    try expectSaveName("Pride and Prejudice.epub", .{ .title = "Pride and Prejudice" }, .epub);
    // An author made of nothing but stripped characters counts as none
    try expectSaveName("Pride and Prejudice.epub", .{ .author = "?!", .title = "Pride and Prejudice" }, .epub);
}

test "saveName falls back to 'book' when the title has nothing usable" {
    try expectSaveName("Austen, Jane - book.epub", .{ .author = "Austen, Jane", .title = "?!..." }, .epub);
    try expectSaveName("book.epub", .{}, .epub);
}

test "saveName cleans author and title by their own rules" {
    // Comma and hyphen stay in the author and are removed from the title
    try expectSaveName(
        "Saint-Exupéry, Antoine de - JeanChristophe vol 1.epub",
        .{ .author = "Saint-Exupéry, Antoine de", .title = "Jean-Christophe, vol. 1" },
        .epub,
    );
}

test "saveName cuts long authors and titles to fit its buffer" {
    const author: [100:0]u8 = @splat('a');
    const title: [300:0]u8 = @splat('t');

    var buf: [MAX_FILENAME]u8 = undefined;
    const name = (Entry{ .author = &author, .title = &title }).saveName(&buf, .fb2_zip);

    // 60 for the author, " - ", 120 for the title, ".fb2.zip": exactly the buffer
    try std.testing.expectEqual(MAX_FILENAME, name.len);
    try std.testing.expectEqual(60, std.mem.count(u8, name, "a"));
    try std.testing.expectEqual(120, std.mem.count(u8, name, "t"));
    try std.testing.expect(std.mem.endsWith(u8, name, "t.fb2.zip"));
}

fn expectDetail(expected: []const u8, entry: Entry) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, entry.detail(&buf));
}

/// A download of the given format
fn testDownload(format: BookFormat) Download {
    return .{ .url = "http://example.com/book123", .format = format };
}

test "detail shows the author of an entry without downloads" {
    try expectDetail("Austen, Jane", .{ .title = "Emma", .author = "Austen, Jane" });
}

test "detail falls back to the description when there is no author" {
    try expectDetail("Our most popular books.", .{ .title = "Popular", .summary = "Our most popular books." });
    // The author wins when both are there
    try expectDetail("Austen, Jane", .{ .author = "Austen, Jane", .summary = "A novel" });
}

test "detail is empty when the entry has nothing to show" {
    try expectDetail("", .{ .title = "Emma" });
}

test "detail lists the formats after the author" {
    try expectDetail("Austen, Jane - EPUB", .{ .author = "Austen, Jane", .downloads = &.{testDownload(.epub)} });
    try expectDetail("Austen, Jane - FB2.ZIP, EPUB", .{ .author = "Austen, Jane", .downloads = &.{ testDownload(.fb2_zip), testDownload(.epub) } });
}

test "detail lists only the formats when there is no author" {
    try expectDetail("PDF", .{ .downloads = &.{testDownload(.pdf)} });
    // The description is not shown for book files
    try expectDetail("PDF", .{ .summary = "A scanned book", .downloads = &.{testDownload(.pdf)} });
}

test "detail names each format once" {
    try expectDetail("Austen, Jane - EPUB", .{ .author = "Austen, Jane", .downloads = &.{ testDownload(.epub), testDownload(.epub), testDownload(.epub) } });
    try expectDetail("EPUB, PDF", .{ .downloads = &.{ testDownload(.epub), testDownload(.pdf), testDownload(.epub) } });
}

test "detail stops when the buffer is full" {
    var buf: [16]u8 = undefined;
    const entry: Entry = .{ .author = "Austen", .downloads = &.{ testDownload(.epub), testDownload(.fb2_zip) } };

    // "Austen - EPUB" fits into the 15 usable bytes, ", FB2.ZIP" does not
    try std.testing.expectEqualStrings("Austen - EPUB", entry.detail(&buf));
}

fn expectDescription(expected: []const u8, download: Download) !void {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(expected, download.description(&buf));
}

test "description shows the catalog's name and the size in kilobytes" {
    try expectDescription("EPUB (no images), 547 KB", .{ .url = "", .format = .epub, .label = "EPUB (no images)", .size = 561102 });
    try expectDescription("EPUB3, 23.6 MB", .{ .url = "", .format = .epub, .label = "EPUB3", .size = 24836548 });
}

test "description leaves the size out when the catalog does not give one" {
    try expectDescription("EPUB (no images)", .{ .url = "", .format = .epub, .label = "EPUB (no images)" });
}

test "description names a download without a label after its format" {
    try expectDescription("EPUB", .{ .url = "", .format = .epub });
    try expectDescription("FB2.ZIP", .{ .url = "", .format = .fb2_zip });
    try expectDescription("PDF, 1.0 MB", .{ .url = "", .format = .pdf, .size = 1024 * 1024 });
}

test "description falls back to a short text when it does not fit" {
    var buf: [8]u8 = undefined;
    const download: Download = .{ .url = "", .format = .epub, .label = "A label that is far too long" };

    try std.testing.expectEqualStrings("Download", download.description(&buf));
}

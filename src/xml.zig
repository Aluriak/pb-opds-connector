const std = @import("std");
const zigxml = @import("xml");
const utils = @import("utils.zig");
const Search = @import("search.zig").Search;

const rel_acquisition = "http://opds-spec.org/acquisition";
const rel_image = "http://opds-spec.org/image";
const rel_thumbnail = "http://opds-spec.org/image/thumbnail";

const max_author_in_filename = 60;
const max_title_in_filename = 120;
/// "<author> - <title>.<ext>" at its longest
pub const max_filename = max_author_in_filename + " - ".len + max_title_in_filename + ".fb2.zip".len;

/// "<author> - <title>.<16 hex digits of the id>.<ext>" at its longest
pub const max_sync_name = max_filename + ".".len + sync_tag_len;
comptime {
    // The extension of a file found on the reader may be any of these
    for (std.enums.values(BookFormat)) |format| std.debug.assert(format.extension().len <= ".fb2.zip".len);
}
/// The hash of an entry's id in the name of a synchronized book
pub const sync_tag_len = 16;

/// Upper bound per entry, so the format menu always fits on the screen
pub const max_downloads = 8;

pub const BookFormat = enum {
    epub,
    pdf,
    fb2,
    fb2_zip,
    mobi,
    azw3,
    txt,

    pub fn fromMime(mime: []const u8) ?BookFormat {
        if (std.mem.startsWith(u8, mime, "application/epub")) return .epub;
        if (std.mem.startsWith(u8, mime, "application/pdf")) return .pdf;
        if (std.mem.startsWith(u8, mime, "application/fb2+zip")) return .fb2_zip;
        if (std.mem.startsWith(u8, mime, "application/fb2")) return .fb2;
        if (std.mem.startsWith(u8, mime, "application/x-fictionbook")) return .fb2;
        if (std.mem.startsWith(u8, mime, "application/x-mobipocket-ebook")) return .mobi;
        if (std.mem.startsWith(u8, mime, "application/x-mobi8-ebook")) return .azw3;
        if (std.mem.startsWith(u8, mime, "text/plain")) return .txt;
        return null;
    }

    pub fn extension(self: BookFormat) []const u8 {
        return switch (self) {
            .epub => "epub",
            .pdf => "pdf",
            .fb2 => "fb2",
            .fb2_zip => "fb2.zip",
            .mobi => "mobi",
            .azw3 => "azw3",
            .txt => "txt",
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
    /// The <id> the catalog gives the entry. It stays the same when the title or author change.
    id: [:0]const u8 = "",
    /// Rows the app adds in front of a list do something instead of opening an entry
    action: Action = .none,
    title: [:0]const u8 = "",
    author: [:0]const u8 = "",
    nav_url: ?[:0]const u8 = null,
    downloads: []const Download = &.{},
    /// Plain text description coming from the interface.
    /// Some catalogs (Project Gutenberg) put the author of a listed book here.
    summary: [:0]const u8 = "",
    /// The whole description, HTML turned into text, for the sheet of the book
    description: [:0]const u8 = "",
    /// Pictures of the cover, full size and small
    cover_url: ?[:0]const u8 = null,
    thumbnail_url: ?[:0]const u8 = null,
    /// The year the book was published, as the catalog gives it
    year: [:0]const u8 = "",
    language: [:0]const u8 = "",
    publisher: [:0]const u8 = "",
    /// Tags of the book, comma separated
    categories: [:0]const u8 = "",

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
        const image: enum { none, cover, thumbnail } = if (std.mem.eql(u8, rel, rel_thumbnail) or std.mem.eql(u8, rel, "x-stanza-cover-image-thumbnail"))
            .thumbnail
        else if (std.mem.eql(u8, rel, rel_image) or std.mem.eql(u8, rel, "x-stanza-cover-image"))
            .cover
        else
            .none;
        if (image != .none) {
            const href = try reader.attributeValueAlloc(allocator, href_index);
            defer allocator.free(href);
            const url = try resolveUrl(allocator, base, href);
            switch (image) {
                .cover => if (entry.cover_url == null) {
                    entry.cover_url = url;
                },
                .thumbnail => if (entry.thumbnail_url == null) {
                    entry.thumbnail_url = url;
                },
                .none => unreachable,
            }
            return;
        }

        const is_acquisition = std.mem.startsWith(u8, rel, rel_acquisition) or std.mem.eql(u8, rel, "enclosure");
        // Unknown types (e.g. text/html shop pages) are not downloadable books
        const format = if (is_acquisition) BookFormat.fromMime(mime) orelse return else null;
        if (!is_acquisition and !std.mem.startsWith(u8, mime, LinkType.atom.mime())) return;

        const href = try reader.attributeValueAlloc(allocator, href_index);
        defer allocator.free(href);

        if (is_acquisition) {
            if (downloads.items.len >= max_downloads) return;

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

    pub const Action = enum { none, search, sync, language, pick_language };

    /// The hash of the entry's id that names a synchronized book, as 16 hex digits.
    /// It stays the same when the title or author change in the catalog.
    pub fn syncTag(entry: Entry) [sync_tag_len]u8 {
        var tag: [sync_tag_len]u8 = undefined;
        _ = std.fmt.bufPrint(&tag, "{x:0>16}", .{std.hash.Wyhash.hash(0, entry.id)}) catch unreachable;
        return tag;
    }

    /// The name a synchronized book is saved under: "<author> - <title>.<tag>.<ext>".
    /// The sync finds a book by its tag alone, whatever the rest of the name became.
    pub fn syncName(entry: Entry, buf: *[max_sync_name]u8, extension: []const u8) []const u8 {
        const len = entry.writeStem(buf[0..max_filename]);
        const rest = std.fmt.bufPrint(buf[len..], ".{s}.{s}", .{ entry.syncTag(), extension }) catch unreachable;
        return buf[0 .. len + rest.len];
    }

    /// Builds the name a download of this entry is saved under: "<author> - <title>.<ext>".
    pub fn saveName(entry: Entry, buf: *[max_filename]u8, format: BookFormat) []const u8 {
        const len = entry.writeStem(buf);
        const ext = std.fmt.bufPrint(buf[len..], ".{s}", .{format.extension()}) catch unreachable;
        return buf[0 .. len + ext.len];
    }

    /// Writes "<author> - <title>" to the start of `buf`, returns its length
    fn writeStem(entry: Entry, buf: *[max_filename]u8) usize {
        var len = utils.cleanName(buf[0..max_author_in_filename], entry.author, true);
        if (len > 0) {
            @memcpy(buf[len..][0..3], " - ");
            len += 3;
        }

        const title_len = utils.cleanName(buf[len..][0..max_title_in_filename], entry.title, false);
        if (title_len > 0) {
            len += title_len;
        } else {
            @memcpy(buf[len..][0..4], "book");
            len += 4;
        }
        return len;
    }
};

/// The kinds of search link a feed can have.
const LinkType = enum {
    atom,
    opensearch,

    fn mime(kind: LinkType) []const u8 {
        return switch (kind) {
            .atom => "application/atom+xml",
            .opensearch => "application/opensearchdescription+xml",
        };
    }

    fn fromMime(text: []const u8) ?LinkType {
        inline for (comptime std.enums.values(LinkType)) |kind| {
            if (std.mem.startsWith(u8, text, kind.mime())) return kind;
        }
        return null;
    }
};

/// This mirrors the structure of feed element defined for the opds.
/// See: https://specs.opds.io/opds-1.1.html
pub const Feed = struct {
    base_uri: std.Uri,
    entries: []Entry = &.{},
    /// Catalogs deliver long lists in pages, this is the address of the next one
    next_url: ?[:0]const u8 = null,
    /// How the catalog can be searched, null if it offers no search
    search: ?Search = null,

    fn setEntries(feed: *Feed, allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) !void {
        feed.entries = try entries.toOwnedSlice(allocator);
    }

    fn readNextPageLink(feed: *Feed, allocator: std.mem.Allocator, reader: *zigxml.Reader) !void {
        const rel = if (reader.attributeIndex("rel")) |i| reader.attributeValueRaw(i) else "";
        if (!std.mem.eql(u8, rel, "next")) return;

        const href_index = reader.attributeIndex("href") orelse return;
        const href = try reader.attributeValueAlloc(allocator, href_index);
        defer allocator.free(href);

        feed.next_url = try resolveUrl(allocator, feed.base_uri, href);
    }

    /// A feed may give the address for a search directly, point to a description file
    /// that contains it, or do both. The direct address is preferred, as no file needs to be loaded.
    fn readSearchLink(feed: *Feed, allocator: std.mem.Allocator, reader: *zigxml.Reader) !void {
        const rel = if (reader.attributeIndex("rel")) |i| reader.attributeValueRaw(i) else "";
        if (!std.mem.eql(u8, rel, "search")) return;

        const mime = if (reader.attributeIndex("type")) |i| reader.attributeValueRaw(i) else "";
        const kind = LinkType.fromMime(mime) orelse return;
        if (feed.search) |found| {
            if (found == .template or kind == .opensearch) return;
        }

        const href_index = reader.attributeIndex("href") orelse return;
        const href = try reader.attributeValueAlloc(allocator, href_index);
        defer allocator.free(href);
        if (kind == .atom and std.mem.indexOf(u8, href, "{searchTerms}") == null) return;

        const url = try resolveUrl(allocator, feed.base_uri, href);
        feed.search = switch (kind) {
            .atom => .{ .template = url },
            .opensearch => .{ .description = url },
        };
    }
};

/// All strings of the returned entries are allocated with `allocator` and never freed
/// individually, so pass an arena.
pub fn parseOpdsFeed(allocator: std.mem.Allocator, xml_data: []const u8, base_url: []const u8) !Feed {
    var feed: Feed = .{ .base_uri = try std.Uri.parse(base_url) };
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
                    if (std.mem.eql(u8, name, "link")) {
                        try feed.readNextPageLink(allocator, reader);
                        try feed.readSearchLink(allocator, reader);
                    }
                    continue;
                };

                if (std.mem.eql(u8, name, "id")) {
                    if (entry.id.len == 0) entry.id = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "title")) {
                    if (entry.title.len == 0) entry.title = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "author")) {
                    inside_author = true;
                } else if (inside_author and std.mem.eql(u8, name, "name")) {
                    if (entry.author.len == 0) entry.author = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "content") or std.mem.eql(u8, name, "summary")) {
                    // Only plain text goes in a list row, the sheet of the book takes any kind
                    const kind = if (reader.attributeIndex("type")) |i| reader.attributeValueRaw(i) else "text";
                    const text = if (std.mem.eql(u8, kind, "xhtml"))
                        try readRichText(allocator, reader)
                    else if (std.mem.eql(u8, kind, "html"))
                        try utils.htmlToText(allocator, try reader.readElementText())
                    else
                        try readText(allocator, reader);
                    if (entry.summary.len == 0 and std.mem.eql(u8, kind, "text")) entry.summary = text;
                    if (text.len > entry.description.len) entry.description = text;
                } else if (std.mem.eql(u8, name, "issued") or std.mem.eql(u8, name, "published")) {
                    // dc:issued is when the book came out, Atom's published may be too
                    const text = try readText(allocator, reader);
                    if (entry.year.len == 0 or std.mem.eql(u8, name, "issued")) entry.year = yearOf(text);
                } else if (std.mem.eql(u8, name, "language")) {
                    if (entry.language.len == 0) entry.language = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "publisher")) {
                    if (entry.publisher.len == 0) entry.publisher = try readText(allocator, reader);
                } else if (std.mem.eql(u8, name, "category")) {
                    const index = reader.attributeIndex("label") orelse reader.attributeIndex("term");
                    if (index) |i| {
                        const label = std.mem.trim(u8, try reader.attributeValue(i), " ");
                        if (label.len > 0) {
                            const sep = if (entry.categories.len > 0) ", " else "";
                            entry.categories = try std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ entry.categories, sep, label }, 0);
                        }
                    }
                } else if (std.mem.eql(u8, name, "link")) {
                    try entry.readLink(allocator, reader, feed.base_uri, &downloads);
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
    if (previous.downloads.len + downloads.len > max_downloads) return null;
    if (!std.mem.eql(u8, previous.title, entry.title)) return null;
    if (!std.mem.eql(u8, previous.author, entry.author)) return null;

    return previous;
}

/// The year at the start of a date ("2019-04-01T00:00:00+00:00"), or the text when it has none
fn yearOf(text: [:0]const u8) [:0]const u8 {
    if (text.len > 4 and std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and std.ascii.isDigit(text[2]) and std.ascii.isDigit(text[3]) and text[4] == '-') {
        // The text is ours, from readText: the year ends where the month starts
        const owned: [*]u8 = @constCast(text.ptr);
        owned[4] = 0;
        return text[0..4 :0];
    }
    return text;
}

/// The text of an element holding XHTML, with its paragraphs and line breaks
fn readRichText(allocator: std.mem.Allocator, reader: *zigxml.Reader) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var depth: usize = 0;
    while (true) {
        switch (try reader.read()) {
            .element_start => {
                depth += 1;
                if (utils.isBlockTag(reader.elementNameNs().local)) try out.append(allocator, '\n');
            },
            .element_end => {
                if (depth == 0) break;
                depth -= 1;
                if (utils.isBlockTag(reader.elementNameNs().local)) try out.append(allocator, '\n');
            },
            .text => try out.appendSlice(allocator, reader.textRaw()),
            .cdata => try out.appendSlice(allocator, reader.cdataRaw()),
            .character_reference => {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(reader.characterReferenceChar(), &utf8) catch 0;
                try out.appendSlice(allocator, utf8[0..n]);
            },
            .entity_reference => {
                const char = utils.decodeEntity(reader.entityReferenceName()) orelse '?';
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(char, &utf8) catch 0;
                try out.appendSlice(allocator, utf8[0..n]);
            },
            .eof => break,
            else => {},
        }
    }
    return utils.tidyText(allocator, out.items);
}

fn readText(allocator: std.mem.Allocator, reader: *zigxml.Reader) ![:0]const u8 {
    const text = try reader.readElementText();

    return allocator.dupeSentinel(u8, std.mem.trim(u8, text, " \t\r\n"), 0);
}

/// Feeds mostly use relative hrefs, resolve them against the URL of the feed.
pub fn resolveUrl(allocator: std.mem.Allocator, base: std.Uri, href: []const u8) ![:0]const u8 {
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
    var buf: [max_filename]u8 = undefined;
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
    try expectSaveName("Austen, Jane - Emma.mobi", entry, .mobi);
    try expectSaveName("Austen, Jane - Emma.azw3", entry, .azw3);
    try expectSaveName("Austen, Jane - Emma.txt", entry, .txt);
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

    var buf: [max_filename]u8 = undefined;
    const name = (Entry{ .author = &author, .title = &title }).saveName(&buf, .fb2_zip);

    // 60 for the author, " - ", 120 for the title, ".fb2.zip": exactly the buffer
    try std.testing.expectEqual(max_filename, name.len);
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

test "fromMime knows the formats the reader opens" {
    try std.testing.expectEqual(.epub, BookFormat.fromMime("application/epub+zip"));
    try std.testing.expectEqual(.pdf, BookFormat.fromMime("application/pdf"));
    try std.testing.expectEqual(.fb2, BookFormat.fromMime("application/fb2"));
    try std.testing.expectEqual(.fb2, BookFormat.fromMime("application/x-fictionbook+xml"));
    try std.testing.expectEqual(.fb2_zip, BookFormat.fromMime("application/fb2+zip"));
    try std.testing.expectEqual(.mobi, BookFormat.fromMime("application/x-mobipocket-ebook"));
    try std.testing.expectEqual(.azw3, BookFormat.fromMime("application/x-mobi8-ebook"));
    try std.testing.expectEqual(.txt, BookFormat.fromMime("text/plain"));
    try std.testing.expectEqual(.txt, BookFormat.fromMime("text/plain; charset=utf-8"));
}

test "fromMime ignores what is not a book" {
    try std.testing.expectEqual(null, BookFormat.fromMime("text/html"));
    try std.testing.expectEqual(null, BookFormat.fromMime("image/jpeg"));
    try std.testing.expectEqual(null, BookFormat.fromMime(""));
}

test "description falls back to a short text when it does not fit" {
    var buf: [8]u8 = undefined;
    const download: Download = .{ .url = "", .format = .epub, .label = "A label that is far too long" };

    try std.testing.expectEqualStrings("Download", download.description(&buf));
}

fn expectSearch(expected: ?Search, links: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data = try std.fmt.allocPrint(arena.allocator(), "<feed xmlns=\"http://www.w3.org/2005/Atom\">{s}</feed>", .{links});
    const feed = try parseOpdsFeed(arena.allocator(), data, "http://calibre.lan:8080/opds");
    try std.testing.expectEqualDeep(expected, feed.search);
}

test "a feed without a search link offers no search" {
    try expectSearch(null, "<link rel=\"start\" type=\"application/atom+xml\" href=\"/opds\"/>");
}

test "the search address of a feed is completed with the server" {
    try expectSearch(
        .{ .template = "http://calibre.lan:8080/opds/search/{searchTerms}" },
        "<link rel=\"search\" type=\"application/atom+xml\" href=\"/opds/search/{searchTerms}\"/>",
    );
}

test "a feed may point to a description file for its search" {
    try expectSearch(
        .{ .description = "https://www.gutenberg.org/catalog/osd-books.xml" },
        "<link rel=\"search\" type=\"application/opensearchdescription+xml\" href=\"https://www.gutenberg.org/catalog/osd-books.xml\"/>",
    );
}

test "the direct search address wins over the description file, in any order" {
    const direct = "<link rel=\"search\" type=\"application/atom+xml\" href=\"/opds/search?searchTerm={searchTerms}\"/>";
    const file = "<link rel=\"search\" type=\"application/opensearchdescription+xml\" href=\"/opds-opensearch.xml\"/>";
    const expected: Search = .{ .template = "http://calibre.lan:8080/opds/search?searchTerm={searchTerms}" };

    try expectSearch(expected, file ++ direct);
    try expectSearch(expected, direct ++ file);
}

test "a search link of an unknown kind is ignored" {
    try expectSearch(null, "<link rel=\"search\" type=\"text/html\" href=\"/search?q={searchTerms}\"/>");
    try expectSearch(null, "<link rel=\"search\" type=\"application/atom+xml\" href=\"/opds/all\"/>");
}

test "entries keep their id, the id of the feed itself is not taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data =
        \\<feed xmlns="http://www.w3.org/2005/Atom"><id>urn:feed</id>
        \\<entry><id>urn:uuid:1b8f</id><title>Dune</title>
        \\<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/get/epub/1"/></entry>
        \\</feed>
    ;
    const feed = try parseOpdsFeed(arena.allocator(), data, "http://calibre.lan:8080/opds");
    try std.testing.expectEqual(1, feed.entries.len);
    try std.testing.expectEqualStrings("urn:uuid:1b8f", feed.entries[0].id);
}

test "the sheet of a book gets its description, cover and details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data =
        \\<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/"><id>urn:feed</id>
        \\<entry><id>urn:uuid:1b8f</id><title>Le Temps d'après</title>
        \\<dc:issued>1996-01-01</dc:issued><dc:language>fra</dc:language><dc:publisher>Gallmeister</dc:publisher>
        \\<category term="Roman" label="Roman"/><category term="SF"/>
        \\<content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Deux s&#339;urs.</p><p>La for&#234;t &amp; la maison.</p></div></content>
        \\<link rel="http://opds-spec.org/image" type="image/jpeg" href="/opds/cover/1"/>
        \\<link rel="http://opds-spec.org/image/thumbnail" type="image/jpeg" href="/opds/cover_240_240/1"/>
        \\<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/get/epub/1"/></entry>
        \\<entry><title>HTML</title><summary type="text">Short</summary><content type="html">&lt;p&gt;A &amp;amp; B&lt;/p&gt;&lt;p&gt;C&lt;/p&gt;</content>
        \\<published>2019-04-01T00:00:00+00:00</published></entry>
        \\</feed>
    ;
    const feed = try parseOpdsFeed(arena.allocator(), data, "http://calibre.lan:8080/opds");
    const book = feed.entries[0];
    try std.testing.expectEqualStrings("Deux sœurs.\n\nLa forêt & la maison.", book.description);
    try std.testing.expectEqualStrings("", book.summary);
    try std.testing.expectEqualStrings("http://calibre.lan:8080/opds/cover/1", book.cover_url.?);
    try std.testing.expectEqualStrings("http://calibre.lan:8080/opds/cover_240_240/1", book.thumbnail_url.?);
    try std.testing.expectEqualStrings("1996", book.year);
    try std.testing.expectEqualStrings("fra", book.language);
    try std.testing.expectEqualStrings("Gallmeister", book.publisher);
    try std.testing.expectEqualStrings("Roman, SF", book.categories);
    try std.testing.expectEqual(1, book.downloads.len);

    const other = feed.entries[1];
    try std.testing.expectEqualStrings("Short", other.summary);
    try std.testing.expectEqualStrings("A & B\n\nC", other.description);
    try std.testing.expectEqualStrings("2019", other.year);
}

test "syncName gives author and title, then the tag of the id" {
    var buf: [max_sync_name]u8 = undefined;
    const entry: Entry = .{ .id = "urn:uuid:1b8f", .title = "Le Temps d'après", .author = "Jean Hegland" };
    const tag = entry.syncTag();
    const expected = "Jean Hegland - Le Temps d'après." ++ tag ++ ".epub";
    try std.testing.expectEqualStrings(expected, entry.syncName(&buf, "epub"));
}

test "syncTag depends on the id only" {
    const before: Entry = .{ .id = "urn:uuid:1b8f", .title = "Dune", .author = "Frank Herbert" };
    const after: Entry = .{ .id = "urn:uuid:1b8f", .title = "Dune (new edition)", .author = "F. Herbert" };
    const other: Entry = .{ .id = "urn:uuid:2c9a", .title = "Dune", .author = "Frank Herbert" };

    try std.testing.expectEqualStrings(&before.syncTag(), &after.syncTag());
    try std.testing.expect(!std.mem.eql(u8, &before.syncTag(), &other.syncTag()));
    for (before.syncTag()) |char| try std.testing.expect(std.ascii.isHex(char));
}

test "syncName fits its buffer with the longest author, title and format" {
    var buf: [max_sync_name]u8 = undefined;
    const long: [300:0]u8 = @splat('x');
    const entry: Entry = .{ .id = "urn:uuid:1b8f", .title = &long, .author = &long };
    const name = entry.syncName(&buf, "fb2.zip");
    try std.testing.expect(std.mem.endsWith(u8, name, ".fb2.zip"));
}

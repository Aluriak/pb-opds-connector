const std = @import("std");
const zigxml = @import("xml");

const REL_ACQUISITION = "http://opds-spec.org/acquisition";
const TYPE_ATOM = "application/atom+xml";

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
};

/// All strings of the returned entries are allocated with `allocator` and never freed
/// individually, so pass an arena.
pub fn parseOPDSFeed(allocator: std.mem.Allocator, xml_data: []const u8, base_url: []const u8) ![]Entry {
    const base = try std.Uri.parse(base_url);

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

                const entry = if (current) |*e| e else continue;

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
                    try readLink(allocator, reader, base, entry, &downloads);
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

    return entries.toOwnedSlice(allocator);
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

fn readLink(
    allocator: std.mem.Allocator,
    reader: *zigxml.Reader,
    base: std.Uri,
    entry: *Entry,
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

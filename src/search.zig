//! Searching a catalog. A feed says how its catalog is searched (see `Search`), this file
//! turns that and the text the user typed into the address of the result feed.
const std = @import("std");
const zigxml = @import("xml");
const xml = @import("xml.zig");

/// How a catalog can be searched, taken from the <link rel="search"> of its feed
pub const Search = union(enum) {
    /// The address of the results, with the placeholder {searchTerms} for the text
    template: [:0]const u8,
    /// The address of an OpenSearch description file, which contains the template
    description: [:0]const u8,
};

/// Finds the template in an OpenSearch description file. A file may list several addresses,
/// for web pages and for feeds: a feed made for OPDS is the first choice.
pub fn readDescription(allocator: std.mem.Allocator, xml_data: []const u8, base_url: []const u8) ![:0]const u8 {
    const base = try std.Uri.parse(base_url);

    var static_reader: zigxml.Reader.Static = .init(allocator, xml_data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var found: ?[:0]const u8 = null;
    errdefer if (found) |template| allocator.free(template);

    while (true) {
        switch (try reader.read()) {
            .eof => break,
            .element_start => {
                if (!std.mem.eql(u8, reader.elementNameNs().local, "Url")) continue;

                const mime = if (reader.attributeIndex("type")) |i| reader.attributeValueRaw(i) else "";
                if (!std.mem.startsWith(u8, mime, "application/atom+xml")) continue;
                const for_opds = std.mem.indexOf(u8, mime, "opds-catalog") != null;
                if (found != null and !for_opds) continue;

                const template_index = reader.attributeIndex("template") orelse continue;
                const template = try reader.attributeValueAlloc(allocator, template_index);
                defer allocator.free(template);
                if (std.mem.indexOf(u8, template, "{searchTerms}") == null) continue;

                const resolved = try xml.resolveUrl(allocator, base, template);
                if (found) |earlier| allocator.free(earlier);
                found = resolved;
                if (for_opds) break;
            },
            else => {},
        }
    }

    return found orelse error.NoSearchAddress;
}

/// Puts the text the user typed into a template. The other placeholders a template may
/// have get a fixed value when the catalog requires them, optional ones ({name?}) are left empty.
pub fn fill(allocator: std.mem.Allocator, template: []const u8, text: []const u8) ![:0]const u8 {
    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(allocator);

    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, '}') orelse break;
        try url.appendSlice(allocator, rest[0..start]);

        const placeholder = rest[start + 1 .. end];
        const name = std.mem.trimEnd(u8, placeholder, "?");
        if (std.mem.eql(u8, name, "searchTerms")) {
            for (std.mem.trim(u8, text, " ")) |c| switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try url.append(allocator, c),
                else => try url.print(allocator, "%{X:0>2}", .{c}),
            };
        } else if (name.len == placeholder.len) {
            // A required placeholder: the first page, in the size the catalog would pick itself
            if (std.mem.eql(u8, name, "startPage") or std.mem.eql(u8, name, "startIndex")) {
                try url.append(allocator, '1');
            } else if (std.mem.eql(u8, name, "count")) {
                try url.appendSlice(allocator, "20");
            }
        }
        rest = rest[end + 1 ..];
    }
    try url.appendSlice(allocator, rest);

    return url.toOwnedSliceSentinel(allocator, 0);
}

/// TEST
fn expectFilled(expected: []const u8, template: []const u8, text: []const u8) !void {
    const url = try fill(std.testing.allocator, template, text);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(expected, url);
}

test "fill puts the text into the template" {
    try expectFilled("http://flibusta.is/opds/search?searchTerm=tolstoy", "http://flibusta.is/opds/search?searchTerm={searchTerms}", "tolstoy");
    try expectFilled("http://calibre.lan:8080/opds/search/dune", "http://calibre.lan:8080/opds/search/{searchTerms}", "dune");
}

test "fill encodes spaces, special characters and other alphabets" {
    try expectFilled("http://c.lan/s?q=war%20and%20peace", "http://c.lan/s?q={searchTerms}", "war and peace");
    try expectFilled("http://c.lan/s?q=a%26b%3Dc%2Fd%3F", "http://c.lan/s?q={searchTerms}", "a&b=c/d?");
    try expectFilled("http://c.lan/s?q=%D0%A2%D0%BE%D0%BC", "http://c.lan/s?q={searchTerms}", "Том");
}

test "fill trims the text" {
    try expectFilled("http://c.lan/s?q=dune", "http://c.lan/s?q={searchTerms}", "  dune ");
}

test "fill leaves optional placeholders empty" {
    try expectFilled(
        "http://flibusta.is/opds/opensearch?searchTerm=dune&searchType=books&pageNumber=",
        "http://flibusta.is/opds/opensearch?searchTerm={searchTerms}&searchType=books&pageNumber={startPage?}",
        "dune",
    );
}

test "fill gives required placeholders a value" {
    try expectFilled(
        "https://standardebooks.org/feeds/opds/all?query=dune&per-page=20&page=1",
        "https://standardebooks.org/feeds/opds/all?query={searchTerms}&per-page={count}&page={startPage}",
        "dune",
    );
    try expectFilled("http://c.lan/s?q=dune&from=1&lang=", "http://c.lan/s?q={searchTerms}&from={startIndex}&lang={language}", "dune");
}

test "fill keeps a template without placeholders and one with a broken placeholder" {
    try expectFilled("http://c.lan/s", "http://c.lan/s", "dune");
    try expectFilled("http://c.lan/s?q={searchTerms", "http://c.lan/s?q={searchTerms", "dune");
}

fn expectTemplate(expected: []const u8, description: []const u8, base_url: []const u8) !void {
    const template = try readDescription(std.testing.allocator, description, base_url);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqualStrings(expected, template);
}

test "readDescription takes the address for feeds, not the one for web pages" {
    try expectTemplate("http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
        \\  <ShortName>Gutenberg</ShortName>
        \\  <Url type="text/html" template="http://www.gutenberg.org/ebooks/search/?query={searchTerms}"/>
        \\  <Url type="application/atom+xml" template="http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}"/>
        \\  <Url type="application/x-suggestions+json" rel="suggestions" template="http://www.gutenberg.org/ebooks/suggest/?query={searchTerms}"/>
        \\</OpenSearchDescription>
    , "https://www.gutenberg.org/catalog/osd-books.xml");
}

test "readDescription prefers the address made for OPDS and decodes it" {
    try expectTemplate("https://standardebooks.org/feeds/opds/all?query={searchTerms}&per-page={count}&page={startPage}",
        \\<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
        \\  <Url type="application/atom+xml" template="https://standardebooks.org/feeds/atom/all?query={searchTerms}&amp;per-page={count}&amp;page={startPage}"/>
        \\  <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="https://standardebooks.org/feeds/opds/all?query={searchTerms}&amp;per-page={count}&amp;page={startPage}"/>
        \\  <Url type="application/opds+json" template="https://standardebooks.org/feeds/opds/all?query={searchTerms}"/>
        \\</OpenSearchDescription>
    , "https://standardebooks.org/opensearch");
}

test "readDescription completes an address without a server" {
    try expectTemplate("http://calibre.lan:8083/opds/search?query={searchTerms}",
        \\<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
        \\  <Url type="text/html" template="/search?query={searchTerms}"/>
        \\  <Url type="application/atom+xml" template="/opds/search?query={searchTerms}"/>
        \\</OpenSearchDescription>
    , "http://calibre.lan:8083/opds/osd");
}

test "readDescription fails when the file has no address for feeds" {
    try std.testing.expectError(error.NoSearchAddress, readDescription(std.testing.allocator,
        \\<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
        \\  <Url type="text/html" template="http://c.lan/search?query={searchTerms}"/>
        \\  <Url type="application/atom+xml" template="http://c.lan/all"/>
        \\</OpenSearchDescription>
    , "http://c.lan/osd"));
}

const std = @import("std");

const xml2 = @cImport({
    @cInclude("libxml/xmlreader.h");
});

pub const Book = struct {
    title: []const u8,
    author: []const u8,
    download_url: []const u8,
};

pub const BookFormat = enum {
    epub,
    pdf,
};

pub fn parseOPDSFeed(allocator: std.mem.Allocator, xml_data: []const u8) ![]BookEntry {
    var books = std.ArrayList(BookEntry).init(allocator);
    errdefer books.deinit();

    const reader = xml2.xmlReaderForMemory(
        xml_data.ptr,
        @intCast(xml_data.len),
        null,
        null,
        0,
    ) orelse return error.XmlReaderInitFailed;
    defer xml2.xmlFreeTextReader(reader);

    var inside_entry = false;

    while (xml2.xmlTextReaderRead(reader) == 1) {
        const node_type = xml2.xmlTextReaderNodeType(reader);
        const raw_name = xml2.xmlTextReaderConstName(reader);

        if (raw_name == null) continue;
        const name = std.mem.span(raw_name);

        // Start of an element - <tag>
        if (node_type == 1) {
            if (std.mem.eql(u8, name, "entry")) {
                inside_entry = true;
            }

            if (inside_entry and std.mem.eql(u8, name, "title")) {
                const raw_value = xml2.xmlTextReaderReadString(reader);
                if (raw_value) |val| {
                    defer xml2.xmlFree(val);

                    const slice = std.mem.span(val);
                    const title_copy = try allocator.dupe(u8, slice);

                    try books.append(.{ .title = title_copy });
                }
            }
        } else if (node_type == 15) {
            if (std.mem.eql(u8, name, "entry")) {
                inside_entry = false;
            }
        }
    }

    return books.toOwnedSlice();
}

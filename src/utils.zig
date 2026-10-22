const std = @import("std");

/// Clean names of the book title and strip not allowed characters,
/// like ;%*.[]
pub fn cleanName(out: []u8, text: []const u8, is_author: bool) usize {
    var len: usize = 0;
    for (text) |c| {
        const keep = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', ' ', '(', ')', '\'' => true,
            ',', '-' => is_author,
            // Bytes of non-ASCII characters, i.e. letters of other alphabets and accents
            0x80...0xFF => true,
            else => false,
        };
        if (!keep) continue;
        // No leading or doubled spaces
        if (c == ' ' and (len == 0 or out[len - 1] == ' ')) continue;

        if (len == out.len) {
            // Full. If we are in the middle of a UTF-8 sequence, drop the part already written
            if ((c & 0xC0) == 0x80) {
                while (len > 0 and (out[len - 1] & 0xC0) == 0x80) len -= 1;
                if (len > 0) len -= 1;
            }
            break;
        }

        out[len] = c;
        len += 1;
    }

    while (len > 0 and out[len - 1] == ' ') len -= 1;
    return len;
}

/// A file size for display: whole kilobytes below one megabyte ("547 KB"),
/// megabytes with one decimal from there on ("23.6 MB"). Sizes are rounded down.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const megabyte = 1024 * 1024;

    if (bytes < megabyte) {
        // A file that is not empty counts as at least 1 KB
        const kilobytes = if (bytes == 0) 0 else @max(1, bytes / 1024);
        return std.fmt.bufPrint(buf, "{d} KB", .{kilobytes}) catch "";
    }

    const tenths = bytes * 10 / megabyte;
    return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ tenths / 10, tenths % 10 }) catch "";
}

/// TEST
/// Runs cleanName with a buffer of `capacity` bytes and compares the result
fn expectClean(expected: []const u8, text: []const u8, is_author: bool, comptime capacity: usize) !void {
    var buf: [capacity]u8 = undefined;
    const len = cleanName(&buf, text, is_author);
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "keeps letters, digits, spaces, round brackets and apostrophes" {
    try expectClean("L'histoire de Guillaume (French) 3", "L'histoire de Guillaume (French) 3", false, 64);
}

test "strips punctuation and symbols" {
    try expectClean("What Quoted pathname ab", "What? \"Quoted\" / path\\name: <a|b>*", false, 64);
    try expectClean("Tom 6 Battle", "Tom 6. Battle!", false, 64);
}

test "comma and hyphen survive in author names only" {
    try expectClean("Saint-Exupéry, Antoine de", "Saint-Exupéry, Antoine de", true, 64);
    try expectClean("JeanChristophe vol 1", "Jean-Christophe, vol. 1", false, 64);
}

test "removes leading, trailing and doubled spaces" {
    try expectClean("Rolland, Romain", "  Rolland,   Romain  ", true, 64);
    try expectClean("Seat work and games Primary grades", "Seat work and games :  Primary grades", false, 64);
}

test "keeps letters of other alphabets" {
    try expectClean("Игра на выживание Том 6", "Игра на выживание. Том 6.", false, 64);
    try expectClean("Maréchal", "Maréchal", false, 64);
}

test "returns nothing when no character is allowed" {
    try expectClean("", "?!...", false, 64);
    try expectClean("", "", true, 64);
}

test "cuts text that does not fit" {
    try expectClean("abcde", "abcdefgh", false, 5);
    try expectClean("abcd", "abcd efgh", false, 5);
}

test "never cuts inside a multi-byte character" {
    // "é" takes two bytes, so only two of them fit into five bytes
    try expectClean("éé", "ééé", false, 5);
    // "Я" takes two bytes: "ab" plus one "Я" is four bytes, the second "Я" would end at six
    try expectClean("abЯ", "abЯЯ", false, 5);
    // "€" takes three bytes and would end at six
    try expectClean("abc", "abc€", false, 5);
}

fn expectSize(expected: []const u8, bytes: u64) !void {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(expected, formatSize(&buf, bytes));
}

test "formatSize shows small files in kilobytes" {
    try expectSize("100 KB", 100 * 1024);
    try expectSize("547 KB", 561102);
    try expectSize("1023 KB", 1024 * 1024 - 1);
}

test "formatSize shows at least 1 KB for a file that is not empty" {
    try expectSize("0 KB", 0);
    try expectSize("1 KB", 1);
    try expectSize("1 KB", 1023);
}

test "formatSize shows megabytes with one decimal from 1 MB on" {
    try expectSize("1.0 MB", 1024 * 1024);
    try expectSize("1.9 MB", 2 * 1024 * 1024 - 1);
    try expectSize("23.6 MB", 24836548);
}

/// Plain text from the HTML of a book description: tags removed, paragraphs and line
/// breaks kept as line breaks, the common entities decoded, spaces tidied
pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            const tag = html[i + 1 .. end];
            if (isBlockTag(tag)) try out.append(allocator, '\n');
            i = end + 1;
        } else if (c == '&') {
            const end = std.mem.indexOfScalarPos(u8, html, i, ';');
            if (end != null and end.? - i <= 10) {
                if (decodeEntity(html[i + 1 .. end.?])) |char| {
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(char, &utf8) catch 0;
                    try out.appendSlice(allocator, utf8[0..n]);
                    i = end.? + 1;
                    continue;
                }
            }
            try out.append(allocator, c);
            i += 1;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return tidyText(allocator, out.items);
}

/// Whether a tag (what is between < and >) starts a new line of text
pub fn isBlockTag(tag: []const u8) bool {
    const name_start: usize = if (tag.len > 0 and tag[0] == '/') 1 else 0;
    var name_end = name_start;
    while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
    const name = tag[name_start..name_end];
    const blocks = [_][]const u8{ "p", "br", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote" };
    for (blocks) |block| {
        if (std.ascii.eqlIgnoreCase(name, block)) return true;
    }
    return false;
}

/// The character of an entity name ("amp", "#233", "#xE9"), null if unknown
pub fn decodeEntity(name: []const u8) ?u21 {
    if (name.len > 1 and name[0] == '#') {
        const value = if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16)
        else
            std.fmt.parseInt(u21, name[1..], 10);
        return value catch null;
    }
    const names = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },      .{ "lt", '<' },       .{ "gt", '>' },        .{ "quot", '"' },
        .{ "apos", '\'' },    .{ "nbsp", 0xA0 },    .{ "rsquo", 0x2019 },  .{ "lsquo", 0x2018 },
        .{ "ldquo", 0x201C }, .{ "rdquo", 0x201D }, .{ "hellip", 0x2026 }, .{ "mdash", 0x2014 },
        .{ "ndash", 0x2013 }, .{ "laquo", 0xAB },   .{ "raquo", 0xBB },    .{ "eacute", 0xE9 },
        .{ "egrave", 0xE8 },  .{ "agrave", 0xE0 },  .{ "ccedil", 0xE7 },   .{ "ecirc", 0xEA },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Spaces and tabs as single spaces, no spaces around line breaks, at most one empty line
/// in a row, none at the start or the end
pub fn tidyText(allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var pending_space = false;
    var newlines: usize = 0;
    for (text) |c| {
        switch (c) {
            ' ', '\t', '\r' => pending_space = true,
            '\n' => {
                newlines += 1;
                pending_space = false;
            },
            else => {
                if (out.items.len > 0) {
                    if (newlines > 0) {
                        try out.appendNTimes(allocator, '\n', @min(newlines, 2));
                    } else if (pending_space) {
                        try out.append(allocator, ' ');
                    }
                }
                newlines = 0;
                pending_space = false;
                try out.append(allocator, c);
            },
        }
    }
    return allocator.dupeSentinel(u8, out.items, 0);
}

test "htmlToText keeps paragraphs and decodes entities" {
    const text = try htmlToText(std.testing.allocator, "<div><p>Un  <em>roman</em>&nbsp;d&#233;sol&eacute;.</p>\n<p>Deux &amp; trois<br/>quatre</p></div>");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Un roman\u{A0}désolé.\n\nDeux & trois\nquatre", text);
}

test "htmlToText leaves unknown entities and lone signs alone" {
    const text = try htmlToText(std.testing.allocator, "A & B &unknown; 3 < 4");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A & B &unknown; 3", text);
}

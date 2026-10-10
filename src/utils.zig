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

/// Shows an error dialog with the correct PocketBook styling.
pub fn showError(comptime pb: type, title: [*:0]const u8, text: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "{s} ({s})", .{ text, @errorName(err) }, 0) catch "Error";
    pb.Message(pb.ICON_ERROR, title, msg.ptr, 5000);
}

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

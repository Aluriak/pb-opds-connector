//! Which synchronized books came from which list, so a book removed from a list can be
//! found again. Without it, a tagged book missing from a list may as well come from another.
//!
//! One line per book and list, tab separated: "<list key>\t<book tag>". The list key is the
//! hash of the address of the list, the book tag that of its id (see xml.Entry.syncTag).

const std = @import("std");
const xml = @import("xml.zig");

pub const default_path = "/mnt/ext1/system/config/opds-connector-sync.tsv";

pub const Tag = [xml.sync_tag_len]u8;

pub const Line = struct {
    list: Tag,
    book: Tag,
};

/// The key of the list at `url`
pub fn listKey(url: []const u8) Tag {
    var key: Tag = undefined;
    _ = std.fmt.bufPrint(&key, "{x:0>16}", .{std.hash.Wyhash.hash(0, url)}) catch unreachable;
    return key;
}

/// Reads the lines of a manifest. Lines that cannot be read are skipped.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len != 2 * xml.sync_tag_len + 1 or line[xml.sync_tag_len] != '\t') continue;
        try lines.append(allocator, .{ .list = line[0..xml.sync_tag_len].*, .book = line[xml.sync_tag_len + 1 ..][0..xml.sync_tag_len].* });
    }
    return lines.toOwnedSlice(allocator);
}

fn contains(tags: []const Tag, tag: Tag) bool {
    for (tags) |other| {
        if (std.mem.eql(u8, &other, &tag)) return true;
    }
    return false;
}

/// The books synchronized from `list` before that are not in it anymore (not in `current`),
/// and that no other list holds
pub fn removed(allocator: std.mem.Allocator, lines: []const Line, list: Tag, current: []const Tag) ![]Tag {
    var found: std.ArrayList(Tag) = .empty;
    for (lines) |line| {
        if (!std.mem.eql(u8, &line.list, &list)) continue;
        if (contains(current, line.book) or contains(found.items, line.book)) continue;
        const elsewhere = for (lines) |other| {
            if (!std.mem.eql(u8, &other.list, &list) and std.mem.eql(u8, &other.book, &line.book)) break true;
        } else false;
        if (!elsewhere) try found.append(allocator, line.book);
    }
    return found.toOwnedSlice(allocator);
}

/// The lines with those of `list` replaced by `books`
pub fn replace(allocator: std.mem.Allocator, lines: []const Line, list: Tag, books: []const Tag) ![]Line {
    var result: std.ArrayList(Line) = .empty;
    for (lines) |line| {
        if (!std.mem.eql(u8, &line.list, &list)) try result.append(allocator, line);
    }
    for (books) |book| try result.append(allocator, .{ .list = list, .book = book });
    return result.toOwnedSlice(allocator);
}

/// Reads the manifest file, an empty one if there is none.
/// Through libc: Zig's own file layer makes system calls the reader's kernel lacks.
pub fn load(allocator: std.mem.Allocator, path: [:0]const u8) ![]Line {
    const file = std.c.fopen(path.ptr, "rb") orelse return &.{};
    defer _ = std.c.fclose(file);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const read = std.c.fread(&buf, 1, buf.len, file);
        if (read == 0) break;
        try text.appendSlice(allocator, buf[0..read]);
    }
    return parse(allocator, text.items);
}

/// Writes the manifest file, through a new file put in place at the end
pub fn store(path: [:0]const u8, lines: []const Line) !void {
    var new_buf: [256]u8 = undefined;
    const new = try std.fmt.bufPrintSentinel(&new_buf, "{s}.new", .{path}, 0);
    {
        const file = std.c.fopen(new.ptr, "wb") orelse return error.CannotWriteManifest;
        defer _ = std.c.fclose(file);
        for (lines) |line| {
            var buf: [2 * xml.sync_tag_len + 2]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s}\t{s}\n", .{ line.list, line.book });
            if (std.c.fwrite(text.ptr, 1, text.len, file) != text.len) return error.CannotWriteManifest;
        }
    }
    if (std.c.rename(new.ptr, path.ptr) != 0) return error.CannotWriteManifest;
}

fn testTag(comptime text: []const u8) Tag {
    var tag: Tag = @splat('0');
    @memcpy(tag[0..text.len], text);
    return tag;
}

test "parse reads what store writes and skips broken lines" {
    const text = "1111000000000000\taaaa000000000000\nbroken\n2222000000000000\tbbbb000000000000\r\n";
    const lines = try parse(std.testing.allocator, text);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(2, lines.len);
    try std.testing.expectEqualStrings("bbbb000000000000", &lines[1].book);
}

test "removed books are those of the list only, not in it anymore" {
    const list = testTag("1");
    const other = testTag("2");
    const lines = [_]Line{
        .{ .list = list, .book = testTag("a") },
        .{ .list = list, .book = testTag("b") },
        .{ .list = list, .book = testTag("c") },
        .{ .list = other, .book = testTag("c") },
        .{ .list = other, .book = testTag("d") },
    };
    // "b" left the list; "c" left it too but the other list still holds it
    const gone = try removed(std.testing.allocator, &lines, list, &.{testTag("a")});
    defer std.testing.allocator.free(gone);
    try std.testing.expectEqual(1, gone.len);
    try std.testing.expectEqualStrings(&testTag("b"), &gone[0]);

    const updated = try replace(std.testing.allocator, &lines, list, &.{ testTag("a"), testTag("e") });
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqual(4, updated.len);
    try std.testing.expectEqualStrings(&testTag("e"), &updated[3].book);
}

test "listKey depends on the address only" {
    try std.testing.expectEqualStrings(&listKey("http://a/opds/shelf/1"), &listKey("http://a/opds/shelf/1"));
    try std.testing.expect(!std.mem.eql(u8, &listKey("http://a/opds/shelf/1"), &listKey("http://a/opds/shelf/2")));
}

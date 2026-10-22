//! Finding files by part of their name. Through libc, like all file access of the app:
//! Zig's own file layer makes system calls the reader's 3.10 kernel lacks.

const std = @import("std");

/// The start of glibc's glob_t, with room for the rest of it
const Glob = extern struct {
    pathc: usize = 0,
    pathv: ?[*]?[*:0]u8 = null,
    offs: usize = 0,
    rest: [16]usize = @splat(0),
};
extern "c" fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *Glob) c_int;
extern "c" fn globfree(pglob: *Glob) void;

/// The name of a file in `dir` whose name holds ".<tag>." (or starts with "opds-<tag>.", as
/// synchronized books were named before), copied into `buf`. Unfinished downloads (".part")
/// do not count. `tag` must hold no wildcard characters.
pub fn findTagged(buf: []u8, dir: []const u8, tag: []const u8) ?[]const u8 {
    var pattern_buf: [512]u8 = undefined;
    const pattern = std.fmt.bufPrintSentinel(&pattern_buf, "{s}/*{s}.*", .{ dir, tag }, 0) catch return null;

    var found: Glob = .{};
    if (glob(pattern.ptr, 0, null, &found) != 0) return null;
    defer globfree(&found);

    const paths = found.pathv orelse return null;
    for (paths[0..found.pathc]) |maybe_path| {
        const path = std.mem.span(maybe_path orelse continue);
        const name = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
        if (std.mem.endsWith(u8, name, ".part")) continue;

        const at = std.mem.indexOf(u8, name, tag) orelse continue;
        const before = name[0..at];
        // ".<tag>." in the name, or the whole start "opds-<tag>."
        if (!std.mem.endsWith(u8, before, ".") and !std.mem.eql(u8, before, "opds-")) continue;

        if (name.len > buf.len) continue;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    return null;
}

/// The extension of a tagged name: what follows "<tag>.", e.g. "epub" or "fb2.zip"
pub fn tagExtension(name: []const u8, tag: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, name, tag) orelse return "";
    const after = at + tag.len;
    if (after >= name.len or name[after] != '.') return "";
    return name[after + 1 ..];
}

/// Whether a name carries the tag of a synchronized book: ".<16 hex digits>." inside it, or
/// "opds-<16 hex digits>." at its start, as synchronized books were named before
pub fn isTagged(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "opds-") and hexRun(name["opds-".len..]) and name.len > "opds-".len + 16 and name["opds-".len + 16] == '.') return true;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, i, '.')) |dot| : (i = dot + 1) {
        const rest = name[dot + 1 ..];
        if (rest.len > 16 and rest[16] == '.' and hexRun(rest)) return true;
    }
    return false;
}

fn hexRun(text: []const u8) bool {
    if (text.len < 16) return false;
    for (text[0..16]) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    }
    return true;
}

/// The names of the files in `dir`, without unfinished downloads (".part")
pub fn list(allocator: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var pattern_buf: [512]u8 = undefined;
    const pattern = try std.fmt.bufPrintSentinel(&pattern_buf, "{s}/*", .{dir}, 0);

    var found: Glob = .{};
    if (glob(pattern.ptr, 0, null, &found) != 0) return &.{};
    defer globfree(&found);

    var names: std.ArrayList([]const u8) = .empty;
    const paths = found.pathv orelse return &.{};
    for (paths[0..found.pathc]) |maybe_path| {
        const path = std.mem.span(maybe_path orelse continue);
        const name = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
        if (std.mem.endsWith(u8, name, ".part")) continue;
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    return names.toOwnedSlice(allocator);
}

const SEEK_END = 2;
extern "c" fn fseek(file: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(file: *std.c.FILE) c_long;

/// The size of a file in bytes, null if it cannot be opened
pub fn size(path: [:0]const u8) ?u64 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);
    if (fseek(file, 0, SEEK_END) != 0) return null;
    return std.math.cast(u64, ftell(file));
}

/// Whether two files hold exactly the same bytes
pub fn sameContent(a: [:0]const u8, b: [:0]const u8) bool {
    const file_a = std.c.fopen(a.ptr, "rb") orelse return false;
    defer _ = std.c.fclose(file_a);
    const file_b = std.c.fopen(b.ptr, "rb") orelse return false;
    defer _ = std.c.fclose(file_b);

    var buf_a: [8192]u8 = undefined;
    var buf_b: [8192]u8 = undefined;
    while (true) {
        const read_a = std.c.fread(&buf_a, 1, buf_a.len, file_a);
        const read_b = std.c.fread(&buf_b, 1, buf_b.len, file_b);
        if (read_a != read_b) return false;
        if (!std.mem.eql(u8, buf_a[0..read_a], buf_b[0..read_b])) return false;
        if (read_a < buf_a.len) return true;
    }
}

/// Lower case letters and digits only, with the accents of Latin letters dropped:
/// "Le Temps d'après" and "Le Temps d'apres" both become "letempsdapres"
pub fn fold(buf: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len and len < buf.len) : (i += 1) {
        const char = text[i];
        if (std.ascii.isAlphanumeric(char)) {
            buf[len] = std.ascii.toLower(char);
            len += 1;
        } else if (char == 0xC3 and i + 1 < text.len) {
            // À to ÿ, two bytes in UTF-8
            i += 1;
            if (foldLatin(text[i])) |base| {
                buf[len] = base;
                len += 1;
            }
        } else if (char == 0xC5 and i + 1 < text.len and (text[i + 1] == 0x93 or text[i + 1] == 0x92) and len + 1 < buf.len) {
            // œ and Œ
            i += 1;
            @memcpy(buf[len..][0..2], "oe");
            len += 2;
        }
    }
    return buf[0..len];
}

/// The base letter of the second byte of "\xC3?" (À to ÿ)
fn foldLatin(second: u8) ?u8 {
    const lower = second | 0x20;
    return switch (lower) {
        0xA0...0xA5 => 'a',
        0xA7 => 'c',
        0xA8...0xAB => 'e',
        0xAC...0xAF => 'i',
        0xB1 => 'n',
        0xB2...0xB6, 0xB8 => 'o',
        0xB9...0xBC => 'u',
        0xBD, 0xBF => 'y',
        else => null,
    };
}

/// Whether a file name looks like it holds the book with this title: the start of the title,
/// folded, is in the folded name
pub fn nameHasTitle(name: []const u8, title: []const u8) bool {
    var name_buf: [512]u8 = undefined;
    var title_buf: [512]u8 = undefined;
    const folded_name = fold(&name_buf, name);
    const folded_title = fold(&title_buf, title);
    // Short titles ("It") would match too much
    if (folded_title.len < 4) return std.mem.indexOf(u8, folded_name, folded_title) == 0;
    return std.mem.indexOf(u8, folded_name, folded_title[0..@min(folded_title.len, 16)]) != null;
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn touch(dir: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    const file = std.c.fopen(path.ptr, "w") orelse return error.CannotCreate;
    _ = std.c.fclose(file);
}

test "findTagged finds a book by its tag, whatever its title became" {
    var template = "/tmp/opds-files-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    const tag = "1eadf8088e68d977";

    try touch(dir, "Someone - Something else.0123456789abcdef.epub");
    try touch(dir, "Jean Hegland - Le Temps d'apres." ++ tag ++ ".epub.part");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(null, findTagged(&buf, dir, tag));

    try touch(dir, "Jean Hegland - Old title." ++ tag ++ ".epub");
    try std.testing.expectEqualStrings("Jean Hegland - Old title." ++ tag ++ ".epub", findTagged(&buf, dir, tag).?);
}

test "findTagged finds books named the earlier way" {
    var template = "/tmp/opds-files-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    const tag = "028d62348d5c0c4b";

    try touch(dir, "x" ++ tag ++ ".epub");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(null, findTagged(&buf, dir, tag));

    try touch(dir, "opds-" ++ tag ++ ".epub");
    try std.testing.expectEqualStrings("opds-" ++ tag ++ ".epub", findTagged(&buf, dir, tag).?);
}

test "tagExtension takes everything after the tag" {
    try std.testing.expectEqualStrings("fb2.zip", tagExtension("A - B.0123456789abcdef.fb2.zip", "0123456789abcdef"));
    try std.testing.expectEqualStrings("epub", tagExtension("opds-0123456789abcdef.epub", "0123456789abcdef"));
    try std.testing.expectEqualStrings("", tagExtension("A - B.epub", "0123456789abcdef"));
}

test "isTagged knows both ways synchronized books are named" {
    try std.testing.expect(isTagged("Jean Hegland - Le Temps d'apres.1eadf8088e68d977.epub"));
    try std.testing.expect(isTagged("opds-028d62348d5c0c4b.epub"));
    try std.testing.expect(isTagged("A. B - Vol. 2.1eadf8088e68d977.fb2.zip"));
    try std.testing.expect(!isTagged("Le Temps d'apres - Jean Hegland.epub"));
    try std.testing.expect(!isTagged("Report.2026-10-22.final.epub"));
    try std.testing.expect(!isTagged("Upper.1EADF8088E68D977.epub"));
}

test "fold drops case, punctuation and accents" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("letempsdapres", fold(&buf, "Le Temps d'après"));
    try std.testing.expectEqualStrings("letempsdapres", fold(&buf, "Le Temps d'apres"));
    try std.testing.expectEqualStrings("lesdesarmantes", fold(&buf, "Les désarmantes"));
    try std.testing.expectEqualStrings("coeurfidele", fold(&buf, "Cœur fidèle"));
}

test "nameHasTitle matches the file names of the same book" {
    try std.testing.expect(nameHasTitle("Le Temps d'apres - Jean Hegland.epub", "Le Temps d'après"));
    try std.testing.expect(nameHasTitle("Dungeon Crawler Carl - Matt Dinniman.epub", "Dungeon Crawler Carl T1 :"));
    try std.testing.expect(nameHasTitle("Trois corps - 01 - Le probleme a trois corps - Liu Cixin.epub", "Trois corps – 01 – Le problème à trois corps"));
    try std.testing.expect(!nameHasTitle("Les desarmantes - Caroline Bouffault.epub", "Le Temps d'après"));
}

test "list, size and sameContent look at the files of a folder" {
    var template = "/tmp/opds-files-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    try write(dir, "a.epub", "same bytes");
    try write(dir, "b.epub", "same bytes");
    try write(dir, "c.epub", "same bytez");
    try write(dir, "d.epub.part", "unfinished");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const names = try list(arena.allocator(), dir);
    try std.testing.expectEqual(3, names.len);

    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    var c_buf: [128]u8 = undefined;
    const a = try std.fmt.bufPrintSentinel(&a_buf, "{s}/a.epub", .{dir}, 0);
    const b = try std.fmt.bufPrintSentinel(&b_buf, "{s}/b.epub", .{dir}, 0);
    const c = try std.fmt.bufPrintSentinel(&c_buf, "{s}/c.epub", .{dir}, 0);
    try std.testing.expectEqual(10, size(a).?);
    try std.testing.expect(sameContent(a, b));
    try std.testing.expect(!sameContent(a, c));
}

fn write(dir: []const u8, name: []const u8, content: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    const file = std.c.fopen(path.ptr, "w") orelse return error.CannotCreate;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(content.ptr, 1, content.len, file);
}

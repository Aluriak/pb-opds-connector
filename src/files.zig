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

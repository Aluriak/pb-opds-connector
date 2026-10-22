//! Which update to offer. Every release of the app comes with a "version.txt" that
//! describes it, the app compares that with the version it was built as.

const std = @import("std");

pub const Channel = enum {
    /// Built from every push to main
    nightly,
    /// A version that was tagged and released
    release,
    /// Built by hand, never published
    dev,
};

/// What the configuration allows to be offered ("updates=" in the settings file)
pub const Policy = enum {
    /// Releases and nightly builds
    all,
    /// Releases only, the default: nightly builds are for those who know why they want them
    stable,
    /// The update row is not shown at all
    off,

    pub fn parse(text: []const u8) Policy {
        return std.meta.stringToEnum(Policy, std.mem.trim(u8, text, " \t\r\n")) orelse .stable;
    }
};

/// A build of the app
pub const Info = struct {
    channel: Channel = .dev,
    /// The version from build.zig.zon, e.g. "0.3.1"
    version: []const u8 = "",
    /// The git commit it was built from, shortened or not
    commit: []const u8 = "",
    /// The tag of the release its files are attached to, e.g. "nightly" or "v0.4.0"
    tag: []const u8 = "",
    /// When it was built, e.g. "2026-10-17"
    date: []const u8 = "",

    /// Reads the "key=value" lines of a version.txt. The slices point into `text`.
    pub fn parse(text: []const u8) !Info {
        var info: Info = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..eq], " ");
            const value = std.mem.trim(u8, line[eq + 1 ..], " ");

            if (std.mem.eql(u8, name, "channel")) {
                info.channel = std.meta.stringToEnum(Channel, value) orelse return error.UnknownChannel;
            } else if (std.mem.eql(u8, name, "version")) {
                info.version = value;
            } else if (std.mem.eql(u8, name, "commit")) {
                info.commit = value;
            } else if (std.mem.eql(u8, name, "tag")) {
                info.tag = value;
            } else if (std.mem.eql(u8, name, "date")) {
                info.date = value;
            }
        }
        if (info.version.len == 0 or info.commit.len == 0 or info.tag.len == 0) return error.IncompleteVersionFile;
        _ = try std.SemanticVersion.parse(info.version);
        return info;
    }

    /// "0.4.0 (release, 9606907, 2026-10-17)"
    pub fn describe(info: Info, buf: []u8) []const u8 {
        const commit = info.commit[0..@min(7, info.commit.len)];
        const text = if (info.date.len > 0)
            std.fmt.bufPrint(buf, "{s} ({s}, {s}, {s})", .{ info.version, @tagName(info.channel), commit, info.date })
        else
            std.fmt.bufPrint(buf, "{s} ({s}, {s})", .{ info.version, @tagName(info.channel), commit });
        return text catch buf[0..0];
    }

    fn sameCommit(a: Info, b: Info) bool {
        const len = @min(a.commit.len, b.commit.len);
        return len > 0 and std.mem.eql(u8, a.commit[0..len], b.commit[0..len]);
    }
};

/// <0 if a is older than b, 0 if equal, >0 if newer. A version that cannot be read counts as oldest.
fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const va = std.SemanticVersion.parse(a) catch return .lt;
    const vb = std.SemanticVersion.parse(b) catch return .gt;
    return va.order(vb);
}

/// The build to offer instead of `installed`, null if there is nothing newer.
/// A release is offered when its version is higher. A nightly build is offered when it was
/// built from another commit, but never when it is older than the installed version.
pub fn choose(installed: Info, policy: Policy, nightly: ?Info, release: ?Info) ?Info {
    if (policy == .off) return null;

    if (policy == .all) {
        if (nightly) |n| {
            if (!n.sameCommit(installed) and compareVersions(n.version, installed.version) != .lt) return n;
        }
    }
    if (release) |r| {
        if (compareVersions(r.version, installed.version) == .gt) return r;
    }
    return null;
}

/// Whether `head`, the first bytes of a file, start an ARM executable
pub fn isArmExecutable(head: []const u8) bool {
    // e_machine at offset 18, little endian, 40 is ARM
    if (head.len < 20) return false;
    return std.mem.eql(u8, head[0..4], "\x7fELF") and head[18] == 40 and head[19] == 0;
}

test "parse reads a version file" {
    const info = try Info.parse("channel=nightly\nversion=0.3.1\ncommit=9606907cc806\ntag=nightly\ndate=2026-10-17\n");
    try std.testing.expectEqual(Channel.nightly, info.channel);
    try std.testing.expectEqualStrings("0.3.1", info.version);
    try std.testing.expectEqualStrings("9606907cc806", info.commit);
    try std.testing.expectEqualStrings("nightly", info.tag);
    try std.testing.expectEqualStrings("2026-10-17", info.date);
}

test "parse refuses an incomplete or broken version file" {
    try std.testing.expectError(error.IncompleteVersionFile, Info.parse("channel=nightly\nversion=0.3.1\n"));
    try std.testing.expectError(error.UnknownChannel, Info.parse("channel=beta\nversion=0.3.1\ncommit=a\ntag=t\n"));
    try std.testing.expectError(error.InvalidVersion, Info.parse("channel=release\nversion=soon\ncommit=a\ntag=t\n"));
}

test "describe names version, kind, commit and date" {
    var buf: [128]u8 = undefined;
    const info: Info = .{ .channel = .release, .version = "0.4.0", .commit = "9606907cc806ea2c", .tag = "v0.4.0", .date = "2026-10-17" };
    try std.testing.expectEqualStrings("0.4.0 (release, 9606907, 2026-10-17)", info.describe(&buf));
}

test "Policy falls back to stable for anything it does not know" {
    try std.testing.expectEqual(Policy.stable, Policy.parse(" stable\n"));
    try std.testing.expectEqual(Policy.off, Policy.parse("off"));
    try std.testing.expectEqual(Policy.stable, Policy.parse("whatever"));
    try std.testing.expectEqual(Policy.all, Policy.parse("all"));
}

const test_installed: Info = .{ .channel = .nightly, .version = "0.3.1", .commit = "aaaaaaa1111", .tag = "nightly" };

test "choose offers a nightly build of another commit" {
    const nightly: Info = .{ .channel = .nightly, .version = "0.3.1", .commit = "bbbbbbb", .tag = "nightly" };
    try std.testing.expectEqualDeep(nightly, choose(test_installed, .all, nightly, null).?);
}

test "choose offers nothing when the nightly build is the installed one" {
    const nightly: Info = .{ .channel = .nightly, .version = "0.3.1", .commit = "aaaaaaa", .tag = "nightly" };
    try std.testing.expectEqual(null, choose(test_installed, .all, nightly, null));
}

test "choose never goes back to an older nightly version" {
    const newer: Info = .{ .channel = .release, .version = "0.4.0", .commit = "ccccccc", .tag = "v0.4.0" };
    const nightly: Info = .{ .channel = .nightly, .version = "0.3.1", .commit = "bbbbbbb", .tag = "nightly" };
    try std.testing.expectEqual(null, choose(newer, .all, nightly, null));
}

test "choose leaves nightly builds out when only releases are wanted" {
    const nightly: Info = .{ .channel = .nightly, .version = "0.4.0", .commit = "bbbbbbb", .tag = "nightly" };
    const release: Info = .{ .channel = .release, .version = "0.4.0", .commit = "ccccccc", .tag = "v0.4.0" };
    try std.testing.expectEqualDeep(release, choose(test_installed, .stable, nightly, release).?);
    try std.testing.expectEqual(null, choose(test_installed, .stable, nightly, null));
}

test "choose offers a release only when its version is higher" {
    const same: Info = .{ .channel = .release, .version = "0.3.1", .commit = "ccccccc", .tag = "v0.3.1" };
    const older: Info = .{ .channel = .release, .version = "0.3.0", .commit = "ccccccc", .tag = "v0.3.0" };
    try std.testing.expectEqual(null, choose(test_installed, .stable, null, same));
    try std.testing.expectEqual(null, choose(test_installed, .stable, null, older));
}

test "choose offers nothing when updates are off" {
    const release: Info = .{ .channel = .release, .version = "9.0.0", .commit = "ccccccc", .tag = "v9.0.0" };
    try std.testing.expectEqual(null, choose(test_installed, .off, null, release));
}

test "isArmExecutable checks the ELF header and the machine" {
    var head: [20]u8 = @splat(0);
    @memcpy(head[0..4], "\x7fELF");
    head[18] = 40;
    try std.testing.expect(isArmExecutable(&head));
    head[18] = 62; // x86-64
    try std.testing.expect(!isArmExecutable(&head));
    try std.testing.expect(!isArmExecutable("<html>Not Found</html>"));
}

const builtin = @import("builtin");
const std = @import("std");
const pb = @import("c");

/// Connects to the network if the reader is not connected yet. False if that did not work.
pub fn ensureNetwork() bool {
    if (pb.QueryNetwork() & pb.NET_CONNECTED != 0) return true;

    return pb.NetConnect(null) == pb.NET_OK;
}

/// Asks the reader's library scanner to index `dir`, so a new book shows up in the library
/// right away instead of after the next reboot.
pub fn rescanLibrary(comptime dir: []const u8) void {
    const task = pb.FindTaskByAppName("scanner.app");
    trace("scanner task={d}\n", .{task});
    if (task == -1) return;

    // InkView wants a writable buffer
    var request = ("-scan:" ++ dir).*;
    const result = pb.SendRequestTo(task, pb.REQ_OPENBOOK, &request, request.len + 1, 0, 2000);
    trace("scan request result={d}\n", .{result});
}

/// Writes to the log of the dev build, release builds stay silent.
/// Zig's own I/O layer makes system calls the reader's 3.10 kernel lacks, so write through libc.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// InkView has to finish closing one keyboard or dialog before the next one opens,
/// so every following step starts from a short timer
pub fn later(step: *const fn () callconv(.c) void) void {
    pb.SetWeakTimer("opds-step", @ptrCast(step), 100);
}

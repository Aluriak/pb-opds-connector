const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabihf,
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pb-opds-connector.app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.addLibraryPath(b.path("lib"));

    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include/libxml2" });

    exe.root_module.linkSystemLibrary("inkview", .{});
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.linkSystemLibrary("xml2", .{});

    b.installArtifact(exe);
}

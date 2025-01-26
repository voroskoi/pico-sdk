const std = @import("std");

pub fn build(b: *std.Build) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const Platform = enum {
        rp2040,
        rp2350,
    };
    const platform = b.option(Platform, "platform", "PICO Platform") orelse .rp2040;

    const target = switch (platform) {
        .rp2040 => std.Target.Query{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .rp2350 => unreachable,
    };
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(std.Build.StaticLibraryOptions{
        .name = "picosdk",
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
    });

    // TODO: add Boards and include the proper header files

    // TODO: bundle this lib, check if zig does it anyway
    lib.addIncludePath(std.Build.LazyPath{ .cwd_relative = "/usr/arm-none-eabi/include/" });

    var include_dirs = std.ArrayList([]const u8).init(arena.allocator());
    defer include_dirs.deinit();
    var src_files = std.ArrayList([]const u8).init(arena.allocator());
    defer src_files.deinit();

    const src_dir = try std.fs.openDirAbsolute(b.path("src").getPath(b), .{ .iterate = true });
    inline for (.{ "common", "rp2_common" }) |comp_dir| {
        var it = src_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, comp_dir)) {
                // proper dirs selected
                var source_dir: std.fs.Dir = blk: {
                    const source_dir = try std.fs.openDirAbsolute(
                        b.path(try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ "src", entry.name })).getPath(b),
                        .{ .iterate = true },
                    );
                    break :blk source_dir;
                };
                var walker = try source_dir.walk(arena.allocator());
                while (try walker.next()) |we| {
                    // std.debug.print("{s}\n", .{we.basename});
                    if (we.kind == .directory and std.mem.eql(u8, we.basename, "include")) {
                        const inc_dir = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}/{s}", .{ "src", comp_dir, we.path });
                        // std.debug.print("{s}\n", .{inc_dir});
                        try include_dirs.append(inc_dir);
                    }
                    if (we.kind == .file and std.mem.endsWith(u8, we.basename, ".c")) {
                        const src_file = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}/{s}", .{ "src", comp_dir, we.path });
                        // std.debug.print("{s}\n", .{src_file});
                        try src_files.append(src_file);
                    }
                }
            }
        }
    }

    for (include_dirs.items) |d| {
        // std.debug.print("{s}\n", .{d});
        lib.addIncludePath(b.path(d));
    }

    for (src_files.items) |sf| {
        // std.debug.print("{s}\n", .{sf});
        lib.addCSourceFile(.{
            .file = b.path(sf),
            .flags = &.{},
        });
    }

    const version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("src/common/pico_base_headers/include/pico/version.h.in") },
        .include_path = "pico/version.h",
    }, .{
        .PICO_SDK_VERSION_MAJOR = 2,
        .PICO_SDK_VERSION_MINOR = 1,
        .PICO_SDK_VERSION_REVISION = 0,
        .PICO_SDK_VERSION_STRING = "2.1.0",
    });
    lib.addConfigHeader(version_h);

    b.installArtifact(lib);
}

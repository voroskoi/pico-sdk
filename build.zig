const std = @import("std");

const Platform = enum {
    rp2040,
    rp2350,
};

const PicoSdkOptions = struct {
    platform: Platform,
    bare_metal: bool = false,
    riscv: bool = false,
};

pub fn includeDirs(b: *std.Build, options: PicoSdkOptions) ![][]const u8 {
    return (try subdirs(b, options)).includes;
}

pub fn build(b: *std.Build) !void {
    const platform = b.option(Platform, "platform", "PICO Platform") orelse .rp2040;
    const bare_metal = b.option(bool, "bm", "Flag to exclude anything except base headers from the build") orelse false;
    const riscv = b.option(bool, "riscv", "RISC-V support") orelse false;

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

    // newlib module
    const newlib = b.dependency("newlib", .{});
    _ = b.addModule("newlib", std.Build.Module.CreateOptions{
        .root_source_file = std.Build.LazyPath{
            .dependency = .{
                .dependency = newlib,
                .sub_path = "",
            },
        },
    });

    // pico-sdk module
    const pico_module = b.addModule("pico-sdk", .{});

    const lib = b.addStaticLibrary(std.Build.StaticLibraryOptions{
        .name = "pico-sdk",
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
    });

    // TODO: is this necessary?
    pico_module.linkLibrary(lib);

    const sd = try subdirs(b, .{ .platform = platform, .bare_metal = bare_metal, .riscv = riscv });

    for (sd.includes) |d| {
        lib.addIncludePath(b.path(d));
    }

    for (sd.src_files) |sf| {
        lib.addCSourceFile(.{ .file = b.path(sf), .flags = &.{} });
    }

    for (sd.asm_files) |af| {
        lib.addAssemblyFile(b.path(af));
    }
    // lib.addIncludePath(b.path("src/rp2040/boot_stage2/asminclude"));
    lib.addAssemblyFile(b.path("src/rp2_common/pico_crt0/crt0.S"));

    lib.addIncludePath(newlib.path("newlib/libc/include"));
    lib.addCSourceFile(.{ .file = b.path("src/rp2_common/pico_clib_interface/newlib_interface.c") });

    lib.addIncludePath(.{ .src_path = .{
        .owner = b,
        .sub_path = "src/rp2_common/pico_stdio_rtt/SEGGER/RTT",
    } });

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

    // const ssi_h = b.addConfigHeader(std.Build.Step.ConfigHeader.Options{
    //     .style = .{ .autoconf = std.Build.LazyPath{
    //         .src_path = .{ .owner = b, .sub_path = "src/rp2040/hardware_regs/include/hardware/regs/ssi.h" },
    //     } },
    //     .include_path = "hardware/regs/ssi.h",
    // }, .{});
    // lib.addConfigHeader(ssi_h);

    const config_autogen_h = b.addWriteFile("pico/config_autogen.h", "");
    lib.addIncludePath(config_autogen_h.getDirectory());
    lib.step.dependOn(&config_autogen_h.step);

    switch (platform) {
        .rp2040 => {
            lib.root_module.addCMacro("PICO_RP2040", "1");
            lib.root_module.addCMacro("PICO_RUNTIME_NO_INIT_MUTEX", "0");
            // lib.root_module.addCMacro("LIB_TINYUSB_HOST", "1");
            // lib.root_module.addCMacro("LIB_PICO_STDIO_USB", "0");
        },
        .rp2350 => unreachable,
    }

    lib.linkSystemLibrary("c");

    b.installArtifact(lib);
}

fn subdirs(b: *std.Build, options: PicoSdkOptions) !struct {
    includes: [][]const u8,
    src_files: [][]const u8,
    asm_files: [][]const u8,
} {
    var compile_dirs = std.ArrayList([]const u8).init(b.allocator);
    defer compile_dirs.deinit();

    switch (options.platform) {
        .rp2040 => {
            try compile_dirs.appendSlice(&BD.bare_metal);
            if (!options.bare_metal) try compile_dirs.appendSlice(&BD.common);
            try compile_dirs.appendSlice(&BD.rp2040);
        },
        .rp2350 => unreachable,
    }

    var include_dirs = std.ArrayList([]const u8).init(b.allocator);
    defer include_dirs.deinit();
    var src_files = std.ArrayList([]const u8).init(b.allocator);
    defer src_files.deinit();
    var asm_files = std.ArrayList([]const u8).init(b.allocator);
    defer asm_files.deinit();

    for (compile_dirs.items) |comp_dir| {
        var source_dir: std.fs.Dir = blk: {
            const source_dir = try std.fs.openDirAbsolute(
                b.path(try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ "src", comp_dir })).getPath(b),
                .{ .iterate = true },
            );
            break :blk source_dir;
        };
        var walker = try source_dir.walk(b.allocator);
        while (try walker.next()) |we| {
            if (we.kind == .directory and std.mem.eql(u8, we.basename, "include")) {
                const inc_dir = try std.fmt.allocPrint(b.allocator, "{s}/{s}/{s}", .{ "src", comp_dir, we.path });
                try include_dirs.append(inc_dir);
            }
            if (we.kind == .file and std.mem.endsWith(u8, we.basename, ".c")) {
                const src_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}/{s}", .{ "src", comp_dir, we.path });
                try src_files.append(src_file);
            }
            if (we.kind == .file and std.mem.endsWith(u8, we.basename, ".S")) {
                if (!options.riscv and std.mem.endsWith(u8, we.basename, "riscv.S")) continue;
                if (!options.riscv and std.mem.endsWith(u8, we.basename, "hazard3.S")) continue;
                const asm_file = try std.fmt.allocPrint(b.allocator, "{s}/{s}/{s}", .{ "src", comp_dir, we.path });
                try asm_files.append(asm_file);
            }
        }
    }

    return .{
        .includes = try include_dirs.toOwnedSlice(),
        .src_files = try src_files.toOwnedSlice(),
        .asm_files = try asm_files.toOwnedSlice(),
    };
}

// Build Directories - https://github.com/raspberrypi/pico-sdk/blob/master/src/cmake/rp2_common.cmake
const BD = struct {
    const bare_metal = [_][]const u8{
        "common/boot_picobin_headers",
        "common/boot_picoboot_headers",
        "common/boot_uf2_headers",
        "common/pico_base_headers",
        "common/pico_usb_reset_interface_headers",
        "common/hardware_claim",

        "rp2_common/boot_bootrom_headers",
        "rp2_common/pico_platform_compiler",
        "rp2_common/pico_platform_sections",
        "rp2_common/pico_platform_panic",
    };
    const common = [_][]const u8{
        "common/pico_bit_ops_headers",
        "common/pico_binary_info",
        "common/pico_divider_headers",
        "common/pico_sync",
        "common/pico_time",
        "common/pico_util",
        "common/pico_stdlib_headers",

        "rp2_common/hardware_base",

        // HAL items which expose a public (inline rp2_common) functions/macro API above the raw hardware
        "rp2_common/hardware_adc",
        "rp2_common/hardware_boot_lock",
        "rp2_common/hardware_clocks",
        "rp2_common/hardware_divider",
        "rp2_common/hardware_dma",
        "rp2_common/hardware_exception",
        "rp2_common/hardware_flash",
        "rp2_common/hardware_gpio",
        "rp2_common/hardware_i2c",
        "rp2_common/hardware_interp",
        "rp2_common/hardware_irq",
        "rp2_common/hardware_pio",
        "rp2_common/hardware_pll",
        "rp2_common/hardware_pwm",
        "rp2_common/hardware_resets",

        "rp2_common/hardware_spi",
        "rp2_common/hardware_sync",
        "rp2_common/hardware_sync_spin_lock",
        "rp2_common/hardware_ticks",
        "rp2_common/hardware_timer",
        "rp2_common/hardware_uart",
        "rp2_common/hardware_vreg",
        "rp2_common/hardware_watchdog",
        "rp2_common/hardware_xip_cache",
        "rp2_common/hardware_xosc",

        // NOTE: THE ORDERING HERE IS IMPORTANT AS SOME TARGETS CHECK ON EXISTENCE OF OTHER TARGETS
        "rp2_common/pico_aon_timer",
        // Helper functions to connect to data/functions in the bootrom
        "rp2_common/pico_bootrom",
        "rp2_common/pico_bootsel_via_double_reset",
        "rp2_common/pico_multicore",
        "rp2_common/pico_unique_id",

        // TODO
        // "rp2_common/pico_atomic",
        "rp2_common/pico_bit_ops",
        "rp2_common/pico_divider",
        // "rp2_common/pico_double",
        "rp2_common/pico_int64_ops",
        "rp2_common/pico_flash",
        "rp2_common/pico_float",
        "rp2_common/pico_mem_ops",
        "rp2_common/pico_malloc",
        "rp2_common/pico_printf",
        "rp2_common/pico_rand",

        // TODO
        // if (PICO_RP2350 OR PICO_COMBINED_DOCS)
        //     pico_add_subdirectory(rp2_common/pico_sha256)
        // endif()

        // TODO
        // "rp2_common/pico_stdio_semihosting",
        "rp2_common/pico_stdio_uart",
        // "rp2_common/pico_stdio_rtt",

        // TODO
        // if (NOT PICO_RISCV)
        //      pico_add_subdirectory(rp2_common/cmsis)
        // endif()
        // TODO
        // "rp2_common/tinyusb",
        // "rp2_common/pico_stdio_usb",
        "rp2_common/pico_i2c_slave",

        // networking libraries - note dependency order is important
        // TODO
        // "rp2_common/pico_async_context",
        // TODO
        // "rp2_common/pico_btstack",
        // "rp2_common/pico_cyw43_driver",
        // "rp2_common/pico_lwip",
        // "rp2_common/pico_cyw43_arch",
        // "rp2_common/pico_mbedtls",

        "rp2_common/pico_time_adapter",

        // "rp2_common/pico_crt0",
        // "rp2_common/pico_clib_interface", - only newlib
        "rp2_common/pico_cxx_options",
        "rp2_common/pico_standard_binary_info",
        "rp2_common/pico_standard_link",

        "rp2_common/pico_fix",

        // at the end as it includes a lot of other stuff
        "rp2_common/pico_runtime_init",
        "rp2_common/pico_runtime",

        // this requires all the pico_stdio_ libraries
        "rp2_common/pico_stdio",
        // this requires runtime
        "rp2_common/pico_stdlib",
    };
    const rp2040 = [_][]const u8{
        "rp2040/pico_platform",
        "rp2040/hardware_regs",
        "rp2040/hardware_structs",
        // "rp2040/boot_stage2",

        "rp2_common/hardware_rtc",
    };
    const rp2350 = [_][]const u8{
        "rp2350/pico_platform",
        "rp2350/hardware_regs",
        "rp2350/hardware_structs",
        // "rp2350/boot_stage2",

        "rp2_common/hardware_powman",
        // Note in spite of the name this is usable on Arm as well as RISC-V
        "rp2_common/hardware_riscv_platform_timer",
        "rp2_common/hardware_sha256",

        "rp2_common/hardware_dcp",
        "rp2_common/hardware_rcp",
    };
};

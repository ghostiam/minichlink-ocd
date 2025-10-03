const std = @import("std");
const builtin = @import("builtin");

// Run: `zig build`
// Requirements:
// MacOS: install XCode
// Linux: apt install libudev-dev
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = if (b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    )) |mode| mode else .ReleaseFast;

    const minichlink = try buildMinichlink(b, .exe, target, optimize);
    b.installArtifact(minichlink);

    const build_lib = b.step("lib", "Build the minichlink as library");
    const minichlink_lib = try buildMinichlink(b, .lib, target, optimize);
    const install_minichlink_lib = b.addInstallArtifact(minichlink_lib, .{});
    build_lib.dependOn(&install_minichlink_lib.step);

    const minichlink_ocd = try buildMinichlinkOcd(b, target, optimize, minichlink_lib);

    const run_step = b.step("run", "Run the minichlink-ocd");
    const ocd_run = b.addRunArtifact(minichlink_ocd);
    run_step.dependOn(&ocd_run.step);

    const test_step = b.step("test", "Run tests");
    const minichlink_ocd_tests = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    // b.installArtifact(minichlink_ocd_tests);
    const minichlink_ocd_tests_run = b.addRunArtifact(minichlink_ocd_tests);
    test_step.dependOn(&minichlink_ocd_tests_run.step);
}

fn buildMinichlink(
    b: *std.Build,
    kind: std.Build.Step.Compile.Kind,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const libusb_dep = b.dependency("libusb", .{});
    const libusb = try createLibusb(b, libusb_dep, target, optimize);

    const minichlink_dep = b.dependency("ch32fun", .{});
    const minichlink = try createMinichlink(b, minichlink_dep, kind, target, optimize);
    minichlink.linkLibrary(libusb);

    return minichlink;
}

fn createMinichlink(
    b: *std.Build,
    dep: *std.Build.Dependency,
    kind: std.Build.Step.Compile.Kind,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const root_path = dep.path("minichlink");
    const exe = std.Build.Step.Compile.create(b, .{
        .name = "minichlink",
        .kind = kind,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
        }),
    });

    if (kind == .lib) {
        exe.linkage = .static;
        exe.root_module.addCMacro("MINICHLINK_AS_LIBRARY", "1");
        exe.installHeader(root_path.path(b, "minichlink.h"), "minichlink.h");
    }

    exe.linkLibC();
    exe.addIncludePath(root_path);
    exe.addCSourceFiles(.{
        .root = root_path,
        .files = &.{
            "minichlink.c",
            "pgm-wch-linke.c",
            "pgm-esp32s2-ch32xx.c",
            "nhc-link042.c",
            "ardulink.c",
            "serial_dev.c",
            "pgm-b003fun.c",
            "minichgdb.c",
        },
    });
    exe.root_module.addCMacro("MINICHLINK", "1");
    exe.root_module.addCMacro("CH32V003", "1");
    // Without this, the build fails with "error: unknown register name 'a5' in asm"
    exe.root_module.addCMacro("__DELAY_TINY_DEFINED__", "1");

    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.addCMacro("__MACOSX__", "1");
            exe.linkFramework("CoreFoundation");
            exe.linkFramework("IOKit");
        },
        .linux, .netbsd, .openbsd => {
            const rules = b.addInstallBinFile(try root_path.join(b.allocator, "99-minichlink.rules"), "99-minichlink.rules");
            exe.step.dependOn(&rules.step);
        },
        .windows => {
            exe.root_module.addCMacro("_WIN32_WINNT", "0x0600");
            exe.addLibraryPath(dep.path("minichlink"));
            exe.linkSystemLibrary("setupapi");
            exe.linkSystemLibrary("ws2_32");
        },
        else => {},
    }

    try addPaths(exe.root_module, target);

    return exe;
}

fn defineBool(b: bool) ?u1 {
    return if (b) 1 else null;
}

fn createLibusb(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const is_posix = target.result.os.tag != .windows;
    const config_header = b.addConfigHeader(.{ .style = .blank }, .{
        ._GNU_SOURCE = 1,
        .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
        .@"PRINTF_FORMAT(a, b)" = .@"/* */",
        .PLATFORM_POSIX = defineBool(is_posix),
        .PLATFORM_WINDOWS = defineBool(target.result.os.tag == .windows),
        // .ENABLE_DEBUG_LOGGING = defineBool(optimize == .Debug),
        .ENABLE_LOGGING = 1,
        .HAVE_CLOCK_GETTIME = defineBool(target.result.os.tag != .windows),
        .HAVE_EVENTFD = null,
        .HAVE_TIMERFD = null,
        .USE_SYSTEM_LOGGING_FACILITY = null,
        .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
        .HAVE_PTHREAD_SETNAME_NP = null,
        .HAVE_PTHREAD_THREADID_NP = null,
    });

    const lib = std.Build.Step.Compile.create(b, .{
        .name = "usb",
        .version = .{ .major = 1, .minor = 0, .patch = 27 },

        .kind = .lib,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
        }),
    });
    lib.installHeader(dep.path("libusb/libusb.h"), "libusb.h");
    lib.linkLibC();
    lib.addIncludePath(dep.path("libusb"));
    lib.addConfigHeader(config_header);
    lib.addCSourceFiles(.{
        .root = dep.path("libusb"),
        .files = &.{
            "core.c",
            "descriptor.c",
            "hotplug.c",
            "io.c",
            "strerror.c",
            "sync.c",
        },
    });

    switch (target.result.os.tag) {
        .macos => {
            lib.addIncludePath(dep.path("Xcode"));
        },
        .windows => {
            lib.addIncludePath(dep.path("msvc"));
        },
        else => {},
    }

    if (is_posix) {
        lib.addCSourceFiles(.{
            .root = dep.path("libusb/os"),
            .files = &.{
                "events_posix.c",
                "threads_posix.c",
            },
        });
    } else {
        lib.addCSourceFiles(.{
            .root = dep.path("libusb/os"),
            .files = &.{
                "events_windows.c",
                "threads_windows.c",
            },
        });
    }
    if (target.result.abi.isAndroid()) {
        lib.addIncludePath(dep.path("android"));
    }

    switch (target.result.os.tag) {
        .macos => {
            lib.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"darwin_usb.c"},
            });
            lib.linkFramework("IOKit");
            lib.linkFramework("CoreFoundation");
            lib.linkFramework("Security");
        },
        .linux => {
            lib.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{
                    "linux_usbfs.c",
                    "linux_netlink.c",
                    "linux_udev.c",
                },
            });
            lib.linkSystemLibrary2("udev", .{ .use_pkg_config = .no });
        },
        .windows => {
            lib.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{
                    "windows_common.c",
                    "windows_usbdk.c",
                    "windows_winusb.c",
                },
            });
            lib.addWin32ResourceFile(.{ .file = dep.path("libusb/libusb-1.0.rc") });
        },
        .netbsd => {
            lib.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"netbsd_usb.c"},
            });
        },
        .openbsd => {
            lib.addCSourceFiles(.{
                .root = dep.path("libusb/os"),
                .files = &.{"openbsd_usb.c"},
            });
        },
        else => {},
    }

    try addPaths(lib.root_module, target);

    return lib;
}

fn buildMinichlinkOcd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    minichlink_lib: *std.Build.Step.Compile,
) !*std.Build.Step.Compile {
    const minichlink_dep = b.dependency("ch32fun", .{});
    const minichlink_root_path = minichlink_dep.path("minichlink");

    const ocd = b.addExecutable(.{
        .name = "minichlink-ocd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .sanitize_thread = false,
        }),
    });
    ocd.linkLibrary(minichlink_lib);
    ocd.root_module.addAnonymousImport("build_zig_zon", .{ .root_source_file = b.path("build.zig.zon") });

    const main_file_path = minichlink_dep.builder.pathFromRoot("minichlink/minichlink.c");
    const minichlink_main_file = CopyAndPatchMinichlinkMainFile.create(
        b,
        main_file_path,
        "src/minichlink-patched.c",
    );
    ocd.step.dependOn(&minichlink_main_file.step);

    ocd.addIncludePath(minichlink_root_path);
    ocd.addIncludePath(b.path("src"));
    ocd.addCSourceFile(.{ .file = b.path(minichlink_main_file.dest_rel_path) });

    try addPaths(ocd.root_module, target);

    b.getInstallStep().dependOn(&b.addInstallArtifact(ocd, .{}).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.addWriteFiles().add("wch-riscv.cfg", ""), .{ .custom = b.pathJoin(&.{ "share", "openocd", "scripts", "board" }) }, "wch-riscv.cfg").step);

    return ocd;
}

const CopyAndPatchMinichlinkMainFile = struct {
    step: std.Build.Step,
    source: []const u8,
    dest_rel_path: []const u8,

    pub fn create(
        owner: *std.Build,
        source: []const u8,
        dest_rel_path: []const u8,
    ) *CopyAndPatchMinichlinkMainFile {
        const copy_file = owner.allocator.create(CopyAndPatchMinichlinkMainFile) catch @panic("OOM");
        copy_file.* = .{
            .step = std.Build.Step.init(.{
                .id = .install_file,
                .name = owner.fmt("copy and patch {s} to {s}", .{ source, dest_rel_path }),
                .owner = owner,
                .makeFn = make,
            }),
            .source = source,
            .dest_rel_path = owner.dupePath(dest_rel_path),
        };
        return copy_file;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const copy_file: *CopyAndPatchMinichlinkMainFile = @fieldParentPtr("step", step);

        const cwd = std.fs.cwd();

        const full_src_path = copy_file.source;

        const src_file = std.fs.openFileAbsolute(copy_file.source, .{}) catch |err| {
            return step.fail("unable to open file '{s}': {s}", .{
                full_src_path, @errorName(err),
            });
        };
        defer src_file.close();

        const stat = try src_file.stat();

        const buf = try b.allocator.alloc(u8, stat.size);
        defer b.allocator.free(buf);

        _ = try src_file.readAll(buf);

        // Find start and end of the main function.
        const main_start, const main_end = findFunction(buf, "int main(") orelse return step.fail("unable to find main function in '{s}'", .{copy_file.source});
        const str_mem_start, const str_mem_end = findFunction(buf[main_start..], "int64_t StringToMemoryAddress(") orelse return step.fail("unable to find StringToMemoryAddress function in '{s}'", .{copy_file.source});

        const dest_file = cwd.createFile(copy_file.dest_rel_path, .{ .truncate = true }) catch |err| {
            return step.fail("unable to create file '{s}': {s}", .{
                copy_file.dest_rel_path, @errorName(err),
            });
        };
        defer dest_file.close();

        // Write header.
        try dest_file.writeAll(
            \\#include <stdio.h>
            \\#include <string.h>
            \\#include <stdlib.h>
            \\#include <getopt.h>
            \\#include "terminalhelp.h"
            \\#include "minichlink.h"
            \\
            \\#if defined(WINDOWS) || defined(WIN32) || defined(_WIN32)
            \\extern int isatty(int);
            \\#if !defined(_SYNCHAPI_H_) && !defined(__TINYC__)
            \\void Sleep(uint32_t dwMilliseconds);
            \\#endif
            \\#else
            \\#include <pwd.h>
            \\#include <unistd.h>
            \\#include <grp.h>
            \\#endif
            \\
            \\static int64_t StringToMemoryAddress( const char * number ) __attribute__((used));
            \\void PostSetupConfigureInterface( void * dev );
            \\
            \\int orig_main( int argc, char ** argv )
        );

        const main_start_offset = std.mem.indexOf(u8, buf[main_start..], "\n") orelse unreachable;
        // Write the functions.
        try dest_file.writeAll(buf[main_start + main_start_offset .. main_end]);
        try dest_file.writeAll(buf[main_start + str_mem_start .. main_start + str_mem_end]);
    }
};

fn findFunction(buf: []const u8, name: []const u8) ?struct { usize, usize } {
    const func_start = std.mem.indexOf(u8, buf, name) orelse {
        return null;
    };

    // Search for the end of the main function.
    var maybe_brackets: ?usize = null;
    var maybe_func_end_offset: ?usize = 0;
    for (buf[func_start..], 0..) |c, i| {
        const brackets = maybe_brackets orelse {
            if (c == '{') {
                maybe_brackets = 1;
            }
            continue;
        };

        if (c == '{') {
            maybe_brackets = brackets + 1;
        } else if (c == '}') {
            maybe_brackets = brackets - 1;
        }

        if (brackets == 0) {
            maybe_func_end_offset = i + 1;
            break;
        }
    }

    const func_end_offset = maybe_func_end_offset orelse return null;

    return .{ func_start, func_start + func_end_offset };
}

pub fn addPaths(mod: *std.Build.Module, target: std.Build.ResolvedTarget) !void {
    const b = mod.owner;

    const paths = try std.zig.system.NativePaths.detect(b.allocator, &target.result);

    for (paths.lib_dirs.items) |item| {
        std.fs.cwd().access(item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addLibraryPath(.{ .cwd_relative = item });
    }
    for (paths.include_dirs.items) |item| {
        std.fs.cwd().access(item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addSystemIncludePath(.{ .cwd_relative = item });
    }
    for (paths.framework_dirs.items) |item| {
        std.fs.cwd().access(item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addSystemFrameworkPath(.{ .cwd_relative = item });
    }
    for (paths.rpaths.items) |item| {
        std.fs.cwd().access(item, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        mod.addRPath(.{ .cwd_relative = item });
    }
}

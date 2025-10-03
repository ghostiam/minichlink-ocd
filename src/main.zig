const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("minichlink.h");
    @cInclude("minichlink-patched.c");
});

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    const allocator = gpa;
    // var arena = std.heap.ArenaAllocator.init(gpa);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch |err| {
        std.debug.print("Failed to allocate arguments\n", .{});
        return err;
    };
    defer std.process.argsFree(allocator, args);

    const ocd_args = try OcdArgs.parse(allocator, args);
    defer allocator.destroy(ocd_args);

    if (ocd_args.show_version) {
        const version = try versionFromZon(allocator);
        defer versionFromZonFree(allocator, version);

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.print("Minichlink As Open On-Chip Debugger {s}\n", .{version.version});
        return 0;
    }

    var minichlink_args: std.ArrayList([*:0]u8) = .empty;
    defer minichlink_args.deinit(allocator);
    try minichlink_args.append(allocator, args[0]);

    var programZ: ?[:0]u8 = null;
    if (ocd_args.program) |program| {
        if (std.mem.eql(u8, std.fs.path.extension(program), ".elf")) {
            programZ = try std.mem.concatWithSentinel(allocator, u8, &.{ program[0 .. program.len - "elf".len], "bin" }, 0);
            errdefer allocator.free(programZ.?);

            // Check file exists
            const file = std.fs.openFileAbsoluteZ(programZ.?, .{ .mode = .read_only }) catch |err| {
                std.log.err("Failed to open file: {s}: {}\n", .{ programZ.?, err });
                return err;
            };
            file.close();
        } else {
            programZ = try allocator.dupeZ(u8, program);
        }

        try minichlink_args.append(allocator, @constCast("-w"));
        try minichlink_args.append(allocator, programZ.?);
        try minichlink_args.append(allocator, @constCast("flash"));
    }
    defer if (programZ) |v| {
        allocator.free(v);
    };

    if (ocd_args.reset) {
        if (ocd_args.halt) {
            // Reboot into Halt.
            try minichlink_args.append(allocator, @constCast("-a"));
        } else {
            // reBoot
            try minichlink_args.append(allocator, @constCast("-b"));
        }
    } else {
        // rEsume
        try minichlink_args.append(allocator, @constCast("-e"));
    }

    if (ocd_args.gdb_port > 0) {
        try minichlink_args.append(allocator, @constCast("-G"));
    }

    if (ocd_args.echo) |echo| {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.writeAll(echo);
    }

    const argv: [][*:0]u8 = @constCast(minichlink_args.items);
    const argv_c_ptr: [*c][*c]u8 = @ptrCast(argv.ptr);
    const code = c.orig_main(@intCast(argv.len), argv_c_ptr);
    if (code != 0) {
        std.log.err("Error code: {}", .{code});
    }
    return @truncate(@as(c_uint, @bitCast(code)));
}

const OcdArgs = struct {
    show_version: bool = false,
    reset: bool = false,
    halt: bool = false,
    run: bool = false,
    program: ?[]const u8 = null,
    gdb_port: u16 = 0,
    echo: ?[]const u8 = null,

    fn parse(allocator: std.mem.Allocator, args: [][:0]u8) !*OcdArgs {
        const ocd_args = try allocator.create(OcdArgs);
        ocd_args.* = OcdArgs{};

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--version")) {
                ocd_args.show_version = true;
                continue;
            }

            if (std.mem.eql(u8, arg, "-c")) {
                while (i < args.len) {
                    i += 1;
                    if (i >= args.len) {
                        break;
                    }

                    const command = args[i];
                    if (std.mem.startsWith(u8, command, "-")) {
                        i -= 1;
                        break;
                    }

                    if (std.mem.startsWith(u8, command, "echo ")) {
                        ocd_args.echo = trimPrefix(command, "echo ");
                        continue;
                    }

                    if (std.mem.startsWith(u8, command, "program ")) {
                        ocd_args.program = std.mem.trim(u8, trimPrefix(command, "program "), " \"");
                        continue;
                    }

                    if (std.mem.startsWith(u8, command, "gdb_port ")) {
                        const gdb_port_str = std.mem.trim(u8, trimPrefix(command, "gdb_port "), " \"");
                        if (std.mem.eql(u8, gdb_port_str, "disabled")) continue;

                        const gdb_port = std.fmt.parseInt(u16, gdb_port_str, 10) catch |err| {
                            std.debug.print("Failed to parse gdb_port: {s}: {}\n", .{ gdb_port_str, err });
                            return err;
                        };
                        ocd_args.gdb_port = gdb_port;
                        continue;
                    }

                    if (std.mem.containsAtLeast(u8, command, 1, "reset")) {
                        ocd_args.reset = true;
                    }

                    if (std.mem.containsAtLeast(u8, command, 1, "halt")) {
                        ocd_args.halt = true;
                    }

                    if (std.mem.containsAtLeast(u8, command, 1, "run")) {
                        ocd_args.run = true;
                    }
                }
            }
        }

        return ocd_args;
    }

    fn trimPrefix(
        haystack: []const u8,
        prefix: []const u8,
    ) []const u8 {
        if (std.mem.startsWith(u8, haystack, prefix)) {
            return haystack[prefix.len..];
        }
        return haystack;
    }
};

test "OcdArgs.parse" {
    // Version
    {
        const args_raw: []const [:0]const u8 = &.{"--version"};
        const expected = OcdArgs{ .show_version = true };

        try testOcdArgsParse(expected, args_raw);
    }

    // Download firmware
    {
        const args_raw: []const [:0]const u8 = &.{ "-s", "/openocd/share/openocd/scripts", "-f", "target/wch-riscv.cfg", "-c", "tcl_port disabled", "-c", "gdb_port disabled", "-c", "tcl_port disabled", "-c", "program /ch32_zig/examples/debug_sdi_print/zig-out/firmware/debug_sdi_print_ch32v003.elf", "-c", "reset", "-c", "shutdown" };
        const expected = OcdArgs{
            .program = "/ch32_zig/examples/debug_sdi_print/zig-out/firmware/debug_sdi_print_ch32v003.elf",
            .reset = true,
        };

        try testOcdArgsParse(expected, args_raw);
    }

    // Debug
    {
        const args_raw: []const [:0]const u8 = &.{ "-c", "tcl_port disabled", "-c", "gdb_port 3333", "-c", "telnet_port 4444", "-s", "/openocd/share/openocd/scripts", "-f", "target/wch-riscv.cfg", "-c", "init;reset halt", "-c", "echo (((READY)))" };
        const expected = OcdArgs{
            .reset = true,
            .halt = true,
            .gdb_port = 3333,
            .echo = "(((READY)))",
        };

        try testOcdArgsParse(expected, args_raw);
    }

    // Download and debug
    {
        const args_raw: []const [:0]const u8 = &.{ "-c", "tcl_port disabled", "-c", "gdb_port 3333", "-c", "telnet_port 4444", "-s", "/openocd/share/openocd/scripts", "-f", "target/wch-riscv.cfg", "-c", "program /ch32_zig/examples/debug_sdi_print/zig-out/firmware/debug_sdi_print_ch32v003.elf", "-c", "init;reset halt", "-c", "echo (((READY)))" };
        const expected = OcdArgs{
            .program = "/ch32_zig/examples/debug_sdi_print/zig-out/firmware/debug_sdi_print_ch32v003.elf",
            .reset = true,
            .halt = true,
            .gdb_port = 3333,
            .echo = "(((READY)))",
        };

        try testOcdArgsParse(expected, args_raw);
    }
}

fn testOcdArgsParse(expected: OcdArgs, args_raw: []const [:0]const u8) !void {
    const allocator = std.testing.allocator;

    var args = std.ArrayList([:0]u8).init(allocator);
    defer args.deinit();

    for (args_raw) |arg_raw| {
        try args.append(@constCast(arg_raw));
    }

    const actual = try OcdArgs.parse(allocator, args.items);
    defer allocator.destroy(actual);

    std.log.info("expected: {}, actual: {}", .{ expected, actual });

    try std.testing.expectEqualDeep(expected, actual.*);
}

const Version = struct { version: []const u8 };

fn versionFromZon(allocator: std.mem.Allocator) !Version {
    const build_zig_zon = @embedFile("build_zig_zon");
    const version = try std.zon.parse.fromSlice(
        Version,
        allocator,
        build_zig_zon,
        null,
        .{ .ignore_unknown_fields = true },
    );

    return version;
}

fn versionFromZonFree(allocator: std.mem.Allocator, version: Version) void {
    std.zon.parse.free(allocator, version);
}

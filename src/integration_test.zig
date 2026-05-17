const std = @import("std");

// ---------------------------------------------------------------------------
// CLI exit-code integration tests
//
// These are *integration* tests, not unit tests: each one spawns the real,
// freshly built `ken` binary as a subprocess and inspects its termination
// status. They deliberately do not call any in-process Zig function, so they
// live outside the default `zig build test` (unit) path and run only via
// `zig build test-integration`, which builds the binary and injects its
// absolute path through `build_options`.
//
// The contract these tests pin down: *every* failure mode of the ken CLI
// terminates with exit status 1, while success paths terminate with 0. The
// exit code is the centralized invariant (`main` turns any error returned by
// `run` into `std.process.exit(1)`), so the only faithful way to test it is to
// spawn the real binary and inspect its termination status. The binary's
// absolute path is injected by build.zig via `build_options`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const build_options = @import("build_options");

/// Spawn the built `ken` binary with `argv` and return its exit code.
/// `argv` is the arguments *after* the program name.
fn runKenExitCode(gpa: std.mem.Allocator, argv: []const []const u8) !u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var full = std.ArrayList([]const u8).empty;
    defer full.deinit(gpa);
    try full.append(gpa, build_options.ken_exe_path);
    try full.appendSlice(gpa, argv);

    const result = try std.process.run(gpa, io, .{ .argv = full.items });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code,
        else => error.AbnormalTermination,
    };
}

test "cli exit: version succeeds (exit 0)" {
    const code = try runKenExitCode(testing.allocator, &.{"version"});
    try testing.expectEqual(@as(u8, 0), code);
}

test "cli exit: help succeeds (exit 0)" {
    const code = try runKenExitCode(testing.allocator, &.{"help"});
    try testing.expectEqual(@as(u8, 0), code);
}

test "cli exit: no command is an error (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{});
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: unknown command (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{"definitelynotacommand"});
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: unknown flag (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{ "add", "note", "--definitely-not-a-flag" });
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: show with no args is an error (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{"show"});
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: -D/--db without a value (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{"-D"});
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: relate missing required options (exit 1)" {
    const code = try runKenExitCode(testing.allocator, &.{ "relate", "-o", "x", "-r", "cites" });
    try testing.expectEqual(@as(u8, 1), code);
}

test "cli exit: show not-found is an error (exit 1)" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The test process runs with the project root as its cwd, and the child
    // process inherits it, so a path relative to cwd resolves identically in
    // both. tmpDir creates `.zig-cache/tmp/<sub_path>/`.
    const db_file = try std.fmt.allocPrint(
        gpa,
        ".zig-cache/tmp/{s}/ken-test.db",
        .{tmp.sub_path},
    );
    defer gpa.free(db_file);

    const init_code = try runKenExitCode(gpa, &.{ "-D", db_file, "init" });
    try testing.expectEqual(@as(u8, 0), init_code);

    const code = try runKenExitCode(gpa, &.{
        "-D",   db_file,
        "show", "00000000-0000-0000-0000-000000000000",
    });
    try testing.expectEqual(@as(u8, 1), code);
}

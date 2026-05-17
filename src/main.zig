const std = @import("std");
const ken = @import("ken");
const Io = std.Io;

const usage =
    \\Usage: ken [-D <path>] <command> [options]
    \\
    \\Options:
    \\
++ ken.db_flag_help ++
    \\
    \\Commands:
    \\  version    Print ken version
    \\  init       Create or upgrade a ken database
    \\  initpath   Print default database path
    \\  dbversion  Print schema version of a ken database
    \\  add        Add a publication
    \\  relate     Create a relationship between publications
    \\  list       List publications
    \\  show       Show a publication's record, note body, and relationships
    \\  load       Load publications from a JSON file
    \\  merge      Merge two ken databases
    \\  skill      Generate agent skills
    \\  pubkind    Manage publication kinds
    \\  relkind    Manage relationship kinds
    \\  help       Show this help message
    \\
;

const Command = enum {
    version,
    init,
    initpath,
    dbversion,
    add,
    relate,
    list,
    show,
    load,
    merge,
    skill,
    pubkind,
    relkind,
    help,
};

fn printCommandUsage(cmd: Command, stdout: anytype) !void {
    switch (cmd) {
        .version => try stdout.writeAll("Usage: ken version\n\nPrint ken version.\n"),
        .init => try stdout.writeAll("Usage: ken [-D <path>] init\n\nCreate or upgrade a ken database.\nIf -D is not given, uses the default location.\n"),
        .initpath => try stdout.writeAll("Usage: ken initpath\n\nPrint the default database path for this platform.\n"),
        .dbversion => try stdout.writeAll("Usage: ken [-D <path>] dbversion\n\nPrint schema version of a ken database.\nIf -D is not given, uses the default location.\n"),
        .add => try stdout.writeAll(ken.addUsage),
        .relate => try stdout.writeAll(ken.relateUsage),
        .list => try stdout.writeAll(ken.listUsage),
        .show => try stdout.writeAll(ken.showUsage),
        .load => try stdout.writeAll(ken.loadUsage),
        .pubkind => try stdout.writeAll(ken.kindUsage(.pubkind)),
        .relkind => try stdout.writeAll(ken.kindUsage(.relkind)),
        .merge => try stdout.writeAll(ken.mergeUsage),
        .skill => try stdout.writeAll(ken.skillUsage),
        .help => try stdout.writeAll(usage),
    }
}

/// Sentinel error meaning "a diagnostic has already been written to stderr".
/// Any command handler that detects a failure writes its human-readable
/// message to stderr and then returns this (or any other) error. `main`
/// catches *every* error returned by `run` and terminates the process with
/// exit code 1, so every failure mode of the CLI is non-zero while success
/// paths return normally (exit 0). Centralizing the exit here means no
/// individual call site has to remember to call `std.process.exit(1)`.
const CliError = error{Reported};

pub fn main(process: std.process.Init) !void {
    run(process) catch {
        // `run` has already written a descriptive "Error: ..." message to
        // stderr (and flushed it where possible). Exit non-zero so shell
        // idioms like `ken show <id> || ...` work as expected. Any error
        // returned from `run` — argument errors, usage errors, not-found,
        // database errors, file errors, JSON parse errors, conflicts,
        // unknown commands/flags, missing required options — lands here.
        std.process.exit(1);
    };
}

fn run(process: std.process.Init) !void {
    const arena = process.arena.allocator();
    const raw_args = try process.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), process.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), process.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Extract -D/--db from args and build filtered args
    var explicit_db_path: ?[:0]const u8 = null;
    var filtered: std.ArrayList([:0]const u8) = .empty;
    {
        var i: usize = 0;
        while (i < raw_args.len) : (i += 1) {
            const arg: []const u8 = raw_args[i];
            if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--db")) {
                i += 1;
                if (i >= raw_args.len) {
                    stderr.print("Error: -D/--db requires a path argument\n", .{}) catch {};
                    stderr.flush() catch {};
                    return error.Reported;
                }
                explicit_db_path = raw_args[i];
            } else {
                try filtered.append(arena, raw_args[i]);
            }
        }
    }
    const args = filtered.items;

    if (args.len < 2) {
        stderr.print(usage, .{}) catch {};
        stderr.flush() catch {};
        return error.Reported;
    }

    if (ken.isHelpFlag(args[1])) {
        try stdout.print(usage, .{});
        try stdout.flush();
        return;
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        stderr.print("Unknown command: {s}\n\n" ++ usage, .{args[1]}) catch {};
        stderr.flush() catch {};
        return error.Reported;
    };

    // Help flag check for commands without their own argument parsers.
    // Commands with subcommands (pubkind, relkind) and commands with their
    // own parsers (add) handle -h internally so help is scoped to the
    // specific subcommand being asked about.
    switch (cmd) {
        .pubkind, .relkind, .add, .relate, .list, .show, .load, .merge => {},
        else => {
            if (hasHelpFlag(args[2..])) {
                try printCommandUsage(cmd, stdout);
                try stdout.flush();
                return;
            }
        },
    }

    switch (cmd) {
        .help => {
            try stdout.print(usage, .{});
            try stdout.flush();
        },
        .version => {
            try stdout.print("{d}\n", .{ken.version});
            try stdout.flush();
        },
        .initpath => {
            const db_path = ken.defaultDbPath(arena) catch {
                try stderr.print("Error: could not determine default database path\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            try stdout.print("{s}\n", .{db_path});
            try stdout.flush();
        },
        .init => {
            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            if (explicit_db_path == null) {
                if (std.fs.path.dirname(db_path)) |dir_path| {
                    Io.Dir.createDirAbsolute(process.io, dir_path, .default_dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => {
                            try stderr.print("Error: could not create directory '{s}'\n", .{dir_path});
                            try stderr.flush();
                            return error.Reported;
                        },
                    };
                }
            }
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();
            const prev = database.getVersion() catch {
                try stderr.print("Error: could not read version from '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            const v = database.migrate(ken.migrations) catch |err| {
                if (err == error.DatabaseAheadOfMigrations) {
                    try stderr.print("Error: database is ahead of this version of ken\n", .{});
                } else {
                    try stderr.print("Error: migration failed\n", .{});
                }
                try stderr.flush();
                return error.Reported;
            };
            if (prev != null and prev.? == v) {
                try stdout.print("Database at {s} already at version {d}, nothing to do\n", .{ db_path, v });
            } else {
                try stdout.print("Initialized ken database at {s} (version {d})\n", .{ db_path, v });
            }
            try stdout.flush();
        },
        .dbversion => {
            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();
            const v = database.getVersion() catch {
                try stderr.print("Error: could not read version from '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            if (v) |ver| {
                try stdout.print("{d}\n", .{ver});
            } else {
                try stdout.print("not initialized\n", .{});
            }
            try stdout.flush();
        },
        .add => {
            const action = ken.parseAddArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.addUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing argument. Usage: ken add <kind> [-k/--key <key>] [--title <title>]\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unknown flag. Usage: ken add <kind> [-k/--key <key>] [--title <title>]\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'add'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            // Validate that the kind exists
            const kind_exists = database.exists(
                "SELECT 1 FROM publication_kinds WHERE name = ?1;",
                &.{action.kind},
            ) catch {
                try stderr.print("Error: could not query database\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            if (!kind_exists) {
                try stderr.print("Error: unknown publication kind '{s}'\n", .{action.kind});
                try stderr.flush();
                return error.Reported;
            }

            // Generate UUID and insert publication
            const uuid = genUuid(process.io);

            database.execParams(
                "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
                &.{ &uuid, action.key, action.kind, action.title },
            ) catch {
                try stderr.print("Error: could not insert publication\n", .{});
                try stderr.flush();
                return error.Reported;
            };

            // For notes with a file key, read file and insert into notes table
            if (std.mem.eql(u8, action.kind, "note")) {
                if (action.key) |key| {
                    const max_note_size = 10 * 1024 * 1024; // 10 MB
                    const file_content = blk: {
                        const file = Io.Dir.openFile(.cwd(), process.io, key, .{}) catch break :blk null;
                        defer file.close(process.io);
                        const stat = file.stat(process.io) catch break :blk null;
                        const size: usize = @intCast(stat.size);
                        if (size == 0 or size > max_note_size) break :blk null;
                        const buf = arena.alloc(u8, size) catch break :blk null;
                        const n = file.readPositionalAll(process.io, buf, 0) catch break :blk null;
                        break :blk buf[0..n];
                    };
                    if (file_content) |content| {
                        const note_uuid = genUuid(process.io);

                        database.execParams(
                            "INSERT INTO notes (id, publication, body) VALUES (?1, ?2, ?3);",
                            &.{ &note_uuid, &uuid, content },
                        ) catch {
                            try stderr.print("Error: could not insert note body\n", .{});
                            try stderr.flush();
                            return error.Reported;
                        };
                    }
                }
            }

            try stdout.print("{s}\n", .{&uuid});
            try stdout.flush();
        },
        .relate => {
            const action = ken.parseRelateArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.relateUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing argument. Usage: ken relate -s <id> -o <id> -r <kind>\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unknown flag. Usage: ken relate -s <id> -o <id> -r <kind>\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'relate'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            // Validate subject exists
            const subject_exists = database.exists(
                "SELECT 1 FROM publications WHERE id = ?1;",
                &.{action.subject},
            ) catch {
                try stderr.print("Error: could not query database\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            if (!subject_exists) {
                try stderr.print("Error: subject publication '{s}' not found\n", .{action.subject});
                try stderr.flush();
                return error.Reported;
            }

            // Validate object exists
            const object_exists = database.exists(
                "SELECT 1 FROM publications WHERE id = ?1;",
                &.{action.object},
            ) catch {
                try stderr.print("Error: could not query database\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            if (!object_exists) {
                try stderr.print("Error: object publication '{s}' not found\n", .{action.object});
                try stderr.flush();
                return error.Reported;
            }

            // Validate relationship kind exists
            const kind_exists = database.exists(
                "SELECT 1 FROM relationship_kinds WHERE name = ?1;",
                &.{action.kind},
            ) catch {
                try stderr.print("Error: could not query database\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            if (!kind_exists) {
                try stderr.print("Error: unknown relationship kind '{s}'\n", .{action.kind});
                try stderr.flush();
                return error.Reported;
            }

            // Generate UUID and insert relationship
            const uuid = genUuid(process.io);

            database.execParams(
                "INSERT INTO relationships (id, subject, object, kind) VALUES (?1, ?2, ?3, ?4);",
                &.{ &uuid, action.subject, action.object, action.kind },
            ) catch {
                try stderr.print("Error: could not insert relationship\n", .{});
                try stderr.flush();
                return error.Reported;
            };

            try stdout.print("{s}\n", .{&uuid});
            try stdout.flush();
        },
        .list => {
            const action = ken.parseListArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.listUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing argument for 'list' flag\n", .{}),
                    error.InvalidNumber => try stderr.print("Error: invalid number in 'list' command\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unknown flag in 'list' command\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'list'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            ken.executeListAction(&database, arena, action, stdout) catch {
                try stderr.print("Error: could not list publications\n", .{});
                try stderr.flush();
                return error.Reported;
            };
            try stdout.flush();
        },
        .show => {
            const action = ken.parseShowArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.showUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing argument. Usage: ken show <id> [--json] | ken show --key <key> [--json]\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unknown or conflicting argument. Usage: ken show <id> [--json] | ken show --key <key> [--json]\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'show'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            ken.executeShowAction(&database, arena, action, stdout, stderr) catch |err| {
                if (err != error.NotFound) {
                    // executeShowAction writes a descriptive "Error: ..."
                    // message to stderr itself for error.NotFound. For other
                    // failures it does not, so add a generic diagnostic here.
                    stderr.print("Error: could not show publication\n", .{}) catch {};
                }
                stderr.flush() catch {};
                // Every failure (missing publication, SQL error, ...) is
                // non-zero: `main` turns this returned error into exit 1.
                return error.Reported;
            };
            try stdout.flush();
        },
        .load => {
            const action = ken.parseLoadArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.loadUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing file path. Usage: ken load <file>\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unexpected argument. Usage: ken load <file>\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'load'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            // Read file
            const max_load_size = 50 * 1024 * 1024; // 50 MB
            const file_content = blk: {
                const file = Io.Dir.openFile(.cwd(), process.io, action.file_path, .{}) catch {
                    try stderr.print("Error: could not open file '{s}'\n", .{action.file_path});
                    try stderr.flush();
                    return error.Reported;
                };
                defer file.close(process.io);
                const stat = file.stat(process.io) catch {
                    try stderr.print("Error: could not stat file '{s}'\n", .{action.file_path});
                    try stderr.flush();
                    return error.Reported;
                };
                const size: usize = @intCast(stat.size);
                if (size == 0) {
                    try stderr.print("Error: file is empty\n", .{});
                    try stderr.flush();
                    return error.Reported;
                }
                if (size > max_load_size) {
                    try stderr.print("Error: file exceeds 50 MB limit\n", .{});
                    try stderr.flush();
                    return error.Reported;
                }
                const buf = arena.alloc(u8, size) catch {
                    try stderr.print("Error: out of memory\n", .{});
                    try stderr.flush();
                    return error.Reported;
                };
                const n = file.readPositionalAll(process.io, buf, 0) catch {
                    try stderr.print("Error: could not read file '{s}'\n", .{action.file_path});
                    try stderr.flush();
                    return error.Reported;
                };
                break :blk buf[0..n];
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            var seed_bytes: [8]u8 = undefined;
            process.io.random(&seed_bytes);
            var prng = std.Random.Pcg.init(@bitCast(seed_bytes));

            ken.executeLoadAction(&database, arena, file_content, prng.random(), stdout, stderr) catch {
                try stderr.flush();
                return error.Reported;
            };
            try stdout.flush();
        },
        .merge => {
            const action = ken.parseMergeArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try stdout.writeAll(ken.mergeUsage);
                    try stdout.flush();
                    return;
                }
                switch (err) {
                    error.MissingArgument => try stderr.print("Error: missing -f/--from <source>. Usage: ken merge -f <source-path> [--check|--nocheck|--force]\n", .{}),
                    error.UnknownFlag => try stderr.print("Error: unknown or conflicting flag. Usage: ken merge -f <source-path> [--check|--nocheck|--force]\n", .{}),
                    else => try stderr.print("Error: invalid arguments for 'merge'\n", .{}),
                }
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            ken.executeMergeAction(&database, arena, action, stdout, stderr) catch |err| {
                if (err == error.KindConflict) {
                    try stderr.print("Error: merge aborted due to kind conflicts (use --force to override)\n", .{});
                }
                try stderr.flush();
                return error.Reported;
            };
            try stdout.flush();
        },
        inline .pubkind, .relkind => |tag| {
            const entity = comptime std.meta.stringToEnum(ken.KindEntity, @tagName(tag)).?;
            const action = ken.parseKindArgs(args, 1) catch |err| {
                if (err == error.HelpRequested) {
                    try ken.writeKindHelp(entity, args, 1, stdout);
                    try stdout.flush();
                    return;
                }
                try ken.formatKindError(entity, err, stderr);
                try stderr.flush();
                return error.Reported;
            };

            const db_path = try resolveDbPath(explicit_db_path, arena, stderr);
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return error.Reported;
            };
            defer database.close();

            ken.executeKindAction(&database, arena, entity, action, stdout, stderr) catch {
                // executeKindAction has already written a descriptive
                // "Error: ..." message to stderr. Returning the error makes
                // `main` exit non-zero so that shell idioms like
                // `ken pubkind show X || ken pubkind add X` work as expected
                // (a missing kind must be a failure).
                stderr.flush() catch {};
                return error.Reported;
            };
            try stdout.flush();
        },
        .skill => {
            try stdout.writeAll(ken.skillContent);
            try stdout.flush();
        },
    }
}

fn resolveDbPath(explicit: ?[:0]const u8, alloc: std.mem.Allocator, stderr: anytype) ![:0]const u8 {
    return explicit orelse (ken.defaultDbPath(alloc) catch {
        stderr.print("Error: could not determine default database path\n", .{}) catch {};
        stderr.flush() catch {};
        return error.Reported;
    });
}

fn hasHelpFlag(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (ken.isHelpFlag(arg)) return true;
    }
    return false;
}

fn genUuid(io: std.Io) [36]u8 {
    var rand_bytes: [16]u8 = undefined;
    io.random(&rand_bytes);
    var buf: [36]u8 = undefined;
    ken.uuidV4(&buf, &rand_bytes);
    return buf;
}

// ---------------------------------------------------------------------------
// CLI exit-code tests
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

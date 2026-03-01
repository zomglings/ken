const std = @import("std");
const ken = @import("ken");
const Io = std.Io;

const usage =
    \\Usage: ken [-D <path>] <command> [options]
    \\
    \\Options:
    \\  -D, --db <path>  Path to ken database (default: platform-specific)
    \\
    \\Commands:
    \\  version    Print ken version
    \\  init       Create or upgrade a ken database
    \\  initpath   Print default database path
    \\  dbversion  Print schema version of a ken database
    \\  add        Add a publication
    \\  relate     Create a relationship between publications
    \\  list       List publications
    \\  search     Search publications
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
    search,
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
        .pubkind => try stdout.writeAll(ken.kindUsage(.pubkind)),
        .relkind => try stdout.writeAll(ken.kindUsage(.relkind)),
        .help => try stdout.writeAll(usage),
        inline else => |tag| try stdout.writeAll("Usage: ken " ++ @tagName(tag) ++ " [options]\n\n" ++ @tagName(tag) ++ ": not yet implemented\n"),
    }
}

pub fn main(process: std.process.Init) !void {
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
                    try stderr.print("Error: -D/--db requires a path argument\n", .{});
                    try stderr.flush();
                    return;
                }
                explicit_db_path = raw_args[i];
            } else {
                try filtered.append(arena, raw_args[i]);
            }
        }
    }
    const args = filtered.items;

    if (args.len < 2) {
        try stderr.print(usage, .{});
        try stderr.flush();
        return;
    }

    if (ken.isHelpFlag(args[1])) {
        try stdout.print(usage, .{});
        try stdout.flush();
        return;
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        try stderr.print("Unknown command: {s}\n\n" ++ usage, .{args[1]});
        try stderr.flush();
        return;
    };

    // Help flag check for commands without their own argument parsers.
    // Commands with subcommands (pubkind, relkind) and commands with their
    // own parsers (add) handle -h internally so help is scoped to the
    // specific subcommand being asked about.
    switch (cmd) {
        .pubkind, .relkind, .add => {},
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
                return;
            };
            try stdout.print("{s}\n", .{db_path});
            try stdout.flush();
        },
        .init => {
            const db_path = resolveDbPath(explicit_db_path, arena, stderr) orelse return;
            if (explicit_db_path == null) {
                if (std.fs.path.dirname(db_path)) |dir_path| {
                    Io.Dir.createDirAbsolute(process.io, dir_path, .default_dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => {
                            try stderr.print("Error: could not create directory '{s}'\n", .{dir_path});
                            try stderr.flush();
                            return;
                        },
                    };
                }
            }
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return;
            };
            defer database.close();
            const prev = database.getVersion() catch {
                try stderr.print("Error: could not read version from '{s}'\n", .{db_path});
                try stderr.flush();
                return;
            };
            const v = database.migrate(ken.migrations) catch |err| {
                if (err == error.DatabaseAheadOfMigrations) {
                    try stderr.print("Error: database is ahead of this version of ken\n", .{});
                } else {
                    try stderr.print("Error: migration failed\n", .{});
                }
                try stderr.flush();
                return;
            };
            if (prev != null and prev.? == v) {
                try stdout.print("Database at {s} already at version {d}, nothing to do\n", .{ db_path, v });
            } else {
                try stdout.print("Initialized ken database at {s} (version {d})\n", .{ db_path, v });
            }
            try stdout.flush();
        },
        .dbversion => {
            const db_path = resolveDbPath(explicit_db_path, arena, stderr) orelse return;
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return;
            };
            defer database.close();
            const v = database.getVersion() catch {
                try stderr.print("Error: could not read version from '{s}'\n", .{db_path});
                try stderr.flush();
                return;
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
                return;
            };

            const db_path = resolveDbPath(explicit_db_path, arena, stderr) orelse return;
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return;
            };
            defer database.close();

            // Validate that the kind exists
            const kind_exists = database.exists(
                "SELECT 1 FROM publication_kinds WHERE name = ?1;",
                &.{action.kind},
            ) catch {
                try stderr.print("Error: could not query database\n", .{});
                try stderr.flush();
                return;
            };
            if (!kind_exists) {
                try stderr.print("Error: unknown publication kind '{s}'\n", .{action.kind});
                try stderr.flush();
                return;
            }

            // Generate UUID and insert publication
            const uuid = genUuid(process.io);

            database.execParams(
                "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
                &.{ &uuid, action.key, action.kind, action.title },
            ) catch {
                try stderr.print("Error: could not insert publication\n", .{});
                try stderr.flush();
                return;
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
                            return;
                        };
                    }
                }
            }

            try stdout.print("{s}\n", .{&uuid});
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
                return;
            };

            const db_path = resolveDbPath(explicit_db_path, arena, stderr) orelse return;
            var database = ken.db.Db.open(db_path) catch {
                try stderr.print("Error: could not open database '{s}'\n", .{db_path});
                try stderr.flush();
                return;
            };
            defer database.close();

            ken.executeKindAction(&database, arena, entity, action, stdout, stderr) catch {
                try stderr.flush();
                return;
            };
            try stdout.flush();
        },
        inline else => |tag| {
            try stderr.print("{s}: not yet implemented\n", .{@tagName(tag)});
            try stderr.flush();
        },
    }
}

fn resolveDbPath(explicit: ?[:0]const u8, alloc: std.mem.Allocator, stderr: anytype) ?[:0]const u8 {
    return explicit orelse (ken.defaultDbPath(alloc) catch {
        stderr.print("Error: could not determine default database path\n", .{}) catch {};
        stderr.flush() catch {};
        return null;
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

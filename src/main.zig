const std = @import("std");
const ken = @import("ken");
const Io = std.Io;

const usage =
    \\Usage: ken <command> [options]
    \\
    \\Commands:
    \\  version    Print ken version
    \\  init       Create or upgrade a ken database
    \\  dbversion  Print schema version of a ken database
    \\  add        Add a publication
    \\  note       Add or view notes
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
    dbversion,
    add,
    note,
    relate,
    list,
    search,
    merge,
    skill,
    pubkind,
    relkind,
    help,
};

pub fn main(process: std.process.Init) !void {
    const arena = process.arena.allocator();
    const args = try process.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), process.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), process.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

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

    switch (cmd) {
        .help => {
            try stdout.print(usage, .{});
            try stdout.flush();
        },
        .version => {
            try stdout.print("{d}\n", .{ken.version});
            try stdout.flush();
        },
        .init => {
            const db_path = resolveDbPath(args, arena) catch {
                try stderr.print("Error: could not determine default database path\n", .{});
                try stderr.flush();
                return;
            };
            if (args.len < 3) {
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
            const v = database.migrate(ken.migrations) catch |err| {
                if (err == error.DatabaseAheadOfMigrations) {
                    try stderr.print("Error: database is ahead of this version of ken\n", .{});
                } else {
                    try stderr.print("Error: migration failed\n", .{});
                }
                try stderr.flush();
                return;
            };
            try stdout.print("Initialized ken database at {s} (version {d})\n", .{ db_path, v });
            try stdout.flush();
        },
        .dbversion => {
            const db_path = resolveDbPath(args, arena) catch {
                try stderr.print("Error: could not determine default database path\n", .{});
                try stderr.flush();
                return;
            };
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
        .pubkind => try handleKind(.pubkind, args, stdout, stderr),
        .relkind => try handleKind(.relkind, args, stdout, stderr),
        inline else => |tag| {
            try stderr.print("{s}: not yet implemented\n", .{@tagName(tag)});
            try stderr.flush();
        },
    }
}

fn resolveDbPath(args: []const [:0]const u8, allocator: std.mem.Allocator) ![:0]const u8 {
    if (args.len >= 3) return args[2];
    return ken.defaultDbPath(allocator);
}

fn handleKind(
    comptime entity: ken.KindEntity,
    args: []const [:0]const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    const action = ken.parseKindArgs(args, 1) catch |err| {
        if (err == error.HelpRequested) {
            try stdout.print(ken.kindUsage(entity), .{});
            try stdout.flush();
            return;
        }
        try ken.formatKindError(entity, err, stderr);
        try stderr.flush();
        return;
    };
    try ken.executeKindAction(entity, action, stdout);
    try stdout.flush();
}

//! ken: a research literature catalog.

const std = @import("std");
const builtin = @import("builtin");
pub const db = @import("db.zig");
const encodeJsonString = std.json.Stringify.encodeJsonString;

pub const version: u32 = 0;
pub const default_db_name = "ken.db";

/// Returns the default database path, platform-appropriate:
/// - macOS: ~/Library/Application Support/ken/ken.db
/// - Linux: $XDG_DATA_HOME/ken/ken.db or ~/.local/share/ken/ken.db
/// - Windows: %LOCALAPPDATA%\ken\ken.db
/// - Other: ~/.ken/ken.db
/// Caller owns the returned memory.
pub fn defaultDbPath(allocator: std.mem.Allocator) ![:0]u8 {
    const app_dir = switch (builtin.os.tag) {
        .windows => blk: {
            const local = std.mem.span(std.c.getenv("LOCALAPPDATA") orelse return error.HomeDirNotFound);
            break :blk try std.fs.path.join(allocator, &.{ local, "ken" });
        },
        else => blk: {
            const home = std.mem.span(std.c.getenv("HOME") orelse return error.HomeDirNotFound);
            break :blk switch (builtin.os.tag) {
                .macos => try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "ken" }),
                .linux => inner: {
                    if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
                        break :inner try std.fs.path.join(allocator, &.{ std.mem.span(xdg), "ken" });
                    }
                    break :inner try std.fs.path.join(allocator, &.{ home, ".local", "share", "ken" });
                },
                else => try std.fs.path.join(allocator, &.{ home, ".ken" }),
            };
        },
    };
    defer allocator.free(app_dir);
    const joined = try std.fs.path.join(allocator, &.{ app_dir, default_db_name });
    defer allocator.free(joined);
    return try allocator.dupeZ(u8, joined);
}

/// Ken schema migrations. Index = version number.
pub const migrations: []const [*:0]const u8 = &.{
    \\CREATE TABLE publication_kinds (
    \\  name TEXT PRIMARY KEY,
    \\  description TEXT NOT NULL
    \\);
    \\CREATE TABLE relationship_kinds (
    \\  name TEXT PRIMARY KEY,
    \\  description TEXT NOT NULL
    \\);
    \\CREATE TABLE publications (
    \\  id TEXT PRIMARY KEY,
    \\  key TEXT,
    \\  kind TEXT NOT NULL REFERENCES publication_kinds(name) ON DELETE RESTRICT,
    \\  title TEXT,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
    \\CREATE TABLE relationships (
    \\  id TEXT PRIMARY KEY,
    \\  subject TEXT NOT NULL REFERENCES publications(id) ON DELETE RESTRICT,
    \\  object TEXT NOT NULL REFERENCES publications(id) ON DELETE RESTRICT,
    \\  kind TEXT NOT NULL REFERENCES relationship_kinds(name) ON DELETE RESTRICT,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
    \\CREATE TABLE notes (
    \\  id TEXT PRIMARY KEY,
    \\  publication TEXT NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
    \\  body TEXT NOT NULL,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
    \\INSERT INTO publication_kinds (name, description) VALUES ('note', 'A researcher''s own note or annotation. The key field is optional; when provided it is treated as a local file path and the file contents are read into the notes table at creation time. The note body is stored in the notes table, linked to the publication by its id. Notes are the primary way researchers record their own thoughts, questions, and observations alongside the literature they are tracking.');
    \\INSERT INTO publication_kinds (name, description) VALUES ('arxiv', 'A preprint hosted on arXiv (arxiv.org). The key is the arXiv identifier, e.g. "2301.07041" for recent papers or "math.AG/0601185" for older ones. To construct the abstract page URL, use https://arxiv.org/abs/{key}. To get the PDF directly, use https://arxiv.org/pdf/{key}. The arXiv API endpoint for metadata is http://export.arxiv.org/api/query?id_list={key}.');
    \\INSERT INTO publication_kinds (name, description) VALUES ('video', 'A YouTube video. The key is the YouTube video ID, which is the 11-character v parameter from a watch URL. To construct the watch URL, use https://www.youtube.com/watch?v={key}. To construct a thumbnail URL, use https://img.youtube.com/vi/{key}/0.jpg. To construct an embed URL, use https://www.youtube.com/embed/{key}.');
    \\INSERT INTO publication_kinds (name, description) VALUES ('web', 'A web page or online resource. The key is the full URL including the scheme (e.g. https://example.com/page). No transformation is needed to visit the resource; the key itself is the link. This is the most general publication kind and can be used for any online resource that does not fit a more specific kind.');
    ,
};

pub const KindEntity = enum {
    pubkind,
    relkind,

    pub fn label(self: KindEntity) []const u8 {
        return switch (self) {
            .pubkind => "publication kind",
            .relkind => "relationship kind",
        };
    }

    pub fn tableName(self: KindEntity) []const u8 {
        return switch (self) {
            .pubkind => "publication_kinds",
            .relkind => "relationship_kinds",
        };
    }

    pub fn childTableName(self: KindEntity) []const u8 {
        return switch (self) {
            .pubkind => "publications",
            .relkind => "relationships",
        };
    }
};

pub const KindSubcommand = enum {
    show,
    list,
    add,
    remove,
    update,
};

pub const Pagination = struct {
    limit: ?u32 = null,
    offset: ?u32 = null,
};

pub const KindAction = union(KindSubcommand) {
    show: struct { name: []const u8 },
    list: struct { pagination: Pagination, descriptions: bool = false },
    add: struct { name: []const u8, description: []const u8 },
    remove: struct { name: []const u8 },
    update: struct { name: []const u8, new_name: ?[]const u8 = null, new_description: ?[]const u8 = null },
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingArgument,
    InvalidNumber,
    MissingUpdateField,
    UnknownFlag,
    HelpRequested,
};

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn kindUsage(comptime entity: KindEntity) []const u8 {
    const lbl = comptime entity.label();
    return "Usage: ken [-D <path>] " ++ @tagName(entity) ++ " <subcommand> [options]\n" ++
        "\nManage " ++ lbl ++ "s.\n" ++
        "\nOptions:\n" ++
        "  -D, --db <path>  Path to ken database (default: platform-specific)\n" ++
        "\nSubcommands:\n" ++
        "  show <name>                                Show a " ++ lbl ++ "\n" ++
        "  list [--limit N] [--offset N] [--descriptions] List " ++ lbl ++ "s\n" ++
        "  add <name> <description>                   Add a " ++ lbl ++ "\n" ++
        "  remove <name>                              Remove a " ++ lbl ++ "\n" ++
        "  update <name> [--name N] [--description D] Update a " ++ lbl ++ "\n";
}

pub fn kindSubcommandUsage(comptime entity: KindEntity, comptime sub: KindSubcommand) []const u8 {
    const ent = @tagName(entity);
    const lbl = entity.label();
    return switch (sub) {
        .show => "Usage: ken [-D <path>] " ++ ent ++ " show <name>\n\nShow a " ++ lbl ++ " by name. Prints JSON with name and description.\n\nOptions:\n  -D, --db <path>  Path to ken database (default: platform-specific)\n",
        .list => "Usage: ken [-D <path>] " ++ ent ++ " list [--limit N] [--offset N] [--descriptions]\n\nList " ++ lbl ++ "s as a JSON array.\n\nOptions:\n  -D, --db <path>  Path to ken database (default: platform-specific)\n  --limit N        Maximum number of results\n  --offset N       Skip first N results\n  --descriptions   Include descriptions in output\n",
        .add => "Usage: ken [-D <path>] " ++ ent ++ " add <name> <description>\n\nAdd a new " ++ lbl ++ ".\n\nOptions:\n  -D, --db <path>  Path to ken database (default: platform-specific)\n",
        .remove => "Usage: ken [-D <path>] " ++ ent ++ " remove <name>\n\nRemove a " ++ lbl ++ ". Fails if the kind is in use.\n\nOptions:\n  -D, --db <path>  Path to ken database (default: platform-specific)\n",
        .update => "Usage: ken [-D <path>] " ++ ent ++ " update <name> [--name N] [--description D]\n\nUpdate a " ++ lbl ++ ". At least one of --name or --description is required.\n\nOptions:\n  -D, --db <path>  Path to ken database (default: platform-specific)\n",
    };
}

/// Write the appropriate help text for a kind command. Shows subcommand-specific
/// help if args contain a valid subcommand, otherwise shows command-level help.
/// Uses cmd_index to locate the subcommand, keeping position logic co-located
/// with parseKindArgs.
pub fn writeKindHelp(comptime entity: KindEntity, args: []const [:0]const u8, cmd_index: usize, stdout: anytype) !void {
    const sub_index = cmd_index + 1;
    if (args.len > sub_index) {
        if (std.meta.stringToEnum(KindSubcommand, args[sub_index])) |sub| {
            switch (sub) {
                inline else => |s| try stdout.writeAll(comptime kindSubcommandUsage(entity, s)),
            }
            return;
        }
    }
    try stdout.writeAll(kindUsage(entity));
}

/// Parses arguments for a `pubkind` or `relkind` command group.
/// `args` is the full argv slice; `cmd_index` is the index of the entity command
/// (e.g. 1 for "pubkind" in `ken pubkind show book`).
pub fn parseKindArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!KindAction {
    const sub_index = cmd_index + 1;
    if (args.len <= sub_index) return error.MissingSubcommand;

    if (isHelpFlag(args[sub_index])) return error.HelpRequested;

    const sub = std.meta.stringToEnum(KindSubcommand, args[sub_index]) orelse
        return error.UnknownSubcommand;

    const rest = args[sub_index + 1 ..];

    for (rest) |arg| {
        if (isHelpFlag(arg)) return error.HelpRequested;
    }

    switch (sub) {
        .show => {
            if (rest.len < 1) return error.MissingArgument;
            return .{ .show = .{ .name = rest[0] } };
        },
        .list => {
            var pagination = Pagination{};
            var descriptions = false;
            var i: usize = 0;
            while (i < rest.len) : (i += 1) {
                const arg: []const u8 = rest[i];
                if (std.mem.eql(u8, arg, "--limit")) {
                    i += 1;
                    if (i >= rest.len) return error.MissingArgument;
                    pagination.limit = std.fmt.parseInt(u32, rest[i], 10) catch
                        return error.InvalidNumber;
                } else if (std.mem.eql(u8, arg, "--offset")) {
                    i += 1;
                    if (i >= rest.len) return error.MissingArgument;
                    pagination.offset = std.fmt.parseInt(u32, rest[i], 10) catch
                        return error.InvalidNumber;
                } else if (std.mem.eql(u8, arg, "--descriptions")) {
                    descriptions = true;
                } else {
                    return error.UnknownFlag;
                }
            }
            return .{ .list = .{ .pagination = pagination, .descriptions = descriptions } };
        },
        .add => {
            if (rest.len < 2) return error.MissingArgument;
            return .{ .add = .{ .name = rest[0], .description = rest[1] } };
        },
        .remove => {
            if (rest.len < 1) return error.MissingArgument;
            return .{ .remove = .{ .name = rest[0] } };
        },
        .update => {
            if (rest.len < 1) return error.MissingArgument;
            const name = rest[0];
            var new_name: ?[]const u8 = null;
            var new_description: ?[]const u8 = null;
            var i: usize = 1;
            while (i < rest.len) : (i += 1) {
                const arg: []const u8 = rest[i];
                if (std.mem.eql(u8, arg, "--name")) {
                    i += 1;
                    if (i >= rest.len) return error.MissingArgument;
                    new_name = rest[i];
                } else if (std.mem.eql(u8, arg, "--description")) {
                    i += 1;
                    if (i >= rest.len) return error.MissingArgument;
                    new_description = rest[i];
                } else {
                    return error.UnknownFlag;
                }
            }
            if (new_name == null and new_description == null) return error.MissingUpdateField;
            return .{ .update = .{
                .name = name,
                .new_name = new_name,
                .new_description = new_description,
            } };
        },
    }
}

pub const KindError = error{
    NotFound,
    AlreadyExists,
    InUse,
    SqlFailed,
};

/// Execute a pubkind/relkind action against the database.
pub fn executeKindAction(
    database: *db.Db,
    allocator: std.mem.Allocator,
    entity: KindEntity,
    action: KindAction,
    stdout: anytype,
    stderr: anytype,
) KindError!void {
    const table = entity.tableName();
    const lbl = entity.label();

    switch (action) {
        .show => |v| {
            var sql_buf: [256]u8 = undefined;
            const sql = std.fmt.bufPrintZ(
                &sql_buf,
                "SELECT description FROM {s} WHERE name = ?1;",
                .{table},
            ) catch unreachable;
            const desc = database.queryTextParams(allocator, sql, &.{v.name}) catch return error.SqlFailed;
            defer if (desc) |d| allocator.free(d);
            if (desc) |d| {
                stdout.writeAll("{\"name\":") catch return error.SqlFailed;
                encodeJsonString(v.name, .{}, stdout) catch return error.SqlFailed;
                stdout.writeAll(",\"description\":") catch return error.SqlFailed;
                encodeJsonString(d, .{}, stdout) catch return error.SqlFailed;
                stdout.writeAll("}\n") catch return error.SqlFailed;
            } else {
                stderr.print("Error: {s} '{s}' not found\n", .{ lbl, v.name }) catch {};
                return error.NotFound;
            }
        },
        .list => |v| {
            var sql_buf: [256]u8 = undefined;
            const lim: i64 = if (v.pagination.limit) |l| @intCast(l) else -1;
            const off: u32 = v.pagination.offset orelse 0;
            const sql = std.fmt.bufPrintZ(
                &sql_buf,
                "SELECT name, description FROM {s} ORDER BY name LIMIT {d} OFFSET {d};",
                .{ table, lim, off },
            ) catch unreachable;
            const rows = database.queryRows(2, allocator, sql, &.{}) catch return error.SqlFailed;
            defer db.Db.freeRows(2, allocator, rows);
            stdout.writeAll("[") catch return error.SqlFailed;
            for (rows, 0..) |row, idx| {
                if (idx > 0) stdout.writeAll(",") catch return error.SqlFailed;
                stdout.writeAll("{\"name\":") catch return error.SqlFailed;
                encodeJsonString(row[0], .{}, stdout) catch return error.SqlFailed;
                if (v.descriptions) {
                    stdout.writeAll(",\"description\":") catch return error.SqlFailed;
                    encodeJsonString(row[1], .{}, stdout) catch return error.SqlFailed;
                }
                stdout.writeAll("}") catch return error.SqlFailed;
            }
            stdout.writeAll("]\n") catch return error.SqlFailed;
        },
        .add => |v| {
            var sql_buf: [256]u8 = undefined;
            const sql = std.fmt.bufPrintZ(
                &sql_buf,
                "INSERT INTO {s} (name, description) VALUES (?1, ?2);",
                .{table},
            ) catch unreachable;
            database.execParams(sql, &.{ v.name, v.description }) catch |err| {
                if (err == error.ConstraintViolation) {
                    stderr.print("Error: {s} '{s}' already exists\n", .{ lbl, v.name }) catch {};
                    return error.AlreadyExists;
                }
                return error.SqlFailed;
            };
            stdout.writeAll("{\"name\":") catch return error.SqlFailed;
            encodeJsonString(v.name, .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(",\"description\":") catch return error.SqlFailed;
            encodeJsonString(v.description, .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll("}\n") catch return error.SqlFailed;
        },
        .remove => |v| {
            var sql_buf: [256]u8 = undefined;
            const sql = std.fmt.bufPrintZ(
                &sql_buf,
                "DELETE FROM {s} WHERE name = ?1;",
                .{table},
            ) catch unreachable;
            database.execParams(sql, &.{v.name}) catch |err| {
                if (err == error.ConstraintViolation) {
                    stderr.print("Error: {s} '{s}' is in use and cannot be removed\n", .{ lbl, v.name }) catch {};
                    return error.InUse;
                }
                return error.SqlFailed;
            };
            if (database.changes() == 0) {
                stderr.print("Error: {s} '{s}' not found\n", .{ lbl, v.name }) catch {};
                return error.NotFound;
            }
            stdout.writeAll("{\"name\":") catch return error.SqlFailed;
            encodeJsonString(v.name, .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(",\"removed\":true}\n") catch return error.SqlFailed;
        },
        .update => |v| {
            if (v.new_name) |new_name| {
                // Rename requires updating child table references (no ON UPDATE CASCADE).
                database.exec("BEGIN;") catch return error.SqlFailed;
                errdefer database.exec("ROLLBACK;") catch {};

                var child_buf: [256]u8 = undefined;
                const child_sql = std.fmt.bufPrintZ(
                    &child_buf,
                    "UPDATE {s} SET kind = ?1 WHERE kind = ?2;",
                    .{entity.childTableName()},
                ) catch unreachable;
                database.execParams(child_sql, &.{ new_name, v.name }) catch return error.SqlFailed;

                // Update the kind row: always SET name, optionally SET description
                var sql_buf: [256]u8 = undefined;
                const sql = if (v.new_description != null)
                    std.fmt.bufPrintZ(
                        &sql_buf,
                        "UPDATE {s} SET name = ?1, description = ?2 WHERE name = ?3;",
                        .{table},
                    ) catch unreachable
                else
                    std.fmt.bufPrintZ(
                        &sql_buf,
                        "UPDATE {s} SET name = ?1 WHERE name = ?2;",
                        .{table},
                    ) catch unreachable;

                const params: []const ?[]const u8 = if (v.new_description) |new_desc|
                    &.{ new_name, new_desc, v.name }
                else
                    &.{ new_name, v.name };

                database.execParams(sql, params) catch |err| {
                    if (err == error.ConstraintViolation) {
                        stderr.print("Error: {s} '{s}' already exists\n", .{ lbl, new_name }) catch {};
                        return error.AlreadyExists;
                    }
                    return error.SqlFailed;
                };

                database.exec("COMMIT;") catch return error.SqlFailed;
            } else {
                // Description-only update, no rename
                var sql_buf: [256]u8 = undefined;
                const sql = std.fmt.bufPrintZ(
                    &sql_buf,
                    "UPDATE {s} SET description = ?1 WHERE name = ?2;",
                    .{table},
                ) catch unreachable;
                database.execParams(sql, &.{ v.new_description.?, v.name }) catch return error.SqlFailed;
            }
            const final_name = v.new_name orelse v.name;
            stdout.writeAll("{\"name\":") catch return error.SqlFailed;
            encodeJsonString(final_name, .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(",\"updated\":true}\n") catch return error.SqlFailed;
        },
    }
}

pub const addUsage =
    \\Usage: ken [-D <path>] add <kind> [-k/--key <key>] [--title <title>]
    \\
    \\Add a publication to the database.
    \\
    \\Options:
    \\  -D, --db <path>  Path to ken database (default: platform-specific)
    \\
    \\Arguments:
    \\  <kind>           Publication kind (e.g. note, arxiv, video, web)
    \\  -k, --key <key>  Key for the publication (e.g. DOI, URL, file path)
    \\  --title <title>  Title of the publication
    \\
    \\Examples:
    \\  ken add arxiv -k 2301.07041 --title "Some paper"
    \\  ken add note --title "Quick note"
    \\  ken add note -k /path/to/note.md --title "From file"
    \\
;

pub const AddAction = struct {
    kind: []const u8,
    key: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

/// Parse arguments for `ken add <kind> [options]`.
/// `args` is full argv; `cmd_index` is the index of "add".
pub fn parseAddArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!AddAction {
    const kind_index = cmd_index + 1;
    if (args.len <= kind_index) return error.MissingArgument;

    if (isHelpFlag(args[kind_index])) return error.HelpRequested;

    var result = AddAction{ .kind = args[kind_index] };
    const rest = args[kind_index + 1 ..];

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg: []const u8 = rest[i];
        if (isHelpFlag(arg)) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.key = rest[i];
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.title = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }

    return result;
}

/// Generate a UUID v4 string into the provided buffer.
/// `rand_bytes` must be 16 random bytes (caller provides randomness).
pub fn uuidV4(buf: *[36]u8, rand_bytes: *[16]u8) void {
    // Set version (4) and variant (RFC 4122)
    rand_bytes[6] = (rand_bytes[6] & 0x0f) | 0x40;
    rand_bytes[8] = (rand_bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out: usize = 0;
    for (rand_bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[out] = '-';
            out += 1;
        }
        buf[out] = hex[b >> 4];
        buf[out + 1] = hex[b & 0x0f];
        out += 2;
    }
}

pub const listUsage =
    \\Usage: ken [-D <path>] list [--kind <kind>] [--limit N] [--offset N]
    \\
    \\List publications as a JSON array.
    \\
    \\Options:
    \\  -D, --db <path>  Path to ken database (default: platform-specific)
    \\  --kind <kind>    Filter by publication kind
    \\  --limit N        Maximum number of results
    \\  --offset N       Skip first N results
    \\
;

pub const ListAction = struct {
    kind: ?[]const u8 = null,
    pagination: Pagination = .{},
};

/// Parse arguments for `ken list [--kind <kind>] [--limit N] [--offset N]`.
/// `args` is full argv; `cmd_index` is the index of "list".
pub fn parseListArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!ListAction {
    const rest = args[cmd_index + 1 ..];
    var result = ListAction{};

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg: []const u8 = rest[i];
        if (isHelpFlag(arg)) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.kind = rest[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.pagination.limit = std.fmt.parseInt(u32, rest[i], 10) catch
                return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.pagination.offset = std.fmt.parseInt(u32, rest[i], 10) catch
                return error.InvalidNumber;
        } else {
            return error.UnknownFlag;
        }
    }

    return result;
}

pub const ListError = error{
    SqlFailed,
};

/// Execute the list action: query publications, write JSON array to stdout.
pub fn executeListAction(
    database: *db.Db,
    allocator: std.mem.Allocator,
    action: ListAction,
    stdout: anytype,
) ListError!void {
    const lim: i64 = if (action.pagination.limit) |l| @intCast(l) else -1;
    const off: u32 = action.pagination.offset orelse 0;
    const where = if (action.kind != null) " WHERE kind = ?1" else "";

    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(
        &sql_buf,
        "SELECT id, kind, title, key FROM publications{s} ORDER BY created_at DESC LIMIT {d} OFFSET {d};",
        .{ where, lim, off },
    ) catch unreachable;
    const params: []const ?[]const u8 = if (action.kind) |k| &.{k} else &.{};
    const rows = database.queryRows(4, allocator, sql, params) catch return error.SqlFailed;
    defer db.Db.freeRows(4, allocator, rows);
    writePublicationRows(rows, stdout) catch return error.SqlFailed;
}

fn writePublicationRows(rows: [][4][]const u8, stdout: anytype) !void {
    try stdout.writeAll("[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try stdout.writeAll(",");
        try stdout.writeAll("{\"id\":");
        try encodeJsonString(row[0], .{}, stdout);
        try stdout.writeAll(",\"kind\":");
        try encodeJsonString(row[1], .{}, stdout);
        try stdout.writeAll(",\"title\":");
        try encodeJsonString(row[2], .{}, stdout);
        try stdout.writeAll(",\"key\":");
        try encodeJsonString(row[3], .{}, stdout);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]\n");
}

pub const relateUsage =
    \\Usage: ken [-D <path>] relate -s <subject-id> -o <object-id> -r <kind>
    \\
    \\Create a relationship between two publications.
    \\
    \\Options:
    \\  -D, --db <path>       Path to ken database (default: platform-specific)
    \\  -s, --subject <id>    Subject publication UUID
    \\  -o, --object <id>     Object publication UUID
    \\  -r, --relation <kind> Relationship kind name
    \\
;

pub const RelateAction = struct {
    subject: []const u8,
    object: []const u8,
    kind: []const u8,
};

/// Parse arguments for `ken relate -s <id> -o <id> -r <kind>`.
/// `args` is full argv; `cmd_index` is the index of "relate".
pub fn parseRelateArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!RelateAction {
    const rest = args[cmd_index + 1 ..];
    if (rest.len == 0) return error.MissingArgument;

    var subject: ?[]const u8 = null;
    var object: ?[]const u8 = null;
    var kind: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg: []const u8 = rest[i];
        if (isHelpFlag(arg)) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--subject")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            subject = rest[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--object")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            object = rest[i];
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--relation")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            kind = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }

    if (subject == null or object == null or kind == null) return error.MissingArgument;
    return .{ .subject = subject.?, .object = object.?, .kind = kind.? };
}

/// Format a ParseError for display.
pub fn formatKindError(
    entity: KindEntity,
    err: ParseError,
    stderr: anytype,
) !void {
    const lbl = entity.label();
    switch (err) {
        error.MissingSubcommand => try stderr.print("Missing subcommand for '{s}'. Expected: show, list, add, remove, update\n", .{lbl}),
        error.UnknownSubcommand => try stderr.print("Unknown subcommand for '{s}'. Expected: show, list, add, remove, update\n", .{lbl}),
        error.MissingArgument => try stderr.print("Missing required argument for '{s}' command\n", .{lbl}),
        error.InvalidNumber => try stderr.print("Invalid number in '{s}' command\n", .{lbl}),
        error.MissingUpdateField => try stderr.print("Update requires at least one of --name or --description\n", .{}),
        error.UnknownFlag => try stderr.print("Unknown flag in '{s}' command\n", .{lbl}),
        error.HelpRequested => {},
    }
}

// ── Merge ──

pub const mergeUsage =
    \\Usage: ken [-D <path>] merge -f <source-path> [--check] [--nocheck] [--force]
    \\
    \\Merge a source ken database into the target database.
    \\Data flows from source into the target (opened via -D or default path).
    \\The entire merge runs in a single transaction for atomicity.
    \\
    \\Options:
    \\  -D, --db <path>       Path to target ken database (default: platform-specific)
    \\  -f, --from <path>     Path to source ken database (required)
    \\
    \\Flags:
    \\  --check    Only check for kind conflicts, don't merge.
    \\             Exit 0 if clean, exit 1 if conflicts found.
    \\  --nocheck  Skip conflict check, just run the merge (ROLLBACK on failure).
    \\             Kind conflicts resolved in favor of the target.
    \\  --force    Merge even if kind conflicts exist. Target descriptions win.
    \\
    \\If no flag is given, conflicts are checked first. If any are found the
    \\merge is aborted with an error. Otherwise the merge proceeds.
    \\
    \\Conflict resolution:
    \\  Kinds (publication_kinds, relationship_kinds): same name + same description
    \\  is silently skipped. Same name + different description is a conflict.
    \\  UUID-keyed tables (publications, relationships, notes): same id is skipped.
    \\
;

pub const MergeMode = enum {
    default,
    check,
    nocheck,
    force,
};

pub const MergeAction = struct {
    source_path: []const u8,
    mode: MergeMode = .default,
};

pub const MergeError = error{
    SqlFailed,
    InvalidSource,
    KindConflict,
};

const MergeCounts = struct {
    publication_kinds: i32 = 0,
    relationship_kinds: i32 = 0,
    publications: i32 = 0,
    relationships: i32 = 0,
    notes: i32 = 0,
};

/// Parse arguments for `ken merge -f <source-path> [--check|--nocheck|--force]`.
/// `args` is full argv; `cmd_index` is the index of "merge".
pub fn parseMergeArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!MergeAction {
    const rest = args[cmd_index + 1 ..];
    if (rest.len == 0) return error.MissingArgument;

    var result = MergeAction{ .source_path = undefined };
    var have_source = false;
    var mode_count: u32 = 0;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a: []const u8 = rest[i];
        if (isHelpFlag(a)) return error.HelpRequested;
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            result.source_path = rest[i];
            have_source = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            result.mode = .check;
            mode_count += 1;
        } else if (std.mem.eql(u8, a, "--nocheck")) {
            result.mode = .nocheck;
            mode_count += 1;
        } else if (std.mem.eql(u8, a, "--force")) {
            result.mode = .force;
            mode_count += 1;
        } else {
            return error.UnknownFlag;
        }
    }

    if (!have_source) return error.MissingArgument;
    if (mode_count > 1) return error.UnknownFlag;

    return result;
}

/// Execute a merge action: import data from source into the target database.
pub fn executeMergeAction(
    database: *db.Db,
    allocator: std.mem.Allocator,
    action: MergeAction,
    stdout: anytype,
    stderr: anytype,
) MergeError!void {
    // ATTACH source database
    database.execParams(
        "ATTACH DATABASE ?1 AS src;",
        &.{action.source_path},
    ) catch {
        stderr.print("Error: could not attach source database '{s}'\n", .{action.source_path}) catch {};
        return error.SqlFailed;
    };
    defer database.exec("DETACH DATABASE src;") catch {};

    // Validate source has _ken_meta table
    const has_meta = database.exists(
        "SELECT 1 FROM src.sqlite_master WHERE type='table' AND name='_ken_meta';",
        &.{},
    ) catch {
        stderr.print("Error: could not read source database\n", .{}) catch {};
        return error.SqlFailed;
    };
    if (!has_meta) {
        stderr.print("Error: source is not a ken database\n", .{}) catch {};
        return error.InvalidSource;
    }

    // BEGIN IMMEDIATE so the conflict check and merge see a consistent snapshot.
    database.exec("BEGIN IMMEDIATE;") catch {
        stderr.print("Error: could not begin transaction\n", .{}) catch {};
        return error.SqlFailed;
    };
    errdefer database.exec("ROLLBACK;") catch {};

    // Conflict detection (unless --nocheck)
    if (action.mode != .nocheck) {
        const pub_conflicts = database.queryRows(
            2,
            allocator,
            \\SELECT s.name, s.description FROM src.publication_kinds s
            \\INNER JOIN main.publication_kinds m ON s.name = m.name
            \\WHERE s.description != m.description;
        ,
            &.{},
        ) catch {
            stderr.print("Error: conflict detection query failed\n", .{}) catch {};
            return error.SqlFailed;
        };
        defer db.Db.freeRows(2, allocator, pub_conflicts);

        const rel_conflicts = database.queryRows(
            2,
            allocator,
            \\SELECT s.name, s.description FROM src.relationship_kinds s
            \\INNER JOIN main.relationship_kinds m ON s.name = m.name
            \\WHERE s.description != m.description;
        ,
            &.{},
        ) catch {
            stderr.print("Error: conflict detection query failed\n", .{}) catch {};
            return error.SqlFailed;
        };
        defer db.Db.freeRows(2, allocator, rel_conflicts);

        const total_conflicts = pub_conflicts.len + rel_conflicts.len;

        // Report conflicts (once, with mode-appropriate prefix)
        if (total_conflicts > 0) {
            const prefix: []const u8 = if (action.mode == .force) "Warning" else "Error";
            const suffix: []const u8 = if (action.mode == .force)
                "(keeping target description)"
            else
                "(descriptions differ between source and target)";
            for (pub_conflicts) |row| {
                stderr.print("{s}: conflicting publication kind '{s}' {s}\n", .{ prefix, row[0], suffix }) catch {};
            }
            for (rel_conflicts) |row| {
                stderr.print("{s}: conflicting relationship kind '{s}' {s}\n", .{ prefix, row[0], suffix }) catch {};
            }
        }

        // Act on conflicts per mode
        if (action.mode == .check) {
            database.exec("ROLLBACK;") catch {};
            if (total_conflicts > 0) {
                stdout.print("{{\"conflicts\":{d}}}\n", .{total_conflicts}) catch return error.SqlFailed;
                return error.KindConflict;
            }
            stdout.print("{{\"conflicts\":0}}\n", .{}) catch return error.SqlFailed;
            return;
        }
        if (action.mode == .default and total_conflicts > 0) {
            return error.KindConflict;
        }
        // .force: fall through to merge
    }

    // Insert tables in FK-safe order
    var counts = MergeCounts{};

    database.exec(
        "INSERT OR IGNORE INTO main.publication_kinds (name, description) SELECT name, description FROM src.publication_kinds;",
    ) catch {
        stderr.print("Error: failed to merge publication kinds\n", .{}) catch {};
        return error.SqlFailed;
    };
    counts.publication_kinds = database.changes();

    database.exec(
        "INSERT OR IGNORE INTO main.relationship_kinds (name, description) SELECT name, description FROM src.relationship_kinds;",
    ) catch {
        stderr.print("Error: failed to merge relationship kinds\n", .{}) catch {};
        return error.SqlFailed;
    };
    counts.relationship_kinds = database.changes();

    database.exec(
        "INSERT OR IGNORE INTO main.publications (id, key, kind, title, created_at, updated_at) SELECT id, key, kind, title, created_at, updated_at FROM src.publications;",
    ) catch {
        stderr.print("Error: failed to merge publications\n", .{}) catch {};
        return error.SqlFailed;
    };
    counts.publications = database.changes();

    database.exec(
        "INSERT OR IGNORE INTO main.relationships (id, subject, object, kind, created_at) SELECT id, subject, object, kind, created_at FROM src.relationships;",
    ) catch {
        stderr.print("Error: failed to merge relationships\n", .{}) catch {};
        return error.SqlFailed;
    };
    counts.relationships = database.changes();

    database.exec(
        "INSERT OR IGNORE INTO main.notes (id, publication, body, created_at, updated_at) SELECT id, publication, body, created_at, updated_at FROM src.notes;",
    ) catch {
        stderr.print("Error: failed to merge notes\n", .{}) catch {};
        return error.SqlFailed;
    };
    counts.notes = database.changes();

    database.exec("COMMIT;") catch {
        stderr.print("Error: could not commit transaction\n", .{}) catch {};
        return error.SqlFailed;
    };

    stdout.print("{{\"publication_kinds\":{d},\"relationship_kinds\":{d},\"publications\":{d},\"relationships\":{d},\"notes\":{d}}}\n", .{
        counts.publication_kinds,
        counts.relationship_kinds,
        counts.publications,
        counts.relationships,
        counts.notes,
    }) catch return error.SqlFailed;
}

// ── Tests ──

const testing = std.testing;

fn mkArgs(comptime strs: []const []const u8) [strs.len][:0]const u8 {
    var result: [strs.len][:0]const u8 = undefined;
    for (strs, 0..) |s, i| {
        result[i] = @ptrCast(s);
    }
    return result;
}

test "show: with name" {
    const args = mkArgs(&.{ "ken", "pubkind", "show", "book" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqualStrings("book", action.show.name);
}

test "show: missing name" {
    const args = mkArgs(&.{ "ken", "pubkind", "show" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "list: no flags" {
    const args = mkArgs(&.{ "ken", "pubkind", "list" });
    const action = try parseKindArgs(&args, 1);
    try testing.expect(action.list.pagination.limit == null);
    try testing.expect(action.list.pagination.offset == null);
}

test "list: with --limit and --offset" {
    const args = mkArgs(&.{ "ken", "pubkind", "list", "--limit", "10", "--offset", "5" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqual(@as(u32, 10), action.list.pagination.limit.?);
    try testing.expectEqual(@as(u32, 5), action.list.pagination.offset.?);
}

test "list: invalid number" {
    const args = mkArgs(&.{ "ken", "pubkind", "list", "--limit", "abc" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.InvalidNumber, result);
}

test "add: with name and description" {
    const args = mkArgs(&.{ "ken", "pubkind", "add", "book", "Keyed by ISBN" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqualStrings("book", action.add.name);
    try testing.expectEqualStrings("Keyed by ISBN", action.add.description);
}

test "add: missing description" {
    const args = mkArgs(&.{ "ken", "pubkind", "add", "book" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "remove: with name" {
    const args = mkArgs(&.{ "ken", "relkind", "remove", "cites" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqualStrings("cites", action.remove.name);
}

test "remove: missing name" {
    const args = mkArgs(&.{ "ken", "relkind", "remove" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "update: with both flags" {
    const args = mkArgs(&.{ "ken", "pubkind", "update", "book", "--name", "tome", "--description", "New desc" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqualStrings("book", action.update.name);
    try testing.expectEqualStrings("tome", action.update.new_name.?);
    try testing.expectEqualStrings("New desc", action.update.new_description.?);
}

test "update: with --description only" {
    const args = mkArgs(&.{ "ken", "pubkind", "update", "book", "--description", "New desc" });
    const action = try parseKindArgs(&args, 1);
    try testing.expectEqualStrings("book", action.update.name);
    try testing.expect(action.update.new_name == null);
    try testing.expectEqualStrings("New desc", action.update.new_description.?);
}

test "update: no flags (error)" {
    const args = mkArgs(&.{ "ken", "pubkind", "update", "book" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.MissingUpdateField, result);
}

test "missing subcommand" {
    const args = mkArgs(&.{ "ken", "pubkind" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.MissingSubcommand, result);
}

test "unknown subcommand" {
    const args = mkArgs(&.{ "ken", "pubkind", "destroy" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.UnknownSubcommand, result);
}

test "help: --help at subcommand position" {
    const args = mkArgs(&.{ "ken", "pubkind", "--help" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "help: -h at subcommand position" {
    const args = mkArgs(&.{ "ken", "pubkind", "-h" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "help: --help within subcommand args" {
    const args = mkArgs(&.{ "ken", "pubkind", "show", "--help" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "help: -h within list args" {
    const args = mkArgs(&.{ "ken", "pubkind", "list", "-h" });
    const result = parseKindArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

// ── parseAddArgs tests ──

test "add: kind only" {
    const args = mkArgs(&.{ "ken", "add", "note" });
    const action = try parseAddArgs(&args, 1);
    try testing.expectEqualStrings("note", action.kind);
    try testing.expect(action.key == null);
    try testing.expect(action.title == null);
}

test "add: kind with key and title" {
    const args = mkArgs(&.{ "ken", "add", "arxiv", "-k", "2301.07041", "--title", "Some paper" });
    const action = try parseAddArgs(&args, 1);
    try testing.expectEqualStrings("arxiv", action.kind);
    try testing.expectEqualStrings("2301.07041", action.key.?);
    try testing.expectEqualStrings("Some paper", action.title.?);
}

test "add: --key long form" {
    const args = mkArgs(&.{ "ken", "add", "web", "--key", "https://example.com", "--title", "Example" });
    const action = try parseAddArgs(&args, 1);
    try testing.expectEqualStrings("web", action.kind);
    try testing.expectEqualStrings("https://example.com", action.key.?);
    try testing.expectEqualStrings("Example", action.title.?);
}

test "add: missing kind" {
    const args = mkArgs(&.{ "ken", "add" });
    const result = parseAddArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "add: help at kind position" {
    const args = mkArgs(&.{ "ken", "add", "--help" });
    const result = parseAddArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "add: help within flags" {
    const args = mkArgs(&.{ "ken", "add", "note", "-h" });
    const result = parseAddArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "add: unknown flag" {
    const args = mkArgs(&.{ "ken", "add", "note", "--bogus" });
    const result = parseAddArgs(&args, 1);
    try testing.expectError(error.UnknownFlag, result);
}

test "add: missing key value" {
    const args = mkArgs(&.{ "ken", "add", "note", "-k" });
    const result = parseAddArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

// ── uuidV4 tests ──

test "uuidV4: correct format" {
    var buf: [36]u8 = undefined;
    var rand_bytes = [16]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    uuidV4(&buf, &rand_bytes);

    // Check hyphens at correct positions
    try testing.expectEqual(@as(u8, '-'), buf[8]);
    try testing.expectEqual(@as(u8, '-'), buf[13]);
    try testing.expectEqual(@as(u8, '-'), buf[18]);
    try testing.expectEqual(@as(u8, '-'), buf[23]);

    // Check version nibble (position 14 = first hex char of byte 6)
    try testing.expectEqual(@as(u8, '4'), buf[14]);

    // Check variant nibble (position 19 = first hex char of byte 8)
    try testing.expect(buf[19] == '8' or buf[19] == '9' or buf[19] == 'a' or buf[19] == 'b');
}

test "uuidV4: different input produces different output" {
    var buf1: [36]u8 = undefined;
    var buf2: [36]u8 = undefined;
    var rand1 = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
    var rand2 = [16]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00 };
    uuidV4(&buf1, &rand1);
    uuidV4(&buf2, &rand2);
    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

// ── executeKindAction tests ──

fn testDb() !db.Db {
    var database = try db.Db.open(":memory:");
    _ = try database.migrate(migrations);
    return database;
}

test "executeKindAction: add and show" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "Keyed by ISBN" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"book\",\"description\":\"Keyed by ISBN\"}\n", out.buffered());

    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "book" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"book\",\"description\":\"Keyed by ISBN\"}\n", out.buffered());
}

test "executeKindAction: show not found" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "nonexistent" } }, &out, &err_w);
    try testing.expectError(error.NotFound, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "not found") != null);
}

test "executeKindAction: list with seeded kinds" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .list = .{ .pagination = .{} } }, &out, &err_w);
    const output = out.buffered();
    // Should contain seeded kinds (arxiv, note, video, web) sorted alphabetically
    try testing.expect(std.mem.indexOf(u8, output, "\"name\":\"arxiv\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"name\":\"note\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"name\":\"video\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"name\":\"web\"") != null);
    // Default list should not include descriptions
    try testing.expect(std.mem.indexOf(u8, output, "\"description\"") == null);
}

test "executeKindAction: list with pagination" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    // Limit 2 → first two alphabetically (arxiv, note)
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .list = .{ .pagination = .{ .limit = 2 } } }, &out, &err_w);
    const output1 = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output1, "\"name\":\"arxiv\"") != null);
    try testing.expect(std.mem.indexOf(u8, output1, "\"name\":\"note\"") != null);
    try testing.expect(std.mem.indexOf(u8, output1, "\"name\":\"video\"") == null);

    // Limit 2, offset 2 → next two (video, web)
    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .list = .{ .pagination = .{ .limit = 2, .offset = 2 } } }, &out, &err_w);
    const output2 = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output2, "\"name\":\"video\"") != null);
    try testing.expect(std.mem.indexOf(u8, output2, "\"name\":\"web\"") != null);
}

test "executeKindAction: duplicate add error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "Keyed by ISBN" } }, &out, &err_w);

    out.end = 0;
    const result = executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "duplicate" } }, &out, &err_w);
    try testing.expectError(error.AlreadyExists, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "already exists") != null);
}

test "executeKindAction: remove" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "Keyed by ISBN" } }, &out, &err_w);
    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .remove = .{ .name = "book" } }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"removed\":true") != null);

    // Verify it's gone
    out.end = 0;
    const result = executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "book" } }, &out, &err_w);
    try testing.expectError(error.NotFound, result);
}

test "executeKindAction: remove nonexistent" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeKindAction(&database, testing.allocator, .pubkind, .{ .remove = .{ .name = "nonexistent" } }, &out, &err_w);
    try testing.expectError(error.NotFound, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "not found") != null);
}

test "executeKindAction: update description" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "Keyed by ISBN" } }, &out, &err_w);

    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .update = .{ .name = "book", .new_description = "Keyed by ISBN-13" } }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"updated\":true") != null);

    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "book" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"book\",\"description\":\"Keyed by ISBN-13\"}\n", out.buffered());
}

test "executeKindAction: update with rename" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .add = .{ .name = "book", .description = "Keyed by ISBN" } }, &out, &err_w);

    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .update = .{ .name = "book", .new_name = "tome" } }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"updated\":true") != null);

    // Old name should not be found
    out.end = 0;
    const result = executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "book" } }, &out, &err_w);
    try testing.expectError(error.NotFound, result);

    // New name should work
    out.end = 0;
    err_w.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .show = .{ .name = "tome" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"tome\",\"description\":\"Keyed by ISBN\"}\n", out.buffered());
}

test "executeKindAction: relkind add and list" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .relkind, .{ .add = .{ .name = "cites", .description = "Subject cites object" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"cites\",\"description\":\"Subject cites object\"}\n", out.buffered());

    out.end = 0;
    try executeKindAction(&database, testing.allocator, .relkind, .{ .list = .{ .pagination = .{} } }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"name\":\"cites\"") != null);
}

test "list: --descriptions flag" {
    const args = mkArgs(&.{ "ken", "pubkind", "list", "--descriptions" });
    const action = try parseKindArgs(&args, 1);
    try testing.expect(action.list.descriptions == true);
    try testing.expect(action.list.pagination.limit == null);
}

test "list: --descriptions with --limit" {
    const args = mkArgs(&.{ "ken", "pubkind", "list", "--descriptions", "--limit", "5" });
    const action = try parseKindArgs(&args, 1);
    try testing.expect(action.list.descriptions == true);
    try testing.expectEqual(@as(u32, 5), action.list.pagination.limit.?);
}

test "executeKindAction: list with --descriptions" {
    var database = try testDb();
    defer database.close();

    var out_buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeKindAction(&database, testing.allocator, .pubkind, .{ .list = .{ .pagination = .{}, .descriptions = true } }, &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"description\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"name\":\"arxiv\"") != null);
}

// ── parseMergeArgs tests ──

test "merge: -f source path" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db" });
    const action = try parseMergeArgs(&args, 1);
    try testing.expectEqualStrings("source.db", action.source_path);
    try testing.expect(action.mode == .default);
}

test "merge: --from source path" {
    const args = mkArgs(&.{ "ken", "merge", "--from", "source.db" });
    const action = try parseMergeArgs(&args, 1);
    try testing.expectEqualStrings("source.db", action.source_path);
    try testing.expect(action.mode == .default);
}

test "merge: --check flag" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db", "--check" });
    const action = try parseMergeArgs(&args, 1);
    try testing.expectEqualStrings("source.db", action.source_path);
    try testing.expect(action.mode == .check);
}

test "merge: --nocheck flag" {
    const args = mkArgs(&.{ "ken", "merge", "--nocheck", "-f", "source.db" });
    const action = try parseMergeArgs(&args, 1);
    try testing.expectEqualStrings("source.db", action.source_path);
    try testing.expect(action.mode == .nocheck);
}

test "merge: --force flag" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db", "--force" });
    const action = try parseMergeArgs(&args, 1);
    try testing.expectEqualStrings("source.db", action.source_path);
    try testing.expect(action.mode == .force);
}

test "merge: missing -f flag" {
    const args = mkArgs(&.{ "ken", "merge" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "merge: -f without value" {
    const args = mkArgs(&.{ "ken", "merge", "-f" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "merge: help flag" {
    const args = mkArgs(&.{ "ken", "merge", "-h" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "merge: help flag with source" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db", "--help" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "merge: unknown flag" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db", "--bogus" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.UnknownFlag, result);
}

test "merge: multiple mode flags rejected" {
    const args = mkArgs(&.{ "ken", "merge", "-f", "source.db", "--check", "--force" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.UnknownFlag, result);
}

test "merge: mode flag without source" {
    const args = mkArgs(&.{ "ken", "merge", "--check" });
    const result = parseMergeArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

// ── executeMergeAction tests ──

/// Create a temporary file-based ken database for merge tests.
/// Returns the path (caller must clean up) and the open Db.
fn testFileDb(comptime path: [*:0]const u8) !db.Db {
    var database = try db.Db.open(path);
    _ = try database.migrate(migrations);
    return database;
}

fn deleteTmpDb(comptime path: [*:0]const u8) void {
    _ = std.c.unlink(path);
}

test "executeMergeAction: basic merge imports publications" {
    defer deleteTmpDb("_test_merge_target.db");
    defer deleteTmpDb("_test_merge_source.db");

    // Set up source with a publication
    {
        var src = try testFileDb("_test_merge_source.db");
        defer src.close();
        try src.execParams(
            "INSERT INTO publications (id, kind, title) VALUES (?1, ?2, ?3);",
            &.{ "aaaa-bbbb-cccc-dddd", "arxiv", "Paper A" },
        );
    }

    // Set up target (empty)
    var target = try testFileDb("_test_merge_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_source.db" }, &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":1") != null);
}

test "executeMergeAction: idempotent merge (second merge inserts 0)" {
    defer deleteTmpDb("_test_merge_idem_target.db");
    defer deleteTmpDb("_test_merge_idem_source.db");

    {
        var src = try testFileDb("_test_merge_idem_source.db");
        defer src.close();
        try src.execParams(
            "INSERT INTO publications (id, kind, title) VALUES (?1, ?2, ?3);",
            &.{ "1111-2222-3333-4444", "arxiv", "Paper B" },
        );
    }

    var target = try testFileDb("_test_merge_idem_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    // First merge
    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_idem_source.db" }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"publications\":1") != null);

    // Second merge — should insert 0
    out.end = 0;
    err_w.end = 0;
    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_idem_source.db" }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"publications\":0") != null);
}

test "executeMergeAction: --check with no conflicts" {
    defer deleteTmpDb("_test_merge_chk_target.db");
    defer deleteTmpDb("_test_merge_chk_source.db");

    {
        var src = try testFileDb("_test_merge_chk_source.db");
        defer src.close();
    }

    var target = try testFileDb("_test_merge_chk_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_chk_source.db", .mode = .check }, &out, &err_w);
    try testing.expectEqualStrings("{\"conflicts\":0}\n", out.buffered());
}

test "executeMergeAction: --check with conflicts" {
    defer deleteTmpDb("_test_merge_chkc_target.db");
    defer deleteTmpDb("_test_merge_chkc_source.db");

    {
        var src = try testFileDb("_test_merge_chkc_source.db");
        defer src.close();
        // Change the description of 'arxiv' in source
        try src.execParams(
            "UPDATE publication_kinds SET description = ?1 WHERE name = ?2;",
            &.{ "Different description", "arxiv" },
        );
    }

    var target = try testFileDb("_test_merge_chkc_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_chkc_source.db", .mode = .check }, &out, &err_w);
    try testing.expectError(error.KindConflict, result);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"conflicts\":1") != null);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "conflicting publication kind 'arxiv'") != null);
}

test "executeMergeAction: default mode aborts on conflict" {
    defer deleteTmpDb("_test_merge_def_target.db");
    defer deleteTmpDb("_test_merge_def_source.db");

    {
        var src = try testFileDb("_test_merge_def_source.db");
        defer src.close();
        try src.execParams(
            "UPDATE publication_kinds SET description = ?1 WHERE name = ?2;",
            &.{ "Conflicting desc", "note" },
        );
    }

    var target = try testFileDb("_test_merge_def_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_def_source.db" }, &out, &err_w);
    try testing.expectError(error.KindConflict, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "conflicting publication kind 'note'") != null);
}

test "executeMergeAction: --force merges despite conflicts" {
    defer deleteTmpDb("_test_merge_force_target.db");
    defer deleteTmpDb("_test_merge_force_source.db");

    {
        var src = try testFileDb("_test_merge_force_source.db");
        defer src.close();
        try src.execParams(
            "UPDATE publication_kinds SET description = ?1 WHERE name = ?2;",
            &.{ "Conflicting desc", "note" },
        );
        try src.execParams(
            "INSERT INTO publications (id, kind, title) VALUES (?1, ?2, ?3);",
            &.{ "force-uuid-1234", "note", "Force note" },
        );
    }

    var target = try testFileDb("_test_merge_force_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_force_source.db", .mode = .force }, &out, &err_w);
    // Should succeed and import the publication
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"publications\":1") != null);
    // Should print warning
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "Warning:") != null);
}

test "executeMergeAction: --nocheck skips conflict detection" {
    defer deleteTmpDb("_test_merge_nochk_target.db");
    defer deleteTmpDb("_test_merge_nochk_source.db");

    {
        var src = try testFileDb("_test_merge_nochk_source.db");
        defer src.close();
        try src.execParams(
            "UPDATE publication_kinds SET description = ?1 WHERE name = ?2;",
            &.{ "Different desc", "video" },
        );
        try src.execParams(
            "INSERT INTO publications (id, kind, title) VALUES (?1, ?2, ?3);",
            &.{ "nochk-uuid-5678", "video", "Some video" },
        );
    }

    var target = try testFileDb("_test_merge_nochk_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_nochk_source.db", .mode = .nocheck }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"publications\":1") != null);
    // No warnings should be printed (no conflict check)
    try testing.expectEqualStrings("", err_w.buffered());
}

test "executeMergeAction: invalid source (not a ken db)" {
    defer deleteTmpDb("_test_merge_inv_target.db");
    defer deleteTmpDb("_test_merge_inv_source.db");

    // Create a plain SQLite database (no _ken_meta)
    {
        var src = try db.Db.open("_test_merge_inv_source.db");
        defer src.close();
        try src.exec("CREATE TABLE foo (id INTEGER);");
    }

    var target = try testFileDb("_test_merge_inv_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_inv_source.db" }, &out, &err_w);
    try testing.expectError(error.InvalidSource, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "source is not a ken database") != null);
}

test "executeMergeAction: merges new publication kind from source" {
    defer deleteTmpDb("_test_merge_newkind_target.db");
    defer deleteTmpDb("_test_merge_newkind_source.db");

    {
        var src = try testFileDb("_test_merge_newkind_source.db");
        defer src.close();
        try src.execParams(
            "INSERT INTO publication_kinds (name, description) VALUES (?1, ?2);",
            &.{ "book", "Keyed by ISBN" },
        );
    }

    var target = try testFileDb("_test_merge_newkind_target.db");
    defer target.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try executeMergeAction(&target, testing.allocator, .{ .source_path = "_test_merge_newkind_source.db" }, &out, &err_w);
    // Should have imported the new kind
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"publication_kinds\":1") != null);

    // Verify the kind exists in target
    const exists = try target.exists("SELECT 1 FROM publication_kinds WHERE name = ?1;", &.{"book"});
    try testing.expect(exists);
}

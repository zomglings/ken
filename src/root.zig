//! ken: a research literature catalog.

const std = @import("std");
const builtin = @import("builtin");
pub const db = @import("db.zig");
const encodeJsonString = std.json.Stringify.encodeJsonString;

pub const version: u32 = 3;
pub const default_db_name = "ken.db";

/// Human-readable default database path for help text, resolved at comptime.
pub const default_db_path_hint: []const u8 = switch (builtin.os.tag) {
    .macos => "~/Library/Application Support/ken/" ++ default_db_name,
    .linux => "~/.local/share/ken/" ++ default_db_name,
    .windows => "%LOCALAPPDATA%\\ken\\" ++ default_db_name,
    else => "~/.ken/" ++ default_db_name,
};

pub const db_flag_help = "  -D, --db <path>  Path to ken database (default: " ++ default_db_path_hint ++ ")\n";

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
    \\INSERT INTO publication_kinds (name, description) VALUES ('topic', 'A research topic or area of study. Used as a conceptual node for organizing literature. The key field is optional; when provided it should be a short canonical identifier such as a Wikipedia URL or taxonomy code. The title should be the human-readable topic name (e.g. "Reinforcement Learning", "Category Theory").');
    \\INSERT INTO relationship_kinds (name, description) VALUES ('cites', 'Subject cites object as a reference or source.');
    \\INSERT INTO relationship_kinds (name, description) VALUES ('derives-from', 'Subject is derived from or builds upon object.');
    ,
    // Version 1: no schema changes (ken load uses existing tables).
    "SELECT 1;",
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
        db_flag_help ++
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
        .show => "Usage: ken [-D <path>] " ++ ent ++ " show <name>\n\nShow a " ++ lbl ++ " by name. Prints JSON with name and description.\n\nOptions:\n" ++ db_flag_help,
        .list => "Usage: ken [-D <path>] " ++ ent ++ " list [--limit N] [--offset N] [--descriptions]\n\nList " ++ lbl ++ "s as a JSON array.\n\nOptions:\n" ++ db_flag_help ++ "  --limit N        Maximum number of results\n  --offset N       Skip first N results\n  --descriptions   Include descriptions in output\n",
        .add => "Usage: ken [-D <path>] " ++ ent ++ " add <name> <description>\n\nAdd a new " ++ lbl ++ ".\n\nOptions:\n" ++ db_flag_help,
        .remove => "Usage: ken [-D <path>] " ++ ent ++ " remove <name>\n\nRemove a " ++ lbl ++ ". Fails if the kind is in use.\n\nOptions:\n" ++ db_flag_help,
        .update => "Usage: ken [-D <path>] " ++ ent ++ " update <name> [--name N] [--description D]\n\nUpdate a " ++ lbl ++ ". At least one of --name or --description is required.\n\nOptions:\n" ++ db_flag_help,
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
    \\
++ db_flag_help ++
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
    \\
++ db_flag_help ++
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

// ── Show ──

pub const showUsage =
    \\Usage: ken [-D <path>] show <id> [--json]
    \\       ken [-D <path>] show --key <key> [--json]
    \\
    \\Print a publication's full record, its note body (if any), and its
    \\relationships. Look it up by UUID (positional) or by key (--key).
    \\
    \\Options:
    \\
++ db_flag_help ++
    \\  --key <key>      Look up the publication by its key instead of id
    \\  --json           Emit a single machine-readable JSON object
    \\
    \\Without --json, output is a human-readable record. With --json, output
    \\is one JSON object with id, kind, key, title, body, and relationships.
    \\
    \\Examples:
    \\  ken show 1f2e3d4c-5b6a-7980-1234-567890abcdef
    \\  ken show --key 2301.07041
    \\  ken show --key 2301.07041 --json
    \\
;

pub const ShowAction = struct {
    /// Exactly one of `id` or `key` is set after parsing.
    id: ?[]const u8 = null,
    key: ?[]const u8 = null,
    json: bool = false,
};

/// Parse arguments for `ken show <id> [--json]` or
/// `ken show --key <key> [--json]`.
/// `args` is full argv; `cmd_index` is the index of "show".
pub fn parseShowArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!ShowAction {
    const rest = args[cmd_index + 1 ..];
    if (rest.len == 0) return error.MissingArgument;

    var result = ShowAction{};

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg: []const u8 = rest[i];
        if (isHelpFlag(arg)) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= rest.len) return error.MissingArgument;
            if (result.key != null or result.id != null) return error.UnknownFlag;
            result.key = rest[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownFlag;
        } else {
            // Positional argument: the publication id.
            if (result.id != null or result.key != null) return error.UnknownFlag;
            result.id = arg;
        }
    }

    if (result.id == null and result.key == null) return error.MissingArgument;
    return result;
}

pub const ShowError = error{
    NotFound,
    SqlFailed,
};

/// Execute the show action: look up a publication by id or key, fetch its
/// note body (if any) and its relationships, and write the result. Writes a
/// diagnostic to stderr and returns error.NotFound when no publication
/// matches, so the CLI can exit non-zero (mirrors executeKindAction's
/// show contract).
pub fn executeShowAction(
    database: *db.Db,
    allocator: std.mem.Allocator,
    action: ShowAction,
    stdout: anytype,
    stderr: anytype,
) ShowError!void {
    const lookup_sql: [*:0]const u8 = if (action.id != null)
        "SELECT id, kind, title, key FROM publications WHERE id = ?1;"
    else
        "SELECT id, kind, title, key FROM publications WHERE key = ?1;";
    const lookup_val: []const u8 = action.id orelse action.key.?;

    const pub_rows = database.queryRows(4, allocator, lookup_sql, &.{lookup_val}) catch return error.SqlFailed;
    defer db.Db.freeRows(4, allocator, pub_rows);

    if (pub_rows.len == 0) {
        if (action.id) |id| {
            stderr.print("Error: publication with id '{s}' not found\n", .{id}) catch {};
        } else {
            stderr.print("Error: publication with key '{s}' not found\n", .{action.key.?}) catch {};
        }
        return error.NotFound;
    }

    const row = pub_rows[0];
    const pub_id = row[0];
    const kind = row[1];
    const title = row[2];
    const key = row[3];

    // Note body (notes.body). A publication has at most one note row in
    // practice (created by `add` for the `note` kind), but be defensive and
    // take the most recent one.
    const body = database.queryTextParams(
        allocator,
        "SELECT body FROM notes WHERE publication = ?1 ORDER BY created_at DESC LIMIT 1;",
        &.{pub_id},
    ) catch return error.SqlFailed;
    defer if (body) |b| allocator.free(b);

    // Relationships where this publication is the subject or the object.
    // Columns: role ('subject'|'object'), relkind, other publication id.
    const rel_rows = database.queryRows(
        3,
        allocator,
        \\SELECT 'subject', kind, object FROM relationships WHERE subject = ?1
        \\UNION ALL
        \\SELECT 'object', kind, subject FROM relationships WHERE object = ?1
        \\ORDER BY 1, 2;
    ,
        &.{pub_id},
    ) catch return error.SqlFailed;
    defer db.Db.freeRows(3, allocator, rel_rows);

    if (action.json) {
        stdout.writeAll("{\"id\":") catch return error.SqlFailed;
        encodeJsonString(pub_id, .{}, stdout) catch return error.SqlFailed;
        stdout.writeAll(",\"kind\":") catch return error.SqlFailed;
        encodeJsonString(kind, .{}, stdout) catch return error.SqlFailed;
        stdout.writeAll(",\"key\":") catch return error.SqlFailed;
        encodeJsonString(key, .{}, stdout) catch return error.SqlFailed;
        stdout.writeAll(",\"title\":") catch return error.SqlFailed;
        encodeJsonString(title, .{}, stdout) catch return error.SqlFailed;
        stdout.writeAll(",\"body\":") catch return error.SqlFailed;
        encodeJsonString(body orelse "", .{}, stdout) catch return error.SqlFailed;
        stdout.writeAll(",\"relationships\":[") catch return error.SqlFailed;
        for (rel_rows, 0..) |rel, idx| {
            if (idx > 0) stdout.writeAll(",") catch return error.SqlFailed;
            stdout.writeAll("{\"role\":") catch return error.SqlFailed;
            encodeJsonString(rel[0], .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(",\"relkind\":") catch return error.SqlFailed;
            encodeJsonString(rel[1], .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(",\"publication\":") catch return error.SqlFailed;
            encodeJsonString(rel[2], .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll("}") catch return error.SqlFailed;
        }
        stdout.writeAll("]}\n") catch return error.SqlFailed;
    } else {
        stdout.print("id:    {s}\n", .{pub_id}) catch return error.SqlFailed;
        stdout.print("kind:  {s}\n", .{kind}) catch return error.SqlFailed;
        stdout.print("key:   {s}\n", .{key}) catch return error.SqlFailed;
        stdout.print("title: {s}\n", .{title}) catch return error.SqlFailed;
        if (rel_rows.len > 0) {
            stdout.writeAll("relationships:\n") catch return error.SqlFailed;
            for (rel_rows) |rel| {
                // role 'subject' → this -[relkind]-> other
                // role 'object'  → other -[relkind]-> this
                if (std.mem.eql(u8, rel[0], "subject")) {
                    stdout.print("  -[{s}]-> {s}\n", .{ rel[1], rel[2] }) catch return error.SqlFailed;
                } else {
                    stdout.print("  <-[{s}]- {s}\n", .{ rel[1], rel[2] }) catch return error.SqlFailed;
                }
            }
        }
        stdout.writeAll("\n") catch return error.SqlFailed;
        if (body) |b| {
            stdout.writeAll(b) catch return error.SqlFailed;
            if (b.len == 0 or b[b.len - 1] != '\n') {
                stdout.writeAll("\n") catch return error.SqlFailed;
            }
        } else {
            stdout.writeAll("(no note body)\n") catch return error.SqlFailed;
        }
    }
}

pub const relateUsage =
    \\Usage: ken [-D <path>] relate -s <subject-id> -o <object-id> -r <kind>
    \\
    \\Create a relationship between two publications.
    \\
    \\Options:
    \\
++ db_flag_help ++
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
    \\
++ db_flag_help ++
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

// ── Load ──

const LoadPublication = struct {
    ref: ?[]const u8 = null,
    kind: []const u8,
    key: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

const LoadRelationship = struct {
    subject: []const u8,
    object: []const u8,
    kind: []const u8,
};

const LoadNote = struct {
    publication: []const u8,
    body: []const u8,
};

const LoadData = struct {
    publications: ?[]const LoadPublication = null,
    relationships: ?[]const LoadRelationship = null,
    notes: ?[]const LoadNote = null,
};

pub const LoadAction = struct {
    file_path: [:0]const u8,
};

pub const loadUsage =
    \\Usage: ken [-D <path>] load <file>
    \\
    \\Load publications, relationships, and notes from a JSON file.
    \\Everything is inserted in a single transaction.
    \\
    \\Options:
    \\
++ db_flag_help ++
    \\
    \\JSON format:
    \\  {
    \\    "publications": [
    \\      {"ref": "p1", "kind": "arxiv", "key": "2301.07041", "title": "Paper A"},
    \\      {"ref": "t1", "kind": "topic", "title": "Scaling Laws"}
    \\    ],
    \\    "relationships": [
    \\      {"subject": "p1", "object": "t1", "kind": "derives-from"}
    \\    ],
    \\    "notes": [
    \\      {"publication": "p1", "body": "Important paper about..."}
    \\    ]
    \\  }
    \\
    \\All three arrays are optional. "ref" on publications is optional — only
    \\needed when referenced elsewhere in the file. In relationships and notes,
    \\subject/object/publication resolves first as a ref label, then as a UUID
    \\of an existing DB entry. All referenced kinds must already exist.
    \\
    \\Output JSON: {"publications":N,"relationships":N,"notes":N,"refs":{...}}
    \\The refs map gives the generated UUID for every labelled publication.
    \\
;

pub fn parseLoadArgs(args: []const [:0]const u8, cmd_index: usize) ParseError!LoadAction {
    const rest = args[cmd_index + 1 ..];

    var file_path: ?[:0]const u8 = null;
    for (rest) |arg| {
        if (isHelpFlag(arg)) return error.HelpRequested;
        if (file_path != null) return error.UnknownFlag;
        file_path = arg;
    }
    if (file_path == null) return error.MissingArgument;
    return .{ .file_path = file_path.? };
}

pub const LoadError = error{
    SqlFailed,
    InvalidJson,
    DuplicateRef,
    UnresolvedRef,
    MissingKind,
};

/// Check if a string looks like a UUID (8-4-4-4-12 hex pattern).
fn looksLikeUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return false;
        } else {
            if (!std.ascii.isHex(ch)) return false;
        }
    }
    return true;
}

pub fn executeLoadAction(
    database: *db.Db,
    allocator: std.mem.Allocator,
    file_content: []const u8,
    rand: std.Random,
    stdout: anytype,
    stderr: anytype,
) LoadError!void {
    // Parse JSON
    const data = std.json.parseFromSlice(LoadData, allocator, file_content, .{
        .ignore_unknown_fields = true,
    }) catch {
        stderr.print("Error: invalid JSON\n", .{}) catch {};
        return error.InvalidJson;
    };
    defer data.deinit();
    const load = data.value;

    const pubs = load.publications orelse &.{};
    const rels = load.relationships orelse &.{};
    const notes = load.notes orelse &.{};

    // Build ref→index map and check for duplicate refs.
    var ref_map = std.StringHashMap(usize).init(allocator);
    defer ref_map.deinit();
    var has_dup = false;
    for (pubs, 0..) |p, i| {
        if (p.ref) |ref| {
            const gop = ref_map.getOrPut(ref) catch {
                stderr.print("Error: out of memory\n", .{}) catch {};
                return error.SqlFailed;
            };
            if (gop.found_existing) {
                stderr.print("Error: duplicate ref '{s}'\n", .{ref}) catch {};
                has_dup = true;
            } else {
                gop.value_ptr.* = i;
            }
        }
    }
    if (has_dup) return error.DuplicateRef;

    // Validate all references in relationships/notes resolve
    var has_unresolved = false;
    for (rels) |rel| {
        for ([_][]const u8{ rel.subject, rel.object }) |ref| {
            if (!ref_map.contains(ref) and !looksLikeUuid(ref)) {
                stderr.print("Error: unresolved reference '{s}'\n", .{ref}) catch {};
                has_unresolved = true;
            }
        }
    }
    for (notes) |note| {
        if (!ref_map.contains(note.publication) and !looksLikeUuid(note.publication)) {
            stderr.print("Error: unresolved reference '{s}'\n", .{note.publication}) catch {};
            has_unresolved = true;
        }
    }
    if (has_unresolved) return error.UnresolvedRef;

    // BEGIN IMMEDIATE
    database.exec("BEGIN IMMEDIATE;") catch {
        stderr.print("Error: could not begin transaction\n", .{}) catch {};
        return error.SqlFailed;
    };
    errdefer database.exec("ROLLBACK;") catch {};

    // Validate all publication kinds exist (deduplicated)
    var has_missing = false;
    for (pubs, 0..) |p, pi| {
        const already_checked = for (pubs[0..pi]) |prev| {
            if (std.mem.eql(u8, prev.kind, p.kind)) break true;
        } else false;
        if (already_checked) continue;

        const exists = database.exists(
            "SELECT 1 FROM publication_kinds WHERE name = ?1;",
            &.{p.kind},
        ) catch {
            stderr.print("Error: could not query database\n", .{}) catch {};
            return error.SqlFailed;
        };
        if (!exists) {
            stderr.print("Error: unknown publication kind '{s}'\n", .{p.kind}) catch {};
            has_missing = true;
        }
    }

    // Validate all relationship kinds exist (deduplicated)
    for (rels, 0..) |rel, ri| {
        const already_checked = for (rels[0..ri]) |prev| {
            if (std.mem.eql(u8, prev.kind, rel.kind)) break true;
        } else false;
        if (already_checked) continue;

        const exists = database.exists(
            "SELECT 1 FROM relationship_kinds WHERE name = ?1;",
            &.{rel.kind},
        ) catch {
            stderr.print("Error: could not query database\n", .{}) catch {};
            return error.SqlFailed;
        };
        if (!exists) {
            stderr.print("Error: unknown relationship kind '{s}'\n", .{rel.kind}) catch {};
            has_missing = true;
        }
    }
    if (has_missing) return error.MissingKind;

    // Generate UUIDs and INSERT publications. Build ref_to_uuid map.
    // Store all generated UUIDs in an array parallel to pubs.
    const uuids = allocator.alloc([36]u8, pubs.len) catch {
        stderr.print("Error: out of memory\n", .{}) catch {};
        return error.SqlFailed;
    };
    defer allocator.free(uuids);

    for (pubs, 0..) |p, i| {
        var rand_bytes: [16]u8 = undefined;
        rand.bytes(&rand_bytes);
        uuidV4(&uuids[i], &rand_bytes);

        database.execParams(
            "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
            &.{ &uuids[i], p.key, p.kind, p.title },
        ) catch {
            stderr.print("Error: could not insert publication\n", .{}) catch {};
            return error.SqlFailed;
        };
    }

    // INSERT relationships
    for (rels) |rel| {
        const subject_uuid: []const u8 = if (ref_map.get(rel.subject)) |i| &uuids[i] else rel.subject;
        const object_uuid: []const u8 = if (ref_map.get(rel.object)) |i| &uuids[i] else rel.object;

        var rel_rand: [16]u8 = undefined;
        rand.bytes(&rel_rand);
        var rel_uuid: [36]u8 = undefined;
        uuidV4(&rel_uuid, &rel_rand);

        database.execParams(
            "INSERT INTO relationships (id, subject, object, kind) VALUES (?1, ?2, ?3, ?4);",
            &.{ &rel_uuid, subject_uuid, object_uuid, rel.kind },
        ) catch {
            stderr.print("Error: could not insert relationship\n", .{}) catch {};
            return error.SqlFailed;
        };
    }

    // INSERT notes
    for (notes) |note| {
        const pub_uuid: []const u8 = if (ref_map.get(note.publication)) |i| &uuids[i] else note.publication;

        var note_rand: [16]u8 = undefined;
        rand.bytes(&note_rand);
        var note_uuid: [36]u8 = undefined;
        uuidV4(&note_uuid, &note_rand);

        database.execParams(
            "INSERT INTO notes (id, publication, body) VALUES (?1, ?2, ?3);",
            &.{ &note_uuid, pub_uuid, note.body },
        ) catch {
            stderr.print("Error: could not insert note\n", .{}) catch {};
            return error.SqlFailed;
        };
    }

    // COMMIT
    database.exec("COMMIT;") catch {
        stderr.print("Error: could not commit transaction\n", .{}) catch {};
        return error.SqlFailed;
    };

    // Write output JSON
    stdout.print("{{\"publications\":{d},\"relationships\":{d},\"notes\":{d},\"refs\":{{", .{
        pubs.len,
        rels.len,
        notes.len,
    }) catch return error.SqlFailed;

    var first = true;
    for (pubs, 0..) |p, i| {
        if (p.ref) |ref| {
            if (!first) stdout.writeAll(",") catch return error.SqlFailed;
            encodeJsonString(ref, .{}, stdout) catch return error.SqlFailed;
            stdout.writeAll(":") catch return error.SqlFailed;
            encodeJsonString(&uuids[i], .{}, stdout) catch return error.SqlFailed;
            first = false;
        }
    }

    stdout.writeAll("}}\n") catch return error.SqlFailed;
}

// ── Skill ──

pub const skillUsage =
    \\Usage: ken skill
    \\
    \\Print an Agent Skills spec (agentskills.io) SKILL.md to stdout.
    \\Pipe to a file to install, e.g.:
    \\  mkdir -p ~/.claude/skills/ken && ken skill > ~/.claude/skills/ken/SKILL.md
    \\
;

pub const skillContent =
    \\---
    \\name: ken
    \\description: >-
    \\  Catalog and query research literature (books, papers, articles, videos)
    \\  using the ken CLI. Use when the user asks to track publications, organize
    \\  references, take research notes, or explore relationships between works.
    \\---
    \\
    \\# ken
    \\
    \\ken is a research literature catalog. It stores publications (books, papers,
    \\articles, videos, web pages), your notes about them, and directed relationships
    \\between them in a SQLite database. The database schema is the core of ken —
    \\the CLI is a thin wrapper that encapsulates its assumptions.
    \\
    \\## Design principles
    \\
    \\- Every command and subcommand responds to `-h`/`--help` with scoped help text.
    \\  Explore the CLI by running `ken -h`, `ken add -h`, `ken pubkind list -h`, etc.
    \\- Exit codes are uniform: every command exits 0 on success and 1 on any
    \\  failure — bad arguments, usage errors, not-found, database errors, file
    \\  errors, JSON parse errors, conflicts, unknown commands/flags, or missing
    \\  required options. Diagnostics go to stderr; machine output to stdout. This
    \\  makes `ken <cmd> ... || handle_failure` a reliable guard in any pipeline.
    \\- All output intended for machine consumption is JSON.
    \\- Every database command accepts `-D/--db <path>` to target a specific database.
    \\  If omitted, a platform-specific default is used (run `ken initpath` to see it).
    \\- Users can maintain multiple databases — one per research interest, one per
    \\  agent, or any other scheme. Databases are regular SQLite files that can be
    \\  copied, shared, and merged.
    \\- The database can be queried directly with SQL. Prefer the CLI when possible,
    \\  as it encapsulates schema assumptions (FK constraints, UUID generation,
    \\  timestamps, conflict resolution).
    \\
    \\## Setup
    \\
    \\```sh
    \\# Create or upgrade the default database
    \\ken init
    \\
    \\# Create a database at a specific path
    \\ken -D ~/research/ml.db init
    \\
    \\# Print the default database path
    \\ken initpath
    \\```
    \\
    \\## Adding publications
    \\
    \\```sh
    \\ken [-D <path>] add <kind> [-k/--key <key>] [--title <title>]
    \\```
    \\
    \\Prints the UUID of the new publication to stdout.
    \\
    \\Built-in publication kinds and their key formats:
    \\- `arxiv` — arXiv identifier (e.g. `2301.07041`). URL: `https://arxiv.org/abs/{key}`
    \\- `video` — YouTube video ID (11 chars). URL: `https://www.youtube.com/watch?v={key}`
    \\- `web` — full URL including scheme (e.g. `https://example.com/page`)
    \\- `note` — key is optional; if provided, treated as a file path whose contents
    \\  are read into the notes table
    \\- `topic` — a conceptual node for organizing literature. Key is optional (e.g.
    \\  Wikipedia URL or taxonomy code). Title is the human-readable topic name.
    \\
    \\Users can add custom kinds via `ken pubkind add`. The kind's description should
    \\specify how to interpret the key field.
    \\
    \\Examples:
    \\```sh
    \\ken add arxiv -k 2301.07041 --title "Scaling Laws for Neural Language Models"
    \\ken add web -k https://example.com/survey --title "ML Survey"
    \\ken add note --title "Thoughts on attention"
    \\ken add note -k ./notes/attention.md --title "Attention notes from file"
    \\```
    \\
    \\## Listing publications
    \\
    \\```sh
    \\ken [-D <path>] list [--kind <kind>] [--limit N] [--offset N]
    \\```
    \\
    \\Outputs a JSON array of objects with `id`, `kind`, `title`, `key` fields.
    \\
    \\Examples:
    \\```sh
    \\ken list
    \\ken list --kind arxiv --limit 10
    \\ken list --offset 20 --limit 10
    \\```
    \\
    \\`list` returns metadata only — it never includes a note's body. Use
    \\`ken show` to read the full record including the body.
    \\
    \\## Reading a publication
    \\
    \\```sh
    \\ken [-D <path>] show <id> [--json]
    \\ken [-D <path>] show --key <key> [--json]
    \\```
    \\
    \\Prints a publication's full record (id, kind, key, title), its note body
    \\if it has one (notes added via `ken add note`), and its relationships
    \\(both directions). Look it up by UUID (positional) or by key (`--key`).
    \\
    \\Without `--json`, output is human-readable. With `--json`, output is a
    \\single object: `{"id","kind","key","title","body","relationships":[...]}`
    \\where each relationship is
    \\`{"role":"subject"|"object","relkind":...,"publication":<other-id>}`.
    \\A `subject` role means this publication points at the other; an `object`
    \\role means the other points at this one. `body` is `""` when there is
    \\no note body.
    \\
    \\Exits 1 (with a diagnostic on stderr) if no publication matches — as do
    \\all error paths CLI-wide — so `ken show <id> >/dev/null 2>&1 && ...`
    \\works as a guard.
    \\
    \\Examples:
    \\```sh
    \\ken show 1f2e3d4c-5b6a-7980-1234-567890abcdef
    \\ken show --key 2301.07041
    \\ken show --key 2301.07041 --json
    \\```
    \\
    \\This is how a multi-step agent reads back its own earlier notes through
    \\the CLI instead of reaching around ken to the on-disk database.
    \\
    \\## Relationships
    \\
    \\Relationships are directed: each has a subject and an object.
    \\
    \\```sh
    \\ken [-D <path>] relate -s <subject-id> -o <object-id> -r <kind>
    \\```
    \\
    \\Prints the UUID of the new relationship to stdout.
    \\
    \\Built-in relationship kinds:
    \\- `cites` — subject cites object as a reference or source.
    \\- `derives-from` — subject is derived from or builds upon object.
    \\
    \\Users can add custom kinds via `ken relkind add`.
    \\
    \\Example:
    \\```sh
    \\ID1=$(ken add arxiv -k 2301.07041 --title "Paper A")
    \\ID2=$(ken add arxiv -k 2405.00001 --title "Paper B")
    \\ken relate -s $ID1 -o $ID2 -r cites
    \\```
    \\
    \\## Managing kinds
    \\
    \\Publication kinds and relationship kinds each have `show`, `list`, `add`,
    \\`remove`, and `update` subcommands.
    \\
    \\```sh
    \\ken pubkind list --descriptions    # list publication kinds with descriptions
    \\ken pubkind show arxiv             # show one kind as JSON
    \\ken pubkind add book "Keyed by ISBN-13. URL: https://isbnsearch.org/isbn/{key}"
    \\ken pubkind update arxiv --description "Updated description"
    \\ken pubkind remove book            # fails if publications of this kind exist
    \\
    \\ken relkind list                   # list built-in and custom relationship kinds
    \\ken relkind show cites              # show one relationship kind as JSON
    \\```
    \\
    \\Kind descriptions are critical — they tell both humans and AI how to interpret
    \\keys and relationships. Write them precisely.
    \\
    \\## Merging databases
    \\
    \\```sh
    \\ken [-D <path>] merge -f <source-path> [--check] [--nocheck] [--force]
    \\```
    \\
    \\Imports data from source into target in a single transaction. Outputs JSON
    \\with insertion counts on success.
    \\
    \\- No flag: abort if kind description conflicts exist, merge otherwise.
    \\- `--check`: only detect conflicts, don't merge.
    \\- `--force`: merge despite conflicts (target descriptions win).
    \\- `--nocheck`: skip conflict detection entirely.
    \\
    \\Example:
    \\```sh
    \\ken -D combined.db merge -f agent1.db
    \\ken -D combined.db merge -f agent2.db --force
    \\```
    \\
    \\## Batch loading
    \\
    \\```sh
    \\ken [-D <path>] load <file.json>
    \\```
    \\
    \\Insert publications, relationships, and notes from a JSON file in a single
    \\transaction. This is much faster than invoking `ken add` / `ken relate` in a
    \\loop.
    \\
    \\JSON format:
    \\```json
    \\{
    \\  "publications": [
    \\    {"ref": "p1", "kind": "arxiv", "key": "2301.07041", "title": "Paper A"},
    \\    {"ref": "t1", "kind": "topic", "title": "Scaling Laws"}
    \\  ],
    \\  "relationships": [
    \\    {"subject": "p1", "object": "t1", "kind": "derives-from"}
    \\  ],
    \\  "notes": [
    \\    {"publication": "p1", "body": "Important paper about scaling."}
    \\  ]
    \\}
    \\```
    \\
    \\- All three arrays are optional. `{}` is a valid no-op.
    \\- `ref` on publications is optional — only needed when referenced elsewhere.
    \\- In relationships/notes, subject/object/publication resolves as a ref first,
    \\  then as a UUID of an existing DB row.
    \\- All referenced kinds must already exist in the DB.
    \\- UUIDs are generated by ken (never in the JSON).
    \\
    \\Output: `{"publications":N,"relationships":N,"notes":N,"refs":{"p1":"uuid",...}}`
    \\The refs map gives the generated UUID for every labelled publication.
    \\
    \\## Workflow example
    \\
    \\```sh
    \\ken init
    \\
    \\# Add publications
    \\A=$(ken add arxiv -k 2301.07041 --title "Chinchilla")
    \\B=$(ken add arxiv -k 2005.14165 --title "GPT-3")
    \\
    \\# Use built-in relationship kinds directly
    \\ken relate -s $A -o $B -r cites
    \\ken relate -s $A -o $B -r derives-from
    \\
    \\# Organize by topic
    \\T=$(ken add topic --title "Scaling Laws")
    \\ken relate -s $A -o $T -r derives-from
    \\
    \\ken list --kind arxiv
    \\```
    \\
;

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
    // Must return an error (so the CLI can exit non-zero) and write the
    // diagnostic to stderr, leaving stdout empty. This contract backs the
    // `ken pubkind show X || ken pubkind add X` idempotent-guard idiom.
    try testing.expectError(error.NotFound, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "not found") != null);
    try testing.expectEqualStrings("", out.buffered());
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

    // Limit 2, offset 2 → next two alphabetically (topic, video)
    out.end = 0;
    try executeKindAction(&database, testing.allocator, .pubkind, .{ .list = .{ .pagination = .{ .limit = 2, .offset = 2 } } }, &out, &err_w);
    const output2 = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output2, "\"name\":\"topic\"") != null);
    try testing.expect(std.mem.indexOf(u8, output2, "\"name\":\"video\"") != null);
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

    // Built-in kinds (cites, derives-from) should already be present
    try executeKindAction(&database, testing.allocator, .relkind, .{ .list = .{ .pagination = .{} } }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"name\":\"cites\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"name\":\"derives-from\"") != null);

    // Adding a custom kind should work
    out.end = 0;
    try executeKindAction(&database, testing.allocator, .relkind, .{ .add = .{ .name = "develops", .description = "Subject develops object" } }, &out, &err_w);
    try testing.expectEqualStrings("{\"name\":\"develops\",\"description\":\"Subject develops object\"}\n", out.buffered());
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

// ── parseLoadArgs tests ──

test "load: file path" {
    const args = mkArgs(&.{ "ken", "load", "data.json" });
    const action = try parseLoadArgs(&args, 1);
    try testing.expectEqualStrings("data.json", action.file_path);
}

test "load: missing file path" {
    const args = mkArgs(&.{ "ken", "load" });
    const result = parseLoadArgs(&args, 1);
    try testing.expectError(error.MissingArgument, result);
}

test "load: help flag" {
    const args = mkArgs(&.{ "ken", "load", "-h" });
    const result = parseLoadArgs(&args, 1);
    try testing.expectError(error.HelpRequested, result);
}

test "load: extra arg is error" {
    const args = mkArgs(&.{ "ken", "load", "a.json", "b.json" });
    const result = parseLoadArgs(&args, 1);
    try testing.expectError(error.UnknownFlag, result);
}

// ── executeLoadAction tests ──

test "executeLoadAction: empty object is no-op" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    var prng = std.Random.Pcg.init(42);
    try executeLoadAction(&database, testing.allocator, "{}", prng.random(), &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"relationships\":0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"notes\":0") != null);
}

test "executeLoadAction: insert publications with refs" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","key":"2301.07041","title":"Paper A"},
        \\  {"ref":"t1","kind":"topic","title":"Scaling Laws"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    try executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"p1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"t1\"") != null);
}

test "executeLoadAction: publications with relationships" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","key":"2301.07041","title":"Paper A"},
        \\  {"ref":"t1","kind":"topic","title":"Scaling Laws"}
        \\],
        \\"relationships":[
        \\  {"subject":"p1","object":"t1","kind":"derives-from"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(99);
    try executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"relationships\":1") != null);
}

test "executeLoadAction: publications with notes" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","key":"2301.07041","title":"Paper A"}
        \\],
        \\"notes":[
        \\  {"publication":"p1","body":"Important paper about scaling."}
        \\]}
    ;

    var prng = std.Random.Pcg.init(7);
    try executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"notes\":1") != null);
}

test "executeLoadAction: duplicate ref error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","title":"A"},
        \\  {"ref":"p1","kind":"arxiv","title":"B"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    const result = executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    try testing.expectError(error.DuplicateRef, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "duplicate ref") != null);
}

test "executeLoadAction: unresolved ref error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","title":"A"}
        \\],
        \\"relationships":[
        \\  {"subject":"p1","object":"nonexistent","kind":"cites"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    const result = executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    try testing.expectError(error.UnresolvedRef, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "unresolved reference") != null);
}

test "executeLoadAction: unknown publication kind error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"kind":"bogus","title":"A"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    const result = executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    try testing.expectError(error.MissingKind, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "unknown publication kind") != null);
}

test "executeLoadAction: unknown relationship kind error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","title":"A"},
        \\  {"ref":"p2","kind":"arxiv","title":"B"}
        \\],
        \\"relationships":[
        \\  {"subject":"p1","object":"p2","kind":"bogus-rel"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    const result = executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    try testing.expectError(error.MissingKind, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "unknown relationship kind") != null);
}

test "executeLoadAction: invalid JSON error" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    var prng = std.Random.Pcg.init(42);
    const result = executeLoadAction(&database, testing.allocator, "not json", prng.random(), &out, &err_w);
    try testing.expectError(error.InvalidJson, result);
}

test "executeLoadAction: UUID reference in relationship" {
    var database = try testDb();
    defer database.close();

    // First insert a publication manually to get a known UUID
    try database.execParams(
        "INSERT INTO publications (id, kind, title) VALUES (?1, ?2, ?3);",
        &.{ "550e8400-e29b-41d4-a716-446655440000", "arxiv", "Existing paper" },
    );

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const json =
        \\{"publications":[
        \\  {"ref":"p1","kind":"arxiv","title":"New paper"}
        \\],
        \\"relationships":[
        \\  {"subject":"p1","object":"550e8400-e29b-41d4-a716-446655440000","kind":"cites"}
        \\]}
    ;

    var prng = std.Random.Pcg.init(42);
    try executeLoadAction(&database, testing.allocator, json, prng.random(), &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"publications\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"relationships\":1") != null);
}

test "looksLikeUuid: valid UUID" {
    try testing.expect(looksLikeUuid("550e8400-e29b-41d4-a716-446655440000"));
}

test "looksLikeUuid: invalid strings" {
    try testing.expect(!looksLikeUuid("not-a-uuid"));
    try testing.expect(!looksLikeUuid("550e8400-e29b-41d4-a716-44665544000")); // too short
    try testing.expect(!looksLikeUuid("550e8400-e29b-41d4-a716-4466554400000")); // too long
    try testing.expect(!looksLikeUuid("550e8400xe29b-41d4-a716-446655440000")); // wrong separator
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

// ── parseShowArgs tests ──

test "parseShowArgs: positional id" {
    const args = mkArgs(&.{ "ken", "show", "abc-123" });
    const action = try parseShowArgs(&args, 1);
    try testing.expectEqualStrings("abc-123", action.id.?);
    try testing.expect(action.key == null);
    try testing.expect(!action.json);
}

test "parseShowArgs: --key lookup" {
    const args = mkArgs(&.{ "ken", "show", "--key", "2301.07041" });
    const action = try parseShowArgs(&args, 1);
    try testing.expectEqualStrings("2301.07041", action.key.?);
    try testing.expect(action.id == null);
}

test "parseShowArgs: --json with id" {
    const args = mkArgs(&.{ "ken", "show", "abc-123", "--json" });
    const action = try parseShowArgs(&args, 1);
    try testing.expectEqualStrings("abc-123", action.id.?);
    try testing.expect(action.json);
}

test "parseShowArgs: --json with --key" {
    const args = mkArgs(&.{ "ken", "show", "--key", "k1", "--json" });
    const action = try parseShowArgs(&args, 1);
    try testing.expectEqualStrings("k1", action.key.?);
    try testing.expect(action.json);
}

test "parseShowArgs: missing argument" {
    const args = mkArgs(&.{ "ken", "show" });
    try testing.expectError(error.MissingArgument, parseShowArgs(&args, 1));
}

test "parseShowArgs: id and --key conflict" {
    const args = mkArgs(&.{ "ken", "show", "abc-123", "--key", "k1" });
    try testing.expectError(error.UnknownFlag, parseShowArgs(&args, 1));
}

test "parseShowArgs: two positionals rejected" {
    const args = mkArgs(&.{ "ken", "show", "id1", "id2" });
    try testing.expectError(error.UnknownFlag, parseShowArgs(&args, 1));
}

test "parseShowArgs: unknown flag" {
    const args = mkArgs(&.{ "ken", "show", "--bogus" });
    try testing.expectError(error.UnknownFlag, parseShowArgs(&args, 1));
}

test "parseShowArgs: help flag" {
    const args = mkArgs(&.{ "ken", "show", "-h" });
    try testing.expectError(error.HelpRequested, parseShowArgs(&args, 1));
}

test "parseShowArgs: --key without value" {
    const args = mkArgs(&.{ "ken", "show", "--key" });
    try testing.expectError(error.MissingArgument, parseShowArgs(&args, 1));
}

// ── executeShowAction tests ──

test "executeShowAction: by id with note body and relationships" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "note-id", "/n.md", "note", "My Note" },
    );
    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "arxiv-id", "2301.07041", "arxiv", "Paper" },
    );
    try database.execParams(
        "INSERT INTO notes (id, publication, body) VALUES (?1, ?2, ?3);",
        &.{ "note-row", "note-id", "The body text." },
    );
    try database.execParams(
        "INSERT INTO relationships (id, subject, object, kind) VALUES (?1, ?2, ?3, ?4);",
        &.{ "rel-id", "note-id", "arxiv-id", "cites" },
    );

    try executeShowAction(&database, testing.allocator, .{ .id = "note-id" }, &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "id:    note-id") != null);
    try testing.expect(std.mem.indexOf(u8, output, "kind:  note") != null);
    try testing.expect(std.mem.indexOf(u8, output, "title: My Note") != null);
    try testing.expect(std.mem.indexOf(u8, output, "The body text.") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-[cites]-> arxiv-id") != null);
}

test "executeShowAction: by key, json output" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "p1", "2301.07041", "arxiv", "Scaling" },
    );
    try database.execParams(
        "INSERT INTO notes (id, publication, body) VALUES (?1, ?2, ?3);",
        &.{ "n1", "p1", "line one\nline two" },
    );

    try executeShowAction(&database, testing.allocator, .{ .key = "2301.07041", .json = true }, &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"id\":\"p1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"arxiv\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"key\":\"2301.07041\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"title\":\"Scaling\"") != null);
    // Body must be JSON-escaped (newline → \n).
    try testing.expect(std.mem.indexOf(u8, output, "\"body\":\"line one\\nline two\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"relationships\":[]") != null);
}

test "executeShowAction: object-role relationship" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "subj", "ka", "arxiv", "A" },
    );
    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "obj", "kb", "arxiv", "B" },
    );
    try database.execParams(
        "INSERT INTO relationships (id, subject, object, kind) VALUES (?1, ?2, ?3, ?4);",
        &.{ "r1", "subj", "obj", "cites" },
    );

    try executeShowAction(&database, testing.allocator, .{ .id = "obj", .json = true }, &out, &err_w);
    const output = out.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"role\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"relkind\":\"cites\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"publication\":\"subj\"") != null);
}

test "executeShowAction: not found by id returns error.NotFound" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeShowAction(&database, testing.allocator, .{ .id = "missing" }, &out, &err_w);
    try testing.expectError(error.NotFound, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "not found") != null);
    try testing.expectEqualStrings("", out.buffered());
}

test "executeShowAction: not found by key returns error.NotFound" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    const result = executeShowAction(&database, testing.allocator, .{ .key = "nope" }, &out, &err_w);
    try testing.expectError(error.NotFound, result);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "key 'nope'") != null);
}

test "executeShowAction: publication with no note body" {
    var database = try testDb();
    defer database.close();

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_w: std.Io.Writer = .fixed(&err_buf);

    try database.execParams(
        "INSERT INTO publications (id, key, kind, title) VALUES (?1, ?2, ?3, ?4);",
        &.{ "p-nobody", "kx", "arxiv", "No Body" },
    );

    try executeShowAction(&database, testing.allocator, .{ .id = "p-nobody" }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "(no note body)") != null);

    out.end = 0;
    try executeShowAction(&database, testing.allocator, .{ .id = "p-nobody", .json = true }, &out, &err_w);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"body\":\"\"") != null);
}

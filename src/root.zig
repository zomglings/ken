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
    return "Usage: ken " ++ @tagName(entity) ++ " <subcommand> [options]\n" ++
        "\nManage " ++ lbl ++ "s.\n" ++
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
        .show => "Usage: ken " ++ ent ++ " show <name>\n\nShow a " ++ lbl ++ " by name. Prints JSON with name and description.\n",
        .list => "Usage: ken " ++ ent ++ " list [--limit N] [--offset N] [--descriptions]\n\nList " ++ lbl ++ "s as a JSON array.\n\nOptions:\n  --limit N        Maximum number of results\n  --offset N       Skip first N results\n  --descriptions   Include descriptions in output\n",
        .add => "Usage: ken " ++ ent ++ " add <name> <description>\n\nAdd a new " ++ lbl ++ ".\n",
        .remove => "Usage: ken " ++ ent ++ " remove <name>\n\nRemove a " ++ lbl ++ ". Fails if the kind is in use.\n",
        .update => "Usage: ken " ++ ent ++ " update <name> [--name N] [--description D]\n\nUpdate a " ++ lbl ++ ". At least one of --name or --description is required.\n",
    };
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
            const rows = database.queryRows2(allocator, sql, &.{}) catch return error.SqlFailed;
            defer db.Db.freeRows2(allocator, rows);
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
    \\Usage: ken add <kind> [-k/--key <key>] [--title <title>]
    \\
    \\Add a publication to the database.
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

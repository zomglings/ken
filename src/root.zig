//! ken: a research literature catalog.

const std = @import("std");
const builtin = @import("builtin");
pub const db = @import("db.zig");

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
    \\INSERT INTO publication_kinds (name, description) VALUES ('note', 'A researcher''s own note or annotation. The key field is unused. The note body is stored in the notes table, linked by publication id.');
    \\INSERT INTO publication_kinds (name, description) VALUES ('arxiv', 'A preprint on arXiv. The key is the arXiv identifier (e.g. 2301.07041 or math.AG/0601185).');
    \\INSERT INTO publication_kinds (name, description) VALUES ('video', 'A YouTube video. The key is the YouTube video ID (the v parameter, e.g. dQw4w9WgXcQ).');
    \\INSERT INTO publication_kinds (name, description) VALUES ('web', 'A web page or online resource. The key is the full URL.');
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
    list: struct { pagination: Pagination },
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
        "  list [--limit N] [--offset N]              List " ++ lbl ++ "s\n" ++
        "  add <name> <description>                   Add a " ++ lbl ++ "\n" ++
        "  remove <name>                              Remove a " ++ lbl ++ "\n" ++
        "  update <name> [--name N] [--description D] Update a " ++ lbl ++ "\n";
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
                } else {
                    return error.UnknownFlag;
                }
            }
            return .{ .list = .{ .pagination = pagination } };
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

/// Stub executor — prints what the action would do. No database yet.
pub fn executeKindAction(
    entity: KindEntity,
    action: KindAction,
    stdout: anytype,
) !void {
    const lbl = entity.label();
    switch (action) {
        .show => |v| try stdout.print("Would show {s} '{s}' (database not yet initialized)\n", .{ lbl, v.name }),
        .list => |v| {
            try stdout.print("Would list {s}s", .{lbl});
            if (v.pagination.limit) |l| try stdout.print(" limit={d}", .{l});
            if (v.pagination.offset) |o| try stdout.print(" offset={d}", .{o});
            try stdout.print(" (database not yet initialized)\n", .{});
        },
        .add => |v| try stdout.print("Would add {s} '{s}': {s} (database not yet initialized)\n", .{ lbl, v.name, v.description }),
        .remove => |v| try stdout.print("Would remove {s} '{s}' (database not yet initialized)\n", .{ lbl, v.name }),
        .update => |v| {
            try stdout.print("Would update {s} '{s}':", .{ lbl, v.name });
            if (v.new_name) |n| try stdout.print(" name->'{s}'", .{n});
            if (v.new_description) |d| try stdout.print(" description->'{s}'", .{d});
            try stdout.print(" (database not yet initialized)\n", .{});
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

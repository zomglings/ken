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
    \\INSERT INTO publication_kinds (name, description) VALUES ('note', 'A note. The key field is unused.');
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

//! SQLite wrapper and schema migration engine for ken.

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

pub const SqliteError = error{
    CantOpen,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    CloseFailed,
};

pub const MigrationError = error{
    DatabaseAheadOfMigrations,
};

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open a SQLite database. Pass ":memory:" for an in-memory database.
    pub fn open(path: [*:0]const u8) (SqliteError || MigrationError)!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.CantOpen;
        }
        return .{ .handle = db.? };
    }

    /// Close the database.
    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute one or more SQL statements. Returns error on failure.
    pub fn exec(self: *Db, sql: [*:0]const u8) SqliteError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.ExecFailed;
        }
    }

    /// Prepare, step, and finalize a single-row query returning one integer.
    /// Returns null if the query returns no rows.
    fn queryInt(self: *Db, sql: [*:0]const u8) SqliteError!?i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt.?);
        if (rc == c.SQLITE_ROW) return c.sqlite3_column_int64(stmt.?, 0);
        if (rc == c.SQLITE_DONE) return null;
        return error.StepFailed;
    }

    /// Returns the current schema version, or null if _ken_meta doesn't exist.
    pub fn getVersion(self: *Db) (SqliteError || MigrationError)!?u32 {
        // COUNT returns 0 (not no rows) when the table is missing, so we
        // check sqlite_master first. A non-null result means the table exists.
        const exists = try self.queryInt(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='_ken_meta' LIMIT 1;",
        );
        if (exists == null) return null;

        const val = try self.queryInt(
            "SELECT CAST(value AS INTEGER) FROM _ken_meta WHERE key='schema_version';",
        );
        if (val) |v| return @intCast(v);
        return null;
    }

    /// Run migrations. migrations[i] brings the DB to version i.
    /// Returns the final schema version.
    pub fn migrate(self: *Db, migrations: []const [*:0]const u8) (SqliteError || MigrationError)!u32 {
        // Ensure _ken_meta table exists.
        try self.exec(
            "CREATE TABLE IF NOT EXISTS _ken_meta (key TEXT PRIMARY KEY, value TEXT);",
        );

        const current = try self.getVersion();
        const target: u32 = @intCast(migrations.len);

        if (current) |v| {
            if (v >= target) {
                if (v > target) return error.DatabaseAheadOfMigrations;
                // Already at target — no-op.
                return v;
            }
        }

        const start: u32 = if (current) |v| v + 1 else 0;

        for (start..target) |i| {
            try self.exec("BEGIN;");
            self.exec(migrations[i]) catch {
                // Attempt rollback on failure, ignore rollback errors.
                self.exec("ROLLBACK;") catch {};
                return error.ExecFailed;
            };
            // Update version inside the transaction.
            var buf: [128]u8 = undefined;
            const update_sql = std.fmt.bufPrintZ(&buf, "INSERT OR REPLACE INTO _ken_meta (key, value) VALUES ('schema_version', '{d}');", .{i}) catch unreachable;
            self.exec(update_sql) catch {
                self.exec("ROLLBACK;") catch {};
                return error.ExecFailed;
            };
            try self.exec("COMMIT;");
        }

        return target - 1;
    }
};

// ── Tests ──

const testing = std.testing;

// Toy schema for testing the migration engine.
const toy_migrations: []const [*:0]const u8 = &.{
    "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
    "ALTER TABLE items ADD COLUMN description TEXT;",
    "CREATE TABLE tags (id INTEGER PRIMARY KEY, item_id INTEGER REFERENCES items(id), tag TEXT NOT NULL);",
};

test "fresh DB: migrate all 3 → version 2, tables exist" {
    var db = try Db.open(":memory:");
    defer db.close();

    const version = try db.migrate(toy_migrations);
    try testing.expectEqual(@as(u32, 2), version);

    // Verify items table exists with description column.
    try db.exec("INSERT INTO items (name, description) VALUES ('test', 'a test item');");
    // Verify tags table exists.
    try db.exec("INSERT INTO tags (item_id, tag) VALUES (1, 'example');");
}

test "incremental migration: 1 then all 3" {
    var db = try Db.open(":memory:");
    defer db.close();

    const v1 = try db.migrate(toy_migrations[0..1]);
    try testing.expectEqual(@as(u32, 0), v1);

    const v2 = try db.migrate(toy_migrations);
    try testing.expectEqual(@as(u32, 2), v2);

    // Verify all tables and columns exist.
    try db.exec("INSERT INTO items (name, description) VALUES ('test', 'desc');");
    try db.exec("INSERT INTO tags (item_id, tag) VALUES (1, 'tag');");
}

test "already at latest version: no-op" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);
    const v = try db.migrate(toy_migrations);
    try testing.expectEqual(@as(u32, 2), v);
}

test "getVersion: fresh DB returns null" {
    var db = try Db.open(":memory:");
    defer db.close();

    const v = try db.getVersion();
    try testing.expect(v == null);
}

test "getVersion: after migrate returns correct version" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations[0..2]);
    const v = try db.getVersion();
    try testing.expectEqual(@as(?u32, 1), v);
}

test "down-migration rejected" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    const result = db.migrate(toy_migrations[0..2]);
    try testing.expectError(error.DatabaseAheadOfMigrations, result);
}

//! SQLite wrapper and schema migration engine for ken.

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

// SQLITE_STATIC tells SQLite the bound data will outlive the statement.
// Safe here because we always finalize before returning.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const SqliteError = error{
    CantOpen,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    ConstraintViolation,
};

pub const MigrationError = error{
    DatabaseAheadOfMigrations,
};

const meta_key_version = "schema_version";

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open a SQLite database. Pass ":memory:" for an in-memory database.
    pub fn open(path: [*:0]const u8) SqliteError!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close_v2(d);
            return error.CantOpen;
        }
        var self = Db{ .handle = db.? };
        try self.exec("PRAGMA foreign_keys = ON;");
        return self;
    }

    /// Close the database.
    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
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

    /// Prepare a statement and bind text parameters. Caller must finalize.
    fn prepareAndBind(self: *Db, sql: [*:0]const u8, params: []const ?[]const u8) SqliteError!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;

        for (params, 1..) |param, i| {
            const idx: c_int = @intCast(i);
            rc = if (param) |p|
                c.sqlite3_bind_text(stmt.?, idx, p.ptr, @intCast(p.len), SQLITE_STATIC)
            else
                c.sqlite3_bind_null(stmt.?, idx);
            if (rc != c.SQLITE_OK) {
                _ = c.sqlite3_finalize(stmt);
                return error.PrepareFailed;
            }
        }

        return stmt.?;
    }

    /// Prepare a statement, bind text parameters (1-indexed), step, and finalize.
    /// Use for INSERT/UPDATE/DELETE with user-supplied text values.
    /// Returns ConstraintViolation for UNIQUE/FK violations.
    pub fn execParams(self: *Db, sql: [*:0]const u8, params: []const ?[]const u8) SqliteError!void {
        const stmt = try self.prepareAndBind(sql, params);
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return;
        if (rc == c.SQLITE_CONSTRAINT) return error.ConstraintViolation;
        return error.StepFailed;
    }

    /// Returns the number of rows modified by the last INSERT/UPDATE/DELETE.
    pub fn changes(self: *Db) i32 {
        return c.sqlite3_changes(self.handle);
    }

    /// Query a single text column from a single row, with text parameter bindings.
    /// Returns null if no rows match. Caller must free the returned slice.
    pub fn queryTextParams(self: *Db, allocator: std.mem.Allocator, sql: [*:0]const u8, params: []const ?[]const u8) (SqliteError || error{OutOfMemory})!?[]const u8 {
        const stmt = try self.prepareAndBind(sql, params);
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const ptr = c.sqlite3_column_text(stmt, 0);
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            if (ptr == null) return null;
            return try allocator.dupe(u8, ptr[0..len]);
        }
        if (rc == c.SQLITE_DONE) return null;
        return error.StepFailed;
    }

    /// Check if a row exists matching the given parameterized query.
    pub fn exists(self: *Db, sql: [*:0]const u8, params: []const ?[]const u8) SqliteError!bool {
        const stmt = try self.prepareAndBind(sql, params);
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.StepFailed;
    }

    /// Query all rows returning N text columns. Returns [][N][]const u8.
    /// Caller must call freeRows to release memory.
    pub fn queryRows(self: *Db, comptime N: usize, allocator: std.mem.Allocator, sql: [*:0]const u8, params: []const ?[]const u8) (SqliteError || error{OutOfMemory})![][N][]const u8 {
        const stmt = try self.prepareAndBind(sql, params);
        defer _ = c.sqlite3_finalize(stmt);

        var rows: std.ArrayList([N][]const u8) = .empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |col| allocator.free(col);
            }
            rows.deinit(allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;

            var row: [N][]const u8 = undefined;
            var ok: usize = 0;
            errdefer for (row[0..ok]) |col| allocator.free(col);

            inline for (0..N) |col_i| {
                const ptr = c.sqlite3_column_text(stmt, col_i);
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col_i));
                row[col_i] = if (ptr != null) try allocator.dupe(u8, ptr[0..len]) else try allocator.dupe(u8, "");
                ok += 1;
            }

            try rows.append(allocator, row);
        }

        return rows.toOwnedSlice(allocator);
    }

    /// Free rows returned by queryRows.
    pub fn freeRows(comptime N: usize, allocator: std.mem.Allocator, rows: [][N][]const u8) void {
        for (rows) |row| {
            for (row) |col| allocator.free(col);
        }
        allocator.free(rows);
    }

    /// Returns the current schema version, or null if _ken_meta doesn't exist.
    pub fn getVersion(self: *Db) SqliteError!?u32 {
        const has_meta = try self.queryInt(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='_ken_meta' LIMIT 1;",
        );
        if (has_meta == null) return null;
        return self.readVersion();
    }

    /// Read version from _ken_meta, assuming the table exists.
    fn readVersion(self: *Db) SqliteError!?u32 {
        const val = try self.queryInt(
            "SELECT CAST(value AS INTEGER) FROM _ken_meta WHERE key='" ++ meta_key_version ++ "';",
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

        // Table is guaranteed to exist, skip sqlite_master check.
        const current = try self.readVersion();
        const target: u32 = @intCast(migrations.len);

        if (current) |v| {
            // v is 0-indexed (version i means migrations 0..i have run),
            // so v+1 is the count of migrations already applied.
            if (v + 1 >= target) {
                if (v + 1 > target) return error.DatabaseAheadOfMigrations;
                return v;
            }
        }

        const start: u32 = if (current) |v| v + 1 else 0;

        for (start..target) |i| {
            try self.exec("BEGIN;");
            errdefer self.exec("ROLLBACK;") catch {};

            try self.exec(migrations[i]);

            var buf: [128]u8 = undefined;
            const update_sql = std.fmt.bufPrintZ(
                &buf,
                "INSERT OR REPLACE INTO _ken_meta (key, value) VALUES ('" ++ meta_key_version ++ "', '{d}');",
                .{i},
            ) catch unreachable;
            try self.exec(update_sql);
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

test "execParams: insert and query with bound text" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams(
        "INSERT INTO items (name, description) VALUES (?1, ?2);",
        &.{ "test-item", "a description" },
    );

    const val = try db.queryInt("SELECT COUNT(*) FROM items WHERE name='test-item';");
    try testing.expectEqual(@as(?i64, 1), val);
}

test "execParams: null parameter" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams(
        "INSERT INTO items (name, description) VALUES (?1, ?2);",
        &.{ "null-desc", null },
    );

    const val = try db.queryInt("SELECT COUNT(*) FROM items WHERE name='null-desc' AND description IS NULL;");
    try testing.expectEqual(@as(?i64, 1), val);
}

test "queryTextParams: returns matching text" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams(
        "INSERT INTO items (name, description) VALUES (?1, ?2);",
        &.{ "findme", "the description" },
    );

    const result = try db.queryTextParams(
        testing.allocator,
        "SELECT description FROM items WHERE name = ?1;",
        &.{"findme"},
    );
    defer if (result) |r| testing.allocator.free(r);
    try testing.expectEqualStrings("the description", result.?);
}

test "queryTextParams: returns null for no rows" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    const result = try db.queryTextParams(
        testing.allocator,
        "SELECT description FROM items WHERE name = ?1;",
        &.{"nonexistent"},
    );
    try testing.expect(result == null);
}

test "execParams: constraint violation on duplicate PK" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams(
        "INSERT INTO items (id, name) VALUES (?1, ?2);",
        &.{ "1", "first" },
    );

    const result = db.execParams(
        "INSERT INTO items (id, name) VALUES (?1, ?2);",
        &.{ "1", "duplicate" },
    );
    try testing.expectError(error.ConstraintViolation, result);
}

test "execParams: constraint violation on DELETE RESTRICT" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams("INSERT INTO items (id, name) VALUES (?1, ?2);", &.{ "1", "item1" });
    try db.execParams("INSERT INTO tags (id, item_id, tag) VALUES (?1, ?2, ?3);", &.{ "1", "1", "tagged" });

    // Should fail because tag references item
    const result = db.execParams("DELETE FROM items WHERE id = ?1;", &.{"1"});
    try testing.expectError(error.ConstraintViolation, result);
}

test "queryRows: multi-row result" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams("INSERT INTO items (name, description) VALUES (?1, ?2);", &.{ "alpha", "first" });
    try db.execParams("INSERT INTO items (name, description) VALUES (?1, ?2);", &.{ "beta", "second" });

    const rows = try db.queryRows(
        2,
        testing.allocator,
        "SELECT name, description FROM items ORDER BY name;",
        &.{},
    );
    defer Db.freeRows(2, testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("alpha", rows[0][0]);
    try testing.expectEqualStrings("first", rows[0][1]);
    try testing.expectEqualStrings("beta", rows[1][0]);
    try testing.expectEqualStrings("second", rows[1][1]);
}

test "queryRows: empty result" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    const rows = try db.queryRows(
        2,
        testing.allocator,
        "SELECT name, description FROM items ORDER BY name;",
        &.{},
    );
    defer Db.freeRows(2, testing.allocator, rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "queryRows: 4 columns" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams("INSERT INTO items (id, name, description) VALUES (?1, ?2, ?3);", &.{ "1", "alpha", "first" });
    try db.execParams("INSERT INTO tags (id, item_id, tag) VALUES (?1, ?2, ?3);", &.{ "10", "1", "cool" });
    try db.execParams("INSERT INTO items (id, name, description) VALUES (?1, ?2, ?3);", &.{ "2", "beta", "second" });
    try db.execParams("INSERT INTO tags (id, item_id, tag) VALUES (?1, ?2, ?3);", &.{ "20", "2", "neat" });

    const rows = try db.queryRows(
        4,
        testing.allocator,
        "SELECT i.id, i.name, i.description, t.tag FROM items i JOIN tags t ON t.item_id = i.id ORDER BY i.name;",
        &.{},
    );
    defer Db.freeRows(4, testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("1", rows[0][0]);
    try testing.expectEqualStrings("alpha", rows[0][1]);
    try testing.expectEqualStrings("first", rows[0][2]);
    try testing.expectEqualStrings("cool", rows[0][3]);
    try testing.expectEqualStrings("2", rows[1][0]);
    try testing.expectEqualStrings("beta", rows[1][1]);
    try testing.expectEqualStrings("second", rows[1][2]);
    try testing.expectEqualStrings("neat", rows[1][3]);
}

test "queryRows: 1 column" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams("INSERT INTO items (name) VALUES (?1);", &.{"alpha"});
    try db.execParams("INSERT INTO items (name) VALUES (?1);", &.{"beta"});

    const rows = try db.queryRows(
        1,
        testing.allocator,
        "SELECT name FROM items ORDER BY name;",
        &.{},
    );
    defer Db.freeRows(1, testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("alpha", rows[0][0]);
    try testing.expectEqualStrings("beta", rows[1][0]);
}

test "queryRows: null columns become empty strings" {
    var db = try Db.open(":memory:");
    defer db.close();

    _ = try db.migrate(toy_migrations);

    try db.execParams("INSERT INTO items (name, description) VALUES (?1, ?2);", &.{ "no-desc", null });

    const rows = try db.queryRows(
        2,
        testing.allocator,
        "SELECT name, description FROM items;",
        &.{},
    );
    defer Db.freeRows(2, testing.allocator, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("no-desc", rows[0][0]);
    try testing.expectEqualStrings("", rows[0][1]);
}

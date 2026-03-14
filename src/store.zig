const std = @import("std");
const log = std.log.scoped(.store);
const ids = @import("ids.zig");
const domain = @import("domain.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const HealthStats = struct {
    tasks_by_stage: []StageCount,
    active_leases: i64,

    pub const StageCount = struct {
        stage: []const u8,
        count: i64,
    };
};

pub const PipelineRow = struct {
    id: []const u8,
    name: []const u8,
    definition_json: []const u8,
    created_at_ms: i64,
};

pub const TaskRow = struct {
    id: []const u8,
    pipeline_id: []const u8,
    stage: []const u8,
    title: []const u8,
    description: []const u8,
    priority: i64,
    metadata_json: []const u8,
    task_version: i64,
    next_eligible_at_ms: i64,
    max_attempts: ?i64,
    retry_delay_ms: i64,
    dead_letter_stage: ?[]const u8,
    dead_letter_reason: ?[]const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const RunRow = struct {
    id: []const u8,
    task_id: []const u8,
    attempt: i64,
    status: []const u8,
    agent_id: ?[]const u8,
    agent_role: ?[]const u8,
    started_at_ms: ?i64,
    ended_at_ms: ?i64,
    usage_json: []const u8,
    error_text: ?[]const u8,
};

pub const EventRow = struct {
    id: i64,
    run_id: []const u8,
    ts_ms: i64,
    kind: []const u8,
    data_json: []const u8,
};

pub const ArtifactRow = struct {
    id: []const u8,
    task_id: ?[]const u8,
    run_id: ?[]const u8,
    created_at_ms: i64,
    kind: []const u8,
    uri: []const u8,
    sha256_hex: ?[]const u8,
    size_bytes: ?i64,
    meta_json: []const u8,
};

pub const DependencyRow = struct {
    depends_on_task_id: []const u8,
    resolved: bool,
};

pub const AssignmentRow = struct {
    task_id: []const u8,
    agent_id: []const u8,
    assigned_by: ?[]const u8,
    active: bool,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const IdempotencyRow = struct {
    request_hash: [32]u8,
    response_status: i64,
    response_body: []const u8,
    created_at_ms: i64,
};

pub const StoreEntry = struct {
    namespace: []const u8,
    key: []const u8,
    value_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const QueueRoleStats = struct {
    role: []const u8,
    claimable_count: i64,
    oldest_claimable_age_ms: ?i64,
    failed_count: i64,
    stuck_count: i64,
    near_expiry_leases: i64,
};

pub const TaskPage = struct {
    items: []TaskRow,
    next_cursor: ?[]const u8,
};

pub const EventPage = struct {
    items: []EventRow,
    next_cursor: ?[]const u8,
};

pub const ArtifactPage = struct {
    items: []ArtifactRow,
    next_cursor: ?[]const u8,
};

pub const ClaimResult = struct {
    task: TaskRow,
    run: RunRow,
    lease_id: []const u8,
    lease_token: []const u8,
    expires_at_ms: i64,
};

pub const TransitionResult = struct {
    previous_stage: []const u8,
    new_stage: []const u8,
    trigger: []const u8,
};

pub const OtlpSpanInsert = struct {
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8 = null,
    name: []const u8,
    kind: ?[]const u8 = null,
    start_time_unix_nano: ?i64 = null,
    end_time_unix_nano: ?i64 = null,
    status_code: ?[]const u8 = null,
    status_message: ?[]const u8 = null,
    attributes_json: []const u8,
    resource_attributes_json: []const u8,
    scope_name: ?[]const u8 = null,
    scope_version: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    raw_json: []const u8,
};

pub const Store = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        if (db) |d| {
            _ = c.sqlite3_busy_timeout(d, 5000);
        }

        var self_ = Self{ .db = db, .allocator = allocator };
        self_.configurePragmas();
        try self_.migrate();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) void {
        const pragmas = [_][*:0]const u8{
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA foreign_keys = ON;",
            "PRAGMA busy_timeout = 5000;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA cache_size = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            const rc = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (rc != c.SQLITE_OK) {
                if (err_msg) |msg| {
                    log.warn("pragma failed (rc={d}): {s}", .{ rc, std.mem.span(msg) });
                    c.sqlite3_free(msg);
                }
            }
        }
    }

    fn migrate(self: *Self) !void {
        const sql = @embedFile("migrations/001_init.sql");
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration failed (rc={d}): {s}", .{ rc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }

        try self.ensureColumn(
            "tasks",
            "task_version",
            "ALTER TABLE tasks ADD COLUMN task_version INTEGER NOT NULL DEFAULT 1;",
        );
        try self.ensureColumn(
            "tasks",
            "next_eligible_at_ms",
            "ALTER TABLE tasks ADD COLUMN next_eligible_at_ms INTEGER NOT NULL DEFAULT 0;",
        );
        try self.ensureColumn(
            "tasks",
            "max_attempts",
            "ALTER TABLE tasks ADD COLUMN max_attempts INTEGER;",
        );
        try self.ensureColumn(
            "tasks",
            "retry_delay_ms",
            "ALTER TABLE tasks ADD COLUMN retry_delay_ms INTEGER NOT NULL DEFAULT 0;",
        );
        try self.ensureColumn(
            "tasks",
            "dead_letter_stage",
            "ALTER TABLE tasks ADD COLUMN dead_letter_stage TEXT;",
        );
        try self.ensureColumn(
            "tasks",
            "dead_letter_reason",
            "ALTER TABLE tasks ADD COLUMN dead_letter_reason TEXT;",
        );

        try self.execSimple("CREATE INDEX IF NOT EXISTS idx_tasks_next_eligible ON tasks(next_eligible_at_ms);");
        try self.execSimple("CREATE INDEX IF NOT EXISTS idx_tasks_dead_letter_reason ON tasks(dead_letter_reason);");

        // Migration 002: orchestration columns + drop gate_results
        try self.ensureColumn(
            "tasks",
            "run_id",
            "ALTER TABLE tasks ADD COLUMN run_id TEXT;",
        );
        try self.ensureColumn(
            "tasks",
            "workflow_state_json",
            "ALTER TABLE tasks ADD COLUMN workflow_state_json TEXT;",
        );
        try self.execSimple("DROP TABLE IF EXISTS gate_results;");

        // Migration 003: store table
        {
            const store_sql = @embedFile("migrations/003_store.sql");
            var store_err: [*c]u8 = null;
            const store_rc = c.sqlite3_exec(self.db, store_sql.ptr, null, null, &store_err);
            if (store_rc != c.SQLITE_OK) {
                if (store_err) |msg| {
                    log.err("migration 003 failed (rc={d}): {s}", .{ store_rc, std.mem.span(msg) });
                    c.sqlite3_free(msg);
                }
                return error.MigrationFailed;
            }
        }

        // Migration 004: store FTS5 full-text search
        {
            const fts_sql = @embedFile("migrations/004_store_fts.sql");
            var fts_err: [*c]u8 = null;
            const fts_rc = c.sqlite3_exec(self.db, fts_sql.ptr, null, null, &fts_err);
            if (fts_rc != c.SQLITE_OK) {
                if (fts_err) |msg| {
                    log.err("migration 004 failed (rc={d}): {s}", .{ fts_rc, std.mem.span(msg) });
                    c.sqlite3_free(msg);
                }
                return error.MigrationFailed;
            }
        }

        try self.execSimple(
            "CREATE TABLE IF NOT EXISTS pipeline_stage_roles (" ++
                "pipeline_id TEXT NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE," ++
                "stage TEXT NOT NULL," ++
                "agent_role TEXT NOT NULL," ++
                "PRIMARY KEY (pipeline_id, stage)" ++
                ");",
        );
        try self.execSimple("CREATE INDEX IF NOT EXISTS idx_pipeline_stage_roles_role_stage ON pipeline_stage_roles(agent_role, stage);");
        try self.execSimple("CREATE INDEX IF NOT EXISTS idx_pipeline_stage_roles_pipeline ON pipeline_stage_roles(pipeline_id);");
        try self.rebuildPipelineStageRoles();
    }

    fn ensureColumn(self: *Self, table_name: []const u8, column_name: []const u8, alter_sql: [*:0]const u8) !void {
        var pragma_buf: [128]u8 = undefined;
        const pragma_sql = std.fmt.bufPrintZ(&pragma_buf, "PRAGMA table_info({s});", .{table_name}) catch return error.PrepareFailed;
        const stmt = try self.prepare(pragma_sql);
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const col_name = self.colTextView(stmt, 1);
            if (std.mem.eql(u8, col_name, column_name)) return;
        }

        try self.execSimple(alter_sql);
    }

    // ===== Health =====

    pub fn getHealthStats(self: *Self) !HealthStats {
        var stage_counts: std.ArrayListUnmanaged(HealthStats.StageCount) = .empty;

        const stage_sql = "SELECT stage, COUNT(*) FROM tasks GROUP BY stage ORDER BY stage;";
        var stage_stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, stage_sql, -1, &stage_stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stage_stmt);

        while (c.sqlite3_step(stage_stmt) == c.SQLITE_ROW) {
            const stage_ptr = c.sqlite3_column_text(stage_stmt, 0);
            const count = c.sqlite3_column_int64(stage_stmt, 1);
            if (stage_ptr) |ptr| {
                const stage_name = try self.allocator.dupe(u8, std.mem.span(ptr));
                errdefer self.allocator.free(stage_name);
                try stage_counts.append(self.allocator, .{ .stage = stage_name, .count = count });
            }
        }

        const lease_sql = "SELECT COUNT(*) FROM leases WHERE expires_at_ms > ?;";
        var lease_stmt: ?*c.sqlite3_stmt = null;
        const now_ms: i64 = std.time.milliTimestamp();
        rc = c.sqlite3_prepare_v2(self.db, lease_sql, -1, &lease_stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(lease_stmt);

        _ = c.sqlite3_bind_int64(lease_stmt, 1, now_ms);
        var active_leases: i64 = 0;
        if (c.sqlite3_step(lease_stmt) == c.SQLITE_ROW) {
            active_leases = c.sqlite3_column_int64(lease_stmt, 0);
        }

        return .{
            .tasks_by_stage = try stage_counts.toOwnedSlice(self.allocator),
            .active_leases = active_leases,
        };
    }

    pub fn freeHealthStats(self: *Self, stats: *HealthStats) void {
        for (stats.tasks_by_stage) |sc| {
            self.allocator.free(sc.stage);
        }
        self.allocator.free(stats.tasks_by_stage);
    }

    // ===== Pipelines =====

    pub fn createPipeline(self: *Self, name: []const u8, definition_json: []const u8) ![]const u8 {
        // Validate the pipeline definition
        var validation_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer validation_arena.deinit();
        const parsed = domain.parseAndValidate(validation_arena.allocator(), definition_json) catch |err| {
            log.err("pipeline validation failed: {s}", .{domain.validationErrorMessage(err)});
            return error.ValidationFailed;
        };
        const definition = parsed.value;

        const id_arr = ids.generateId();
        const id = try self.allocator.dupe(u8, &id_arr);
        errdefer self.allocator.free(id);
        const now_ms = ids.nowMs();

        try self.execSimple("BEGIN IMMEDIATE;");
        errdefer self.execSimple("ROLLBACK;") catch {};

        const stmt = try self.prepare("INSERT INTO pipelines (id, name, definition_json, created_at_ms) VALUES (?, ?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);

        self.bindText(stmt, 1, id);
        self.bindText(stmt, 2, name);
        self.bindText(stmt, 3, definition_json);
        _ = c.sqlite3_bind_int64(stmt, 4, now_ms);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            const err_msg = self.lastError();
            if (std.mem.indexOf(u8, err_msg, "UNIQUE") != null) {
                return error.DuplicateName;
            }
            return error.InsertFailed;
        }

        try self.replacePipelineStageRoles(id, definition);
        try self.execSimple("COMMIT;");
        return id;
    }

    pub fn getPipeline(self: *Self, id: []const u8) !?PipelineRow {
        const stmt = try self.prepare("SELECT id, name, definition_json, created_at_ms FROM pipelines WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.readPipelineRow(stmt);
    }

    pub fn listPipelines(self: *Self) ![]PipelineRow {
        const stmt = try self.prepare("SELECT id, name, definition_json, created_at_ms FROM pipelines ORDER BY created_at_ms DESC;");
        defer _ = c.sqlite3_finalize(stmt);

        var results: std.ArrayListUnmanaged(PipelineRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(self.allocator, self.readPipelineRow(stmt));
        }
        return results.toOwnedSlice(self.allocator);
    }

    fn readPipelineRow(self: *Self, stmt: *c.sqlite3_stmt) PipelineRow {
        return .{
            .id = self.colText(stmt, 0),
            .name = self.colText(stmt, 1),
            .definition_json = self.colText(stmt, 2),
            .created_at_ms = c.sqlite3_column_int64(stmt, 3),
        };
    }

    // ===== Tasks =====

    pub fn createTask(
        self: *Self,
        pipeline_id: []const u8,
        title: []const u8,
        description: []const u8,
        priority: i64,
        metadata_json: []const u8,
        max_attempts: ?i64,
        retry_delay_ms: i64,
        dead_letter_stage: ?[]const u8,
    ) ![]const u8 {
        // Verify pipeline exists and get initial stage
        const pipeline = try self.getPipeline(pipeline_id) orelse return error.PipelineNotFound;
        defer self.freePipelineRow(pipeline);

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();
        var parsed = domain.parseAndValidate(parse_arena.allocator(), pipeline.definition_json) catch return error.InvalidPipeline;
        defer parsed.deinit();
        const def = parsed.value;

        const id_arr = ids.generateId();
        const id = try self.allocator.dupe(u8, &id_arr);
        errdefer self.allocator.free(id);
        const now_ms = ids.nowMs();

        const stmt = try self.prepare(
            "INSERT INTO tasks (id, pipeline_id, stage, title, description, priority, metadata_json, task_version, next_eligible_at_ms, max_attempts, retry_delay_ms, dead_letter_stage, dead_letter_reason, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, NULL, ?, ?);",
        );
        defer _ = c.sqlite3_finalize(stmt);

        self.bindText(stmt, 1, id);
        self.bindText(stmt, 2, pipeline_id);
        self.bindText(stmt, 3, def.initial);
        self.bindText(stmt, 4, title);
        self.bindText(stmt, 5, description);
        _ = c.sqlite3_bind_int64(stmt, 6, priority);
        self.bindText(stmt, 7, metadata_json);
        if (max_attempts) |val| _ = c.sqlite3_bind_int64(stmt, 8, val) else _ = c.sqlite3_bind_null(stmt, 8);
        _ = c.sqlite3_bind_int64(stmt, 9, retry_delay_ms);
        if (dead_letter_stage) |stage| self.bindText(stmt, 10, stage) else _ = c.sqlite3_bind_null(stmt, 10);
        _ = c.sqlite3_bind_int64(stmt, 11, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 12, now_ms);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;

        return id;
    }

    pub fn getTask(self: *Self, id: []const u8) !?TaskRow {
        const stmt = try self.prepare("SELECT id, pipeline_id, stage, title, description, priority, metadata_json, task_version, next_eligible_at_ms, max_attempts, retry_delay_ms, dead_letter_stage, dead_letter_reason, created_at_ms, updated_at_ms FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.readTaskRow(stmt);
    }

    pub fn getLatestRun(self: *Self, task_id: []const u8) !?RunRow {
        const stmt = try self.prepare("SELECT id, task_id, attempt, status, agent_id, agent_role, started_at_ms, ended_at_ms, usage_json, error_text FROM runs WHERE task_id = ? ORDER BY attempt DESC LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.readRunRow(stmt);
    }

    pub fn addTaskDependency(self: *Self, task_id: []const u8, depends_on_task_id: []const u8) !void {
        if (std.mem.eql(u8, task_id, depends_on_task_id)) return error.InvalidDependency;

        // Validate both tasks exist.
        const exists_stmt = try self.prepare("SELECT COUNT(*) FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(exists_stmt);
        self.bindText(exists_stmt, 1, task_id);
        if (c.sqlite3_step(exists_stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(exists_stmt, 0) == 0) {
            return error.TaskNotFound;
        }

        const exists_dep_stmt = try self.prepare("SELECT COUNT(*) FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(exists_dep_stmt);
        self.bindText(exists_dep_stmt, 1, depends_on_task_id);
        if (c.sqlite3_step(exists_dep_stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(exists_dep_stmt, 0) == 0) {
            return error.DependencyTaskNotFound;
        }

        const stmt = try self.prepare("INSERT INTO task_dependencies (task_id, depends_on_task_id, created_at_ms) VALUES (?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);
        self.bindText(stmt, 2, depends_on_task_id);
        _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            const err_msg = self.lastError();
            if (std.mem.indexOf(u8, err_msg, "UNIQUE") != null) return error.DuplicateDependency;
            return error.InsertFailed;
        }
    }

    pub fn listTaskDependencies(self: *Self, task_id: []const u8) ![]DependencyRow {
        const stmt = try self.prepare(
            "SELECT d.depends_on_task_id, t.stage, p.definition_json FROM task_dependencies d JOIN tasks t ON t.id = d.depends_on_task_id JOIN pipelines p ON p.id = t.pipeline_id WHERE d.task_id = ? ORDER BY d.created_at_ms ASC;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        var results: std.ArrayListUnmanaged(DependencyRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const dep_id = self.colTextView(stmt, 0);
            const dep_stage = self.colTextView(stmt, 1);
            const dep_def_json = self.colTextView(stmt, 2);
            var parsed = domain.parseAndValidate(temp_alloc, dep_def_json) catch return error.InvalidPipeline;
            defer parsed.deinit();
            try results.append(self.allocator, .{
                .depends_on_task_id = try self.allocator.dupe(u8, dep_id),
                .resolved = domain.isTerminal(parsed.value, dep_stage),
            });
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn assignTask(self: *Self, task_id: []const u8, agent_id: []const u8, assigned_by: ?[]const u8) !void {
        const now_ms = ids.nowMs();

        const task_stmt = try self.prepare("SELECT COUNT(*) FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(task_stmt);
        self.bindText(task_stmt, 1, task_id);
        if (c.sqlite3_step(task_stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(task_stmt, 0) == 0) return error.TaskNotFound;

        // Keep assignment optional but single-active-per-task for deterministic ownership.
        const deactivate = try self.prepare("UPDATE task_assignments SET active = 0, updated_at_ms = ? WHERE task_id = ?;");
        defer _ = c.sqlite3_finalize(deactivate);
        _ = c.sqlite3_bind_int64(deactivate, 1, now_ms);
        self.bindText(deactivate, 2, task_id);
        _ = c.sqlite3_step(deactivate);

        const upsert = try self.prepare(
            "INSERT INTO task_assignments (task_id, agent_id, assigned_by, active, created_at_ms, updated_at_ms) VALUES (?, ?, ?, 1, ?, ?) ON CONFLICT(task_id, agent_id) DO UPDATE SET assigned_by = excluded.assigned_by, active = 1, updated_at_ms = excluded.updated_at_ms;",
        );
        defer _ = c.sqlite3_finalize(upsert);
        self.bindText(upsert, 1, task_id);
        self.bindText(upsert, 2, agent_id);
        if (assigned_by) |value| self.bindText(upsert, 3, value) else _ = c.sqlite3_bind_null(upsert, 3);
        _ = c.sqlite3_bind_int64(upsert, 4, now_ms);
        _ = c.sqlite3_bind_int64(upsert, 5, now_ms);
        if (c.sqlite3_step(upsert) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn unassignTask(self: *Self, task_id: []const u8, agent_id: []const u8) !bool {
        const stmt = try self.prepare("UPDATE task_assignments SET active = 0, updated_at_ms = ? WHERE task_id = ? AND agent_id = ? AND active = 1;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, ids.nowMs());
        self.bindText(stmt, 2, task_id);
        self.bindText(stmt, 3, agent_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn listTaskAssignments(self: *Self, task_id: []const u8) ![]AssignmentRow {
        const stmt = try self.prepare("SELECT task_id, agent_id, assigned_by, active, created_at_ms, updated_at_ms FROM task_assignments WHERE task_id = ? ORDER BY created_at_ms ASC;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        var results: std.ArrayListUnmanaged(AssignmentRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(self.allocator, .{
                .task_id = self.colText(stmt, 0),
                .agent_id = self.colText(stmt, 1),
                .assigned_by = self.colTextNullable(stmt, 2),
                .active = c.sqlite3_column_int64(stmt, 3) != 0,
                .created_at_ms = c.sqlite3_column_int64(stmt, 4),
                .updated_at_ms = c.sqlite3_column_int64(stmt, 5),
            });
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn listTasksPage(self: *Self, stage_filter: ?[]const u8, pipeline_id_filter: ?[]const u8, cursor_created_at_ms: ?i64, cursor_id: ?[]const u8, limit: i64) !TaskPage {
        const page_limit: usize = @intCast(limit);
        var sql_buf: [1024]u8 = undefined;
        var sql_len: usize = 0;
        const base = "SELECT id, pipeline_id, stage, title, description, priority, metadata_json, task_version, next_eligible_at_ms, max_attempts, retry_delay_ms, dead_letter_stage, dead_letter_reason, created_at_ms, updated_at_ms FROM tasks";
        @memcpy(sql_buf[0..base.len], base);
        sql_len = base.len;

        var has_where = false;
        if (stage_filter != null) {
            const clause = " WHERE stage = ?";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }
        if (pipeline_id_filter != null) {
            const clause = if (has_where) " AND pipeline_id = ?" else " WHERE pipeline_id = ?";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }
        if (cursor_created_at_ms != null and cursor_id != null) {
            const clause = if (has_where) " AND (created_at_ms > ? OR (created_at_ms = ? AND id > ?))" else " WHERE (created_at_ms > ? OR (created_at_ms = ? AND id > ?))";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }

        const order = " ORDER BY created_at_ms ASC, id ASC LIMIT ?;";
        @memcpy(sql_buf[sql_len..][0..order.len], order);
        sql_len += order.len;
        sql_buf[sql_len] = 0;
        const sql_z: [*:0]const u8 = @ptrCast(sql_buf[0..sql_len :0]);

        const stmt = try self.prepare(sql_z);
        defer _ = c.sqlite3_finalize(stmt);

        var bind_idx: c_int = 1;
        if (stage_filter) |sf| {
            self.bindText(stmt, bind_idx, sf);
            bind_idx += 1;
        }
        if (pipeline_id_filter) |pf| {
            self.bindText(stmt, bind_idx, pf);
            bind_idx += 1;
        }
        if (cursor_created_at_ms) |v| {
            _ = c.sqlite3_bind_int64(stmt, bind_idx, v);
            bind_idx += 1;
            _ = c.sqlite3_bind_int64(stmt, bind_idx, v);
            bind_idx += 1;
            self.bindText(stmt, bind_idx, cursor_id.?);
            bind_idx += 1;
        }
        _ = c.sqlite3_bind_int64(stmt, bind_idx, limit + 1);

        var rows: std.ArrayListUnmanaged(TaskRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(self.allocator, self.readTaskRow(stmt));
        }

        var next_cursor: ?[]const u8 = null;
        if (rows.items.len > page_limit) {
            const cursor_row = rows.items[page_limit];
            next_cursor = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ cursor_row.created_at_ms, cursor_row.id });
            self.freeTaskRow(cursor_row);
            _ = rows.orderedRemove(page_limit);
        }

        return .{
            .items = try rows.toOwnedSlice(self.allocator),
            .next_cursor = next_cursor,
        };
    }

    pub fn listEventsPage(self: *Self, run_id: []const u8, cursor_id: ?i64, limit: i64) !EventPage {
        const page_limit: usize = @intCast(limit);
        const sql = if (cursor_id != null)
            "SELECT id, run_id, ts_ms, kind, data_json FROM events WHERE run_id = ? AND id > ? ORDER BY id ASC LIMIT ?;"
        else
            "SELECT id, run_id, ts_ms, kind, data_json FROM events WHERE run_id = ? ORDER BY id ASC LIMIT ?;";

        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        var bind_idx: c_int = 1;
        self.bindText(stmt, bind_idx, run_id);
        bind_idx += 1;
        if (cursor_id) |v| {
            _ = c.sqlite3_bind_int64(stmt, bind_idx, v);
            bind_idx += 1;
        }
        _ = c.sqlite3_bind_int64(stmt, bind_idx, limit + 1);

        var rows: std.ArrayListUnmanaged(EventRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(self.allocator, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .run_id = self.colText(stmt, 1),
                .ts_ms = c.sqlite3_column_int64(stmt, 2),
                .kind = self.colText(stmt, 3),
                .data_json = self.colText(stmt, 4),
            });
        }

        var next_cursor: ?[]const u8 = null;
        if (rows.items.len > page_limit) {
            const cursor_row = rows.items[page_limit];
            next_cursor = try std.fmt.allocPrint(self.allocator, "{d}", .{cursor_row.id});
            self.allocator.free(cursor_row.run_id);
            self.allocator.free(cursor_row.kind);
            self.allocator.free(cursor_row.data_json);
            _ = rows.orderedRemove(page_limit);
        }

        return .{
            .items = try rows.toOwnedSlice(self.allocator),
            .next_cursor = next_cursor,
        };
    }

    fn readTaskRow(self: *Self, stmt: *c.sqlite3_stmt) TaskRow {
        return .{
            .id = self.colText(stmt, 0),
            .pipeline_id = self.colText(stmt, 1),
            .stage = self.colText(stmt, 2),
            .title = self.colText(stmt, 3),
            .description = self.colText(stmt, 4),
            .priority = c.sqlite3_column_int64(stmt, 5),
            .metadata_json = self.colText(stmt, 6),
            .task_version = c.sqlite3_column_int64(stmt, 7),
            .next_eligible_at_ms = c.sqlite3_column_int64(stmt, 8),
            .max_attempts = self.colInt64Nullable(stmt, 9),
            .retry_delay_ms = c.sqlite3_column_int64(stmt, 10),
            .dead_letter_stage = self.colTextNullable(stmt, 11),
            .dead_letter_reason = self.colTextNullable(stmt, 12),
            .created_at_ms = c.sqlite3_column_int64(stmt, 13),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 14),
        };
    }

    fn readRunRow(self: *Self, stmt: *c.sqlite3_stmt) RunRow {
        return .{
            .id = self.colText(stmt, 0),
            .task_id = self.colText(stmt, 1),
            .attempt = c.sqlite3_column_int64(stmt, 2),
            .status = self.colText(stmt, 3),
            .agent_id = self.colTextNullable(stmt, 4),
            .agent_role = self.colTextNullable(stmt, 5),
            .started_at_ms = self.colInt64Nullable(stmt, 6),
            .ended_at_ms = self.colInt64Nullable(stmt, 7),
            .usage_json = self.colText(stmt, 8),
            .error_text = self.colTextNullable(stmt, 9),
        };
    }

    // ===== Claim + Lease =====

    pub fn claimTask(self: *Self, agent_id: []const u8, agent_role: []const u8, lease_ttl_ms: i64, per_state_concurrency: ?std.json.Value) !?ClaimResult {
        // BEGIN IMMEDIATE to prevent double-claim
        try self.execSimple("BEGIN IMMEDIATE;");
        errdefer self.execSimple("ROLLBACK;") catch {};

        const now_ms = ids.nowMs();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        // Janitor: expire stale leases
        {
            const stmt = try self.prepare("SELECT l.id, l.run_id FROM leases l WHERE l.expires_at_ms <= ?;");
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, now_ms);

            var stale_lease_ids: std.ArrayListUnmanaged([]const u8) = .empty;
            var stale_run_ids: std.ArrayListUnmanaged([]const u8) = .empty;
            var seen_stale_runs = std.StringHashMap(void).init(temp_alloc);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                try stale_lease_ids.append(temp_alloc, try temp_alloc.dupe(u8, self.colTextView(stmt, 0)));
                const run_id = try temp_alloc.dupe(u8, self.colTextView(stmt, 1));
                if (!seen_stale_runs.contains(run_id)) {
                    try seen_stale_runs.put(run_id, {});
                    try stale_run_ids.append(temp_alloc, run_id);
                }
            }

            if (stale_run_ids.items.len > 0) {
                const upd = try self.prepare("UPDATE runs SET status = 'stale', ended_at_ms = ? WHERE id = ?;");
                defer _ = c.sqlite3_finalize(upd);
                for (stale_run_ids.items) |run_id| {
                    _ = c.sqlite3_reset(upd);
                    _ = c.sqlite3_clear_bindings(upd);
                    _ = c.sqlite3_bind_int64(upd, 1, now_ms);
                    self.bindText(upd, 2, run_id);
                    _ = c.sqlite3_step(upd);
                }
            }
            if (stale_lease_ids.items.len > 0) {
                const del = try self.prepare("DELETE FROM leases WHERE id = ?;");
                defer _ = c.sqlite3_finalize(del);
                for (stale_lease_ids.items) |lease_id| {
                    _ = c.sqlite3_reset(del);
                    _ = c.sqlite3_clear_bindings(del);
                    self.bindText(del, 1, lease_id);
                    _ = c.sqlite3_step(del);
                }
            }
        }

        const RoleStage = struct {
            pipeline_id: []const u8,
            stage: []const u8,
        };

        // Find pipeline+stage pairs matching this role.
        var role_stages: std.ArrayListUnmanaged(RoleStage) = .empty;
        {
            const pstmt = try self.prepare("SELECT pipeline_id, stage FROM pipeline_stage_roles WHERE agent_role = ? ORDER BY pipeline_id, stage;");
            defer _ = c.sqlite3_finalize(pstmt);
            self.bindText(pstmt, 1, agent_role);
            while (c.sqlite3_step(pstmt) == c.SQLITE_ROW) {
                try role_stages.append(temp_alloc, .{
                    .pipeline_id = try temp_alloc.dupe(u8, self.colTextView(pstmt, 0)),
                    .stage = try temp_alloc.dupe(u8, self.colTextView(pstmt, 1)),
                });
            }
        }

        if (role_stages.items.len == 0) {
            try self.execSimple("COMMIT;");
            return null;
        }

        // Find task: stage matches, no active lease, ordered by priority
        var task_row: ?TaskRow = null;
        const find_sql = "SELECT t.id, t.pipeline_id, t.stage, t.title, t.description, t.priority, t.metadata_json, t.task_version, t.next_eligible_at_ms, t.max_attempts, t.retry_delay_ms, t.dead_letter_stage, t.dead_letter_reason, t.created_at_ms, t.updated_at_ms FROM tasks t WHERE t.pipeline_id = ? AND t.stage = ? AND t.dead_letter_reason IS NULL AND t.next_eligible_at_ms <= ? AND NOT EXISTS (SELECT 1 FROM leases l JOIN runs r ON l.run_id = r.id WHERE r.task_id = t.id AND l.expires_at_ms > ?) ORDER BY t.priority DESC, t.created_at_ms ASC LIMIT 20;";
        const fstmt = try self.prepare(find_sql);
        defer _ = c.sqlite3_finalize(fstmt);
        for (role_stages.items) |role_stage| {
            _ = c.sqlite3_reset(fstmt);
            _ = c.sqlite3_clear_bindings(fstmt);
            self.bindText(fstmt, 1, role_stage.pipeline_id);
            self.bindText(fstmt, 2, role_stage.stage);
            _ = c.sqlite3_bind_int64(fstmt, 3, now_ms);
            _ = c.sqlite3_bind_int64(fstmt, 4, now_ms);

            while (c.sqlite3_step(fstmt) == c.SQLITE_ROW) {
                const candidate = try self.readTaskRowAlloc(temp_alloc, fstmt);
                if (!(try self.isTaskDependenciesSatisfied(candidate.id)) or !(try self.isTaskAssignableToAgent(candidate.id, agent_id))) {
                    continue;
                }

                // Per-state concurrency check
                if (per_state_concurrency) |psc| {
                    if (psc == .object) {
                        if (psc.object.get(candidate.stage)) |limit_val| {
                            const limit: i64 = switch (limit_val) {
                                .integer => |v| v,
                                .float => |v| @intFromFloat(v),
                                else => 0,
                            };
                            if (limit > 0) {
                                const leased_count = try self.countLeasedTasksInState(candidate.stage, now_ms);
                                if (leased_count >= limit) continue;
                            }
                        }
                    }
                }

                if (task_row) |existing| {
                    if (candidate.priority > existing.priority or
                        (candidate.priority == existing.priority and candidate.created_at_ms < existing.created_at_ms))
                    {
                        task_row = candidate;
                    }
                } else {
                    task_row = candidate;
                }
            }
        }

        const task_tmp = task_row orelse {
            try self.execSimple("COMMIT;");
            return null;
        };
        const task = try self.dupeTaskRow(task_tmp);
        errdefer self.freeTaskRow(task);

        // Get max attempt
        var max_attempt: i64 = 0;
        {
            const astmt = try self.prepare("SELECT COALESCE(MAX(attempt), 0) FROM runs WHERE task_id = ?;");
            defer _ = c.sqlite3_finalize(astmt);
            self.bindText(astmt, 1, task.id);
            if (c.sqlite3_step(astmt) == c.SQLITE_ROW) {
                max_attempt = c.sqlite3_column_int64(astmt, 0);
            }
        }

        // Create run
        const run_id_arr = ids.generateId();
        const run_id = try self.allocator.dupe(u8, &run_id_arr);
        errdefer self.allocator.free(run_id);
        const attempt = max_attempt + 1;
        {
            const rstmt = try self.prepare("INSERT INTO runs (id, task_id, attempt, status, agent_id, agent_role, started_at_ms) VALUES (?, ?, ?, 'running', ?, ?, ?);");
            defer _ = c.sqlite3_finalize(rstmt);
            self.bindText(rstmt, 1, run_id);
            self.bindText(rstmt, 2, task.id);
            _ = c.sqlite3_bind_int64(rstmt, 3, attempt);
            self.bindText(rstmt, 4, agent_id);
            self.bindText(rstmt, 5, agent_role);
            _ = c.sqlite3_bind_int64(rstmt, 6, now_ms);
            if (c.sqlite3_step(rstmt) != c.SQLITE_DONE) return error.InsertFailed;
        }

        // Create lease
        const lease_id_arr = ids.generateId();
        const lease_id = try self.allocator.dupe(u8, &lease_id_arr);
        errdefer self.allocator.free(lease_id);
        const token_hex_arr = ids.generateToken();
        const token_hex = try self.allocator.dupe(u8, &token_hex_arr);
        errdefer self.allocator.free(token_hex);
        var token_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&token_bytes, token_hex) catch return error.InvalidToken;
        const token_hash = ids.hashBytes(&token_bytes);
        const expires_at_ms = now_ms + lease_ttl_ms;
        {
            const lstmt = try self.prepare("INSERT INTO leases (id, run_id, agent_id, token_hash, expires_at_ms, last_heartbeat_ms) VALUES (?, ?, ?, ?, ?, ?);");
            defer _ = c.sqlite3_finalize(lstmt);
            self.bindText(lstmt, 1, lease_id);
            self.bindText(lstmt, 2, run_id);
            self.bindText(lstmt, 3, agent_id);
            _ = c.sqlite3_bind_blob(lstmt, 4, &token_hash, @intCast(token_hash.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(lstmt, 5, expires_at_ms);
            _ = c.sqlite3_bind_int64(lstmt, 6, now_ms);
            if (c.sqlite3_step(lstmt) != c.SQLITE_DONE) return error.InsertFailed;
        }

        try self.execSimple("COMMIT;");

        return .{
            .task = task,
            .run = .{
                .id = run_id,
                .task_id = task.id,
                .attempt = attempt,
                .status = "running",
                .agent_id = agent_id,
                .agent_role = agent_role,
                .started_at_ms = now_ms,
                .ended_at_ms = null,
                .usage_json = "{}",
                .error_text = null,
            },
            .lease_id = lease_id,
            .lease_token = token_hex,
            .expires_at_ms = expires_at_ms,
        };
    }

    pub fn heartbeat(self: *Self, lease_id: []const u8, token_hex: []const u8, extend_ms: i64) !i64 {
        // Hash the token and compare
        var token_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&token_bytes, token_hex) catch return error.InvalidToken;
        const token_hash = ids.hashBytes(&token_bytes);

        const stmt = try self.prepare("SELECT token_hash, expires_at_ms FROM leases WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, lease_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.LeaseNotFound;

        const stored_hash_ptr = c.sqlite3_column_blob(stmt, 0);
        const stored_hash_len = c.sqlite3_column_bytes(stmt, 0);
        if (stored_hash_ptr == null or stored_hash_len != @as(c_int, @intCast(token_hash.len))) return error.InvalidLease;

        const stored_hash = @as([*]const u8, @ptrCast(stored_hash_ptr.?))[0..@as(usize, @intCast(stored_hash_len))];
        if (!std.mem.eql(u8, token_hash[0..], stored_hash)) return error.InvalidToken;

        const expires = c.sqlite3_column_int64(stmt, 1);
        const now_ms = ids.nowMs();
        if (expires <= now_ms) return error.LeaseExpired;

        // Extend lease
        const new_expires = now_ms + extend_ms;
        const upd = try self.prepare("UPDATE leases SET expires_at_ms = ?, last_heartbeat_ms = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(upd);
        _ = c.sqlite3_bind_int64(upd, 1, new_expires);
        _ = c.sqlite3_bind_int64(upd, 2, now_ms);
        self.bindText(upd, 3, lease_id);
        _ = c.sqlite3_step(upd);

        return new_expires;
    }

    fn isTaskDependenciesSatisfied(self: *Self, task_id: []const u8) !bool {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        const stmt = try self.prepare(
            "SELECT t.stage, p.definition_json FROM task_dependencies d JOIN tasks t ON t.id = d.depends_on_task_id JOIN pipelines p ON p.id = t.pipeline_id WHERE d.task_id = ?;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const dep_stage = self.colTextView(stmt, 0);
            const def_json = self.colTextView(stmt, 1);
            var parsed = domain.parseAndValidate(temp_alloc, def_json) catch return false;
            defer parsed.deinit();
            if (!domain.isTerminal(parsed.value, dep_stage)) return false;
        }

        return true;
    }

    fn isTaskAssignableToAgent(self: *Self, task_id: []const u8, agent_id: []const u8) !bool {
        const stmt = try self.prepare("SELECT agent_id FROM task_assignments WHERE task_id = ? AND active = 1;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        var has_active_assignment = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            has_active_assignment = true;
            const assigned_agent = self.colTextView(stmt, 0);
            if (std.mem.eql(u8, assigned_agent, agent_id)) return true;
        }

        return !has_active_assignment;
    }

    fn countLeasedTasksInState(self: *Self, state: []const u8, now_ms: i64) !i64 {
        const stmt = try self.prepare(
            "SELECT COUNT(*) FROM tasks t WHERE t.stage = ? AND EXISTS (SELECT 1 FROM leases l JOIN runs r ON l.run_id = r.id WHERE r.task_id = t.id AND l.expires_at_ms > ?);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, state);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_int64(stmt, 0);
        }
        return 0;
    }

    pub fn validateLeaseByRunId(self: *Self, run_id: []const u8, token_hex: []const u8) !void {
        var token_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&token_bytes, token_hex) catch return error.InvalidToken;
        const token_hash = ids.hashBytes(&token_bytes);

        const stmt = try self.prepare("SELECT token_hash, expires_at_ms FROM leases WHERE run_id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, run_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.LeaseNotFound;

        const stored_hash_ptr = c.sqlite3_column_blob(stmt, 0);
        const stored_hash_len = c.sqlite3_column_bytes(stmt, 0);
        if (stored_hash_ptr == null or stored_hash_len != @as(c_int, @intCast(token_hash.len))) return error.InvalidLease;

        const stored_hash = @as([*]const u8, @ptrCast(stored_hash_ptr.?))[0..@as(usize, @intCast(stored_hash_len))];
        if (!std.mem.eql(u8, token_hash[0..], stored_hash)) return error.InvalidToken;

        const expires = c.sqlite3_column_int64(stmt, 1);
        if (expires <= ids.nowMs()) return error.LeaseExpired;
    }

    // ===== Events =====

    pub fn addEvent(self: *Self, run_id: []const u8, kind: []const u8, data_json: []const u8) !i64 {
        const stmt = try self.prepare("INSERT INTO events (run_id, ts_ms, kind, data_json) VALUES (?, ?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, run_id);
        _ = c.sqlite3_bind_int64(stmt, 2, ids.nowMs());
        self.bindText(stmt, 3, kind);
        self.bindText(stmt, 4, data_json);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    // ===== Transition =====

    pub fn transitionRun(
        self: *Self,
        run_id: []const u8,
        trigger: []const u8,
        instructions: ?[]const u8,
        usage_json: ?[]const u8,
        expected_stage: ?[]const u8,
        expected_task_version: ?i64,
    ) !TransitionResult {
        try self.execSimple("BEGIN IMMEDIATE;");
        errdefer self.execSimple("ROLLBACK;") catch {};

        const now_ms = ids.nowMs();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        // Load run
        const run_stmt = try self.prepare("SELECT task_id, status FROM runs WHERE id = ?;");
        defer _ = c.sqlite3_finalize(run_stmt);
        self.bindText(run_stmt, 1, run_id);
        if (c.sqlite3_step(run_stmt) != c.SQLITE_ROW) return error.RunNotFound;
        const task_id = try temp_alloc.dupe(u8, self.colTextView(run_stmt, 0));
        const run_status = self.colTextView(run_stmt, 1);
        if (!std.mem.eql(u8, run_status, "running")) return error.RunNotRunning;

        // Load task
        const task_stmt = try self.prepare("SELECT pipeline_id, stage, task_version FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(task_stmt);
        self.bindText(task_stmt, 1, task_id);
        if (c.sqlite3_step(task_stmt) != c.SQLITE_ROW) return error.TaskNotFound;
        const pipeline_id = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 0));
        const current_stage = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 1));
        const current_task_version = c.sqlite3_column_int64(task_stmt, 2);

        if (expected_stage) |value| {
            if (!std.mem.eql(u8, value, current_stage)) return error.ExpectedStageMismatch;
        }
        if (expected_task_version) |value| {
            if (value != current_task_version) return error.TaskVersionMismatch;
        }

        // Load pipeline
        const pip_stmt = try self.prepare("SELECT definition_json FROM pipelines WHERE id = ?;");
        defer _ = c.sqlite3_finalize(pip_stmt);
        self.bindText(pip_stmt, 1, pipeline_id);
        if (c.sqlite3_step(pip_stmt) != c.SQLITE_ROW) return error.PipelineNotFound;
        const def_json = self.colTextView(pip_stmt, 0);

        var parsed = domain.parseAndValidate(temp_alloc, def_json) catch return error.InvalidPipeline;
        defer parsed.deinit();
        const transition = domain.findTransition(parsed.value, current_stage, trigger) orelse return error.InvalidTransition;

        // Update run
        {
            const upd = try self.prepare("UPDATE runs SET status = 'completed', ended_at_ms = ?, usage_json = ? WHERE id = ?;");
            defer _ = c.sqlite3_finalize(upd);
            _ = c.sqlite3_bind_int64(upd, 1, now_ms);
            self.bindText(upd, 2, usage_json orelse "{}");
            self.bindText(upd, 3, run_id);
            _ = c.sqlite3_step(upd);
        }

        // Update task stage
        {
            const upd = try self.prepare("UPDATE tasks SET stage = ?, task_version = task_version + 1, dead_letter_reason = NULL, next_eligible_at_ms = 0, updated_at_ms = ? WHERE id = ?;");
            defer _ = c.sqlite3_finalize(upd);
            self.bindText(upd, 1, transition.to);
            _ = c.sqlite3_bind_int64(upd, 2, now_ms);
            self.bindText(upd, 3, task_id);
            _ = c.sqlite3_step(upd);
        }

        // Delete lease
        {
            const del = try self.prepare("DELETE FROM leases WHERE run_id = ?;");
            defer _ = c.sqlite3_finalize(del);
            self.bindText(del, 1, run_id);
            _ = c.sqlite3_step(del);
        }

        // Insert transition event
        {
            const instr = instructions orelse transition.instructions orelse "";
            const event_data = std.json.Stringify.valueAlloc(temp_alloc, .{
                .trigger = trigger,
                .from = current_stage,
                .to = transition.to,
                .instructions = instr,
            }, .{}) catch return error.InsertFailed;
            const evt = try self.prepare("INSERT INTO events (run_id, ts_ms, kind, data_json) VALUES (?, ?, 'transition', ?);");
            defer _ = c.sqlite3_finalize(evt);
            self.bindText(evt, 1, run_id);
            _ = c.sqlite3_bind_int64(evt, 2, now_ms);
            self.bindText(evt, 3, event_data);
            _ = c.sqlite3_step(evt);
        }

        try self.execSimple("COMMIT;");

        return .{
            .previous_stage = try self.allocator.dupe(u8, current_stage),
            .new_stage = try self.allocator.dupe(u8, transition.to),
            .trigger = try self.allocator.dupe(u8, trigger),
        };
    }

    // ===== Fail =====

    pub fn failRun(self: *Self, run_id: []const u8, error_text: []const u8, usage_json: ?[]const u8) !void {
        try self.execSimple("BEGIN IMMEDIATE;");
        errdefer self.execSimple("ROLLBACK;") catch {};

        const now_ms = ids.nowMs();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        // Load run
        const run_stmt = try self.prepare("SELECT task_id, status FROM runs WHERE id = ?;");
        defer _ = c.sqlite3_finalize(run_stmt);
        self.bindText(run_stmt, 1, run_id);
        if (c.sqlite3_step(run_stmt) != c.SQLITE_ROW) return error.RunNotFound;
        const task_id = try temp_alloc.dupe(u8, self.colTextView(run_stmt, 0));

        // Update run
        {
            const upd = try self.prepare("UPDATE runs SET status = 'failed', ended_at_ms = ?, error_text = ?, usage_json = ? WHERE id = ?;");
            defer _ = c.sqlite3_finalize(upd);
            _ = c.sqlite3_bind_int64(upd, 1, now_ms);
            self.bindText(upd, 2, error_text);
            self.bindText(upd, 3, usage_json orelse "{}");
            self.bindText(upd, 4, run_id);
            _ = c.sqlite3_step(upd);
        }

        // Delete lease
        {
            const del = try self.prepare("DELETE FROM leases WHERE run_id = ?;");
            defer _ = c.sqlite3_finalize(del);
            self.bindText(del, 1, run_id);
            _ = c.sqlite3_step(del);
        }

        // Retry policy and dead-letter handling
        {
            const task_stmt = try self.prepare("SELECT pipeline_id, stage, max_attempts, retry_delay_ms, dead_letter_stage FROM tasks WHERE id = ?;");
            defer _ = c.sqlite3_finalize(task_stmt);
            self.bindText(task_stmt, 1, task_id);
            if (c.sqlite3_step(task_stmt) != c.SQLITE_ROW) return error.TaskNotFound;

            const pipeline_id = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 0));
            const current_stage = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 1));
            const max_attempts = self.colInt64Nullable(task_stmt, 2);
            const retry_delay_ms = c.sqlite3_column_int64(task_stmt, 3);
            const dead_letter_stage = if (c.sqlite3_column_type(task_stmt, 4) == c.SQLITE_NULL) null else try temp_alloc.dupe(u8, self.colTextView(task_stmt, 4));

            const cnt_stmt = try self.prepare("SELECT COUNT(*) FROM runs WHERE task_id = ? AND status = 'failed';");
            defer _ = c.sqlite3_finalize(cnt_stmt);
            self.bindText(cnt_stmt, 1, task_id);
            var fail_count: i64 = 0;
            if (c.sqlite3_step(cnt_stmt) == c.SQLITE_ROW) {
                fail_count = c.sqlite3_column_int64(cnt_stmt, 0);
            }

            const exhausted = if (max_attempts) |limit| fail_count >= limit else false;
            if (exhausted) {
                var dead_stage_to_use: ?[]const u8 = null;
                if (dead_letter_stage) |candidate| {
                    const pip_stmt = try self.prepare("SELECT definition_json FROM pipelines WHERE id = ?;");
                    defer _ = c.sqlite3_finalize(pip_stmt);
                    self.bindText(pip_stmt, 1, pipeline_id);
                    if (c.sqlite3_step(pip_stmt) == c.SQLITE_ROW) {
                        const def_json = self.colTextView(pip_stmt, 0);
                        const parsed = domain.parseAndValidate(temp_alloc, def_json) catch null;
                        if (parsed) |parsed_value| {
                            var p = parsed_value;
                            defer p.deinit();
                            if (p.value.states.map.contains(candidate)) {
                                dead_stage_to_use = candidate;
                            }
                        }
                    }
                }

                const impossible_retry_ts: i64 = 9_223_372_036_854_775_000;
                if (dead_stage_to_use) |stage| {
                    const upd = try self.prepare("UPDATE tasks SET stage = ?, task_version = task_version + 1, dead_letter_reason = 'max_attempts_exceeded', next_eligible_at_ms = ?, updated_at_ms = ? WHERE id = ?;");
                    defer _ = c.sqlite3_finalize(upd);
                    self.bindText(upd, 1, stage);
                    _ = c.sqlite3_bind_int64(upd, 2, impossible_retry_ts);
                    _ = c.sqlite3_bind_int64(upd, 3, now_ms);
                    self.bindText(upd, 4, task_id);
                    _ = c.sqlite3_step(upd);
                } else {
                    const upd = try self.prepare("UPDATE tasks SET dead_letter_reason = 'max_attempts_exceeded', next_eligible_at_ms = ?, updated_at_ms = ? WHERE id = ?;");
                    defer _ = c.sqlite3_finalize(upd);
                    _ = c.sqlite3_bind_int64(upd, 1, impossible_retry_ts);
                    _ = c.sqlite3_bind_int64(upd, 2, now_ms);
                    self.bindText(upd, 3, task_id);
                    _ = c.sqlite3_step(upd);
                }

                const evt_data = std.json.Stringify.valueAlloc(temp_alloc, .{
                    .reason = "max_attempts_exceeded",
                    .failed_attempts = fail_count,
                    .from_stage = current_stage,
                    .dead_letter_stage = dead_stage_to_use,
                }, .{}) catch return error.InsertFailed;
                const evt = try self.prepare("INSERT INTO events (run_id, ts_ms, kind, data_json) VALUES (?, ?, 'dead_letter', ?);");
                defer _ = c.sqlite3_finalize(evt);
                self.bindText(evt, 1, run_id);
                _ = c.sqlite3_bind_int64(evt, 2, now_ms);
                self.bindText(evt, 3, evt_data);
                _ = c.sqlite3_step(evt);
            } else {
                const next_eligible_at_ms = now_ms + retry_delay_ms;
                const upd = try self.prepare("UPDATE tasks SET next_eligible_at_ms = ?, updated_at_ms = ? WHERE id = ?;");
                defer _ = c.sqlite3_finalize(upd);
                _ = c.sqlite3_bind_int64(upd, 1, next_eligible_at_ms);
                _ = c.sqlite3_bind_int64(upd, 2, now_ms);
                self.bindText(upd, 3, task_id);
                _ = c.sqlite3_step(upd);

                const evt_data = std.json.Stringify.valueAlloc(temp_alloc, .{
                    .reason = "retry_scheduled",
                    .failed_attempts = fail_count,
                    .retry_delay_ms = retry_delay_ms,
                    .next_eligible_at_ms = next_eligible_at_ms,
                }, .{}) catch return error.InsertFailed;
                const evt = try self.prepare("INSERT INTO events (run_id, ts_ms, kind, data_json) VALUES (?, ?, 'retry_scheduled', ?);");
                defer _ = c.sqlite3_finalize(evt);
                self.bindText(evt, 1, run_id);
                _ = c.sqlite3_bind_int64(evt, 2, now_ms);
                self.bindText(evt, 3, evt_data);
                _ = c.sqlite3_step(evt);
            }
        }

        try self.execSimple("COMMIT;");
    }

    pub fn freeOwnedString(self: *Self, value: []const u8) void {
        self.allocator.free(value);
    }

    pub fn freePipelineRow(self: *Self, row: PipelineRow) void {
        self.allocator.free(row.id);
        self.allocator.free(row.name);
        self.allocator.free(row.definition_json);
    }

    pub fn freePipelineRows(self: *Self, rows: []PipelineRow) void {
        for (rows) |row| self.freePipelineRow(row);
        self.allocator.free(rows);
    }

    pub fn freeTaskRow(self: *Self, row: TaskRow) void {
        self.allocator.free(row.id);
        self.allocator.free(row.pipeline_id);
        self.allocator.free(row.stage);
        self.allocator.free(row.title);
        self.allocator.free(row.description);
        self.allocator.free(row.metadata_json);
        if (row.dead_letter_stage) |stage| self.allocator.free(stage);
        if (row.dead_letter_reason) |reason| self.allocator.free(reason);
    }

    pub fn freeTaskRows(self: *Self, rows: []TaskRow) void {
        for (rows) |row| self.freeTaskRow(row);
        self.allocator.free(rows);
    }

    pub fn freeRunRow(self: *Self, row: RunRow) void {
        self.allocator.free(row.id);
        self.allocator.free(row.task_id);
        self.allocator.free(row.status);
        if (row.agent_id) |agent_id| self.allocator.free(agent_id);
        if (row.agent_role) |agent_role| self.allocator.free(agent_role);
        self.allocator.free(row.usage_json);
        if (row.error_text) |error_text| self.allocator.free(error_text);
    }

    pub fn freeClaimResult(self: *Self, claim: ClaimResult) void {
        self.freeTaskRow(claim.task);
        self.allocator.free(claim.run.id);
        self.allocator.free(claim.lease_id);
        self.allocator.free(claim.lease_token);
    }

    pub fn freeTransitionResult(self: *Self, transition: TransitionResult) void {
        self.allocator.free(transition.previous_stage);
        self.allocator.free(transition.new_stage);
        self.allocator.free(transition.trigger);
    }

    pub fn freeEventRows(self: *Self, rows: []EventRow) void {
        for (rows) |row| {
            self.allocator.free(row.run_id);
            self.allocator.free(row.kind);
            self.allocator.free(row.data_json);
        }
        self.allocator.free(rows);
    }

    pub fn freeArtifactRows(self: *Self, rows: []ArtifactRow) void {
        for (rows) |row| {
            self.allocator.free(row.id);
            if (row.task_id) |task_id| self.allocator.free(task_id);
            if (row.run_id) |run_id| self.allocator.free(run_id);
            self.allocator.free(row.kind);
            self.allocator.free(row.uri);
            if (row.sha256_hex) |sha256| self.allocator.free(sha256);
            self.allocator.free(row.meta_json);
        }
        self.allocator.free(rows);
    }

    pub fn freeDependencyRows(self: *Self, rows: []DependencyRow) void {
        for (rows) |row| {
            self.allocator.free(row.depends_on_task_id);
        }
        self.allocator.free(rows);
    }

    pub fn freeAssignmentRows(self: *Self, rows: []AssignmentRow) void {
        for (rows) |row| {
            self.allocator.free(row.task_id);
            self.allocator.free(row.agent_id);
            if (row.assigned_by) |assigned_by| self.allocator.free(assigned_by);
        }
        self.allocator.free(rows);
    }

    pub fn freeTaskPage(self: *Self, page: TaskPage) void {
        self.freeTaskRows(page.items);
        if (page.next_cursor) |cursor| self.allocator.free(cursor);
    }

    pub fn freeEventPage(self: *Self, page: EventPage) void {
        self.freeEventRows(page.items);
        if (page.next_cursor) |cursor| self.allocator.free(cursor);
    }

    pub fn freeArtifactPage(self: *Self, page: ArtifactPage) void {
        self.freeArtifactRows(page.items);
        if (page.next_cursor) |cursor| self.allocator.free(cursor);
    }

    pub fn freeQueueRoleStats(self: *Self, rows: []QueueRoleStats) void {
        for (rows) |row| self.allocator.free(row.role);
        self.allocator.free(rows);
    }

    pub fn freeIdempotencyRow(self: *Self, row: IdempotencyRow) void {
        self.allocator.free(row.response_body);
    }

    // ===== OpenTelemetry =====

    pub fn addOtlpBatchJson(self: *Self, content_type: []const u8, payload_json: []const u8, parsed_spans: i64) !i64 {
        const stmt = try self.prepare("INSERT INTO otlp_batches (received_at_ms, content_type, payload_json, parsed_spans) VALUES (?, ?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, ids.nowMs());
        self.bindText(stmt, 2, content_type);
        self.bindText(stmt, 3, payload_json);
        _ = c.sqlite3_bind_int64(stmt, 4, parsed_spans);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn addOtlpBatchBlob(self: *Self, content_type: []const u8, payload_blob: []const u8) !i64 {
        const stmt = try self.prepare("INSERT INTO otlp_batches (received_at_ms, content_type, payload_blob, parsed_spans) VALUES (?, ?, ?, 0);");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, ids.nowMs());
        self.bindText(stmt, 2, content_type);
        _ = c.sqlite3_bind_blob(stmt, 3, payload_blob.ptr, @intCast(payload_blob.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn updateOtlpBatchParsedSpans(self: *Self, batch_id: i64, parsed_spans: i64) !void {
        const stmt = try self.prepare("UPDATE otlp_batches SET parsed_spans = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, parsed_spans);
        _ = c.sqlite3_bind_int64(stmt, 2, batch_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    }

    pub fn addOtlpSpan(self: *Self, batch_id: i64, span: OtlpSpanInsert) !void {
        const stmt = try self.prepare(
            "INSERT INTO otlp_spans (batch_id, trace_id, span_id, parent_span_id, name, kind, start_time_unix_nano, end_time_unix_nano, status_code, status_message, attributes_json, resource_attributes_json, scope_name, scope_version, run_id, task_id, raw_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
        );
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, batch_id);
        self.bindText(stmt, 2, span.trace_id);
        self.bindText(stmt, 3, span.span_id);
        if (span.parent_span_id) |v| self.bindText(stmt, 4, v) else _ = c.sqlite3_bind_null(stmt, 4);
        self.bindText(stmt, 5, span.name);
        if (span.kind) |v| self.bindText(stmt, 6, v) else _ = c.sqlite3_bind_null(stmt, 6);
        if (span.start_time_unix_nano) |v| _ = c.sqlite3_bind_int64(stmt, 7, v) else _ = c.sqlite3_bind_null(stmt, 7);
        if (span.end_time_unix_nano) |v| _ = c.sqlite3_bind_int64(stmt, 8, v) else _ = c.sqlite3_bind_null(stmt, 8);
        if (span.status_code) |v| self.bindText(stmt, 9, v) else _ = c.sqlite3_bind_null(stmt, 9);
        if (span.status_message) |v| self.bindText(stmt, 10, v) else _ = c.sqlite3_bind_null(stmt, 10);
        self.bindText(stmt, 11, span.attributes_json);
        self.bindText(stmt, 12, span.resource_attributes_json);
        if (span.scope_name) |v| self.bindText(stmt, 13, v) else _ = c.sqlite3_bind_null(stmt, 13);
        if (span.scope_version) |v| self.bindText(stmt, 14, v) else _ = c.sqlite3_bind_null(stmt, 14);
        if (span.run_id) |v| self.bindText(stmt, 15, v) else _ = c.sqlite3_bind_null(stmt, 15);
        if (span.task_id) |v| self.bindText(stmt, 16, v) else _ = c.sqlite3_bind_null(stmt, 16);
        self.bindText(stmt, 17, span.raw_json);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    // ===== Artifacts =====

    pub fn addArtifact(self: *Self, task_id: ?[]const u8, run_id: ?[]const u8, kind: []const u8, uri: []const u8, sha256_hex: ?[]const u8, size_bytes: ?i64, meta_json: []const u8) ![]const u8 {
        const id_arr = ids.generateId();
        const id = try self.allocator.dupe(u8, &id_arr);
        errdefer self.allocator.free(id);
        const now_ms = ids.nowMs();

        const stmt = try self.prepare("INSERT INTO artifacts (id, task_id, run_id, created_at_ms, kind, uri, sha256_hex, size_bytes, meta_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);

        self.bindText(stmt, 1, id);
        if (task_id) |tid| self.bindText(stmt, 2, tid) else _ = c.sqlite3_bind_null(stmt, 2);
        if (run_id) |rid| self.bindText(stmt, 3, rid) else _ = c.sqlite3_bind_null(stmt, 3);
        _ = c.sqlite3_bind_int64(stmt, 4, now_ms);
        self.bindText(stmt, 5, kind);
        self.bindText(stmt, 6, uri);
        if (sha256_hex) |s| self.bindText(stmt, 7, s) else _ = c.sqlite3_bind_null(stmt, 7);
        if (size_bytes) |sb| _ = c.sqlite3_bind_int64(stmt, 8, sb) else _ = c.sqlite3_bind_null(stmt, 8);
        self.bindText(stmt, 9, meta_json);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
        return id;
    }

    pub fn listArtifactsPage(self: *Self, task_id: ?[]const u8, run_id: ?[]const u8, cursor_created_at_ms: ?i64, cursor_id: ?[]const u8, limit: i64) !ArtifactPage {
        const page_limit: usize = @intCast(limit);
        var sql_buf: [768]u8 = undefined;
        var sql_len: usize = 0;
        const base = "SELECT id, task_id, run_id, created_at_ms, kind, uri, sha256_hex, size_bytes, meta_json FROM artifacts";
        @memcpy(sql_buf[0..base.len], base);
        sql_len = base.len;

        var has_where = false;
        if (task_id != null) {
            const clause = " WHERE task_id = ?";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }
        if (run_id != null) {
            const clause = if (has_where) " AND run_id = ?" else " WHERE run_id = ?";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }
        if (cursor_created_at_ms != null and cursor_id != null) {
            const clause = if (has_where) " AND (created_at_ms > ? OR (created_at_ms = ? AND id > ?))" else " WHERE (created_at_ms > ? OR (created_at_ms = ? AND id > ?))";
            @memcpy(sql_buf[sql_len..][0..clause.len], clause);
            sql_len += clause.len;
            has_where = true;
        }

        const order = " ORDER BY created_at_ms ASC, id ASC LIMIT ?;";
        @memcpy(sql_buf[sql_len..][0..order.len], order);
        sql_len += order.len;
        sql_buf[sql_len] = 0;
        const sql_z: [*:0]const u8 = @ptrCast(sql_buf[0..sql_len :0]);

        const stmt = try self.prepare(sql_z);
        defer _ = c.sqlite3_finalize(stmt);

        var bind_idx: c_int = 1;
        if (task_id) |tid| {
            self.bindText(stmt, bind_idx, tid);
            bind_idx += 1;
        }
        if (run_id) |rid| {
            self.bindText(stmt, bind_idx, rid);
            bind_idx += 1;
        }
        if (cursor_created_at_ms) |v| {
            _ = c.sqlite3_bind_int64(stmt, bind_idx, v);
            bind_idx += 1;
            _ = c.sqlite3_bind_int64(stmt, bind_idx, v);
            bind_idx += 1;
            self.bindText(stmt, bind_idx, cursor_id.?);
            bind_idx += 1;
        }
        _ = c.sqlite3_bind_int64(stmt, bind_idx, limit + 1);

        var rows: std.ArrayListUnmanaged(ArtifactRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(self.allocator, .{
                .id = self.colText(stmt, 0),
                .task_id = self.colTextNullable(stmt, 1),
                .run_id = self.colTextNullable(stmt, 2),
                .created_at_ms = c.sqlite3_column_int64(stmt, 3),
                .kind = self.colText(stmt, 4),
                .uri = self.colText(stmt, 5),
                .sha256_hex = self.colTextNullable(stmt, 6),
                .size_bytes = self.colInt64Nullable(stmt, 7),
                .meta_json = self.colText(stmt, 8),
            });
        }

        var next_cursor: ?[]const u8 = null;
        if (rows.items.len > page_limit) {
            const cursor_row = rows.items[page_limit];
            next_cursor = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ cursor_row.created_at_ms, cursor_row.id });
            self.allocator.free(cursor_row.id);
            if (cursor_row.task_id) |v| self.allocator.free(v);
            if (cursor_row.run_id) |v| self.allocator.free(v);
            self.allocator.free(cursor_row.kind);
            self.allocator.free(cursor_row.uri);
            if (cursor_row.sha256_hex) |v| self.allocator.free(v);
            self.allocator.free(cursor_row.meta_json);
            _ = rows.orderedRemove(page_limit);
        }

        return .{
            .items = try rows.toOwnedSlice(self.allocator),
            .next_cursor = next_cursor,
        };
    }

    fn ensureRoleStatsIndex(self: *Self, roles: *std.ArrayListUnmanaged(QueueRoleStats), role: []const u8) !usize {
        for (roles.items, 0..) |row, i| {
            if (std.mem.eql(u8, row.role, role)) return i;
        }
        try roles.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .claimable_count = 0,
            .oldest_claimable_age_ms = null,
            .failed_count = 0,
            .stuck_count = 0,
            .near_expiry_leases = 0,
        });
        return roles.items.len - 1;
    }

    fn rebuildPipelineStageRoles(self: *Self) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const temp_alloc = scratch.allocator();

        const stmt = try self.prepare("SELECT id, definition_json FROM pipelines;");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const pipeline_id = self.colTextView(stmt, 0);
            const definition_json = self.colTextView(stmt, 1);
            var parsed = domain.parseAndValidate(temp_alloc, definition_json) catch {
                log.warn("skipping pipeline role index rebuild for invalid pipeline {s}", .{pipeline_id});
                continue;
            };
            defer parsed.deinit();
            try self.replacePipelineStageRoles(pipeline_id, parsed.value);
        }
    }

    fn replacePipelineStageRoles(self: *Self, pipeline_id: []const u8, def: domain.PipelineDefinition) !void {
        const delete_stmt = try self.prepare("DELETE FROM pipeline_stage_roles WHERE pipeline_id = ?;");
        defer _ = c.sqlite3_finalize(delete_stmt);
        self.bindText(delete_stmt, 1, pipeline_id);
        if (c.sqlite3_step(delete_stmt) != c.SQLITE_DONE) return error.DeleteFailed;

        const insert_stmt = try self.prepare("INSERT INTO pipeline_stage_roles (pipeline_id, stage, agent_role) VALUES (?, ?, ?);");
        defer _ = c.sqlite3_finalize(insert_stmt);

        var states_it = def.states.map.iterator();
        while (states_it.next()) |entry| {
            const agent_role = entry.value_ptr.agent_role orelse continue;
            _ = c.sqlite3_reset(insert_stmt);
            _ = c.sqlite3_clear_bindings(insert_stmt);
            self.bindText(insert_stmt, 1, pipeline_id);
            self.bindText(insert_stmt, 2, entry.key_ptr.*);
            self.bindText(insert_stmt, 3, agent_role);
            if (c.sqlite3_step(insert_stmt) != c.SQLITE_DONE) return error.InsertFailed;
        }
    }

    pub fn getIdempotency(self: *Self, key: []const u8, method: []const u8, path: []const u8) !?IdempotencyRow {
        const stmt = try self.prepare("SELECT request_hash, response_status, response_body, created_at_ms FROM idempotency_keys WHERE key = ? AND method = ? AND path = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, key);
        self.bindText(stmt, 2, method);
        self.bindText(stmt, 3, path);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        const hash_ptr = c.sqlite3_column_blob(stmt, 0);
        const hash_len = c.sqlite3_column_bytes(stmt, 0);
        if (hash_ptr == null or hash_len != 32) return error.InvalidHashLength;
        var request_hash: [32]u8 = undefined;
        @memcpy(request_hash[0..], @as([*]const u8, @ptrCast(hash_ptr.?))[0..32]);

        return .{
            .request_hash = request_hash,
            .response_status = c.sqlite3_column_int64(stmt, 1),
            .response_body = self.colText(stmt, 2),
            .created_at_ms = c.sqlite3_column_int64(stmt, 3),
        };
    }

    pub fn putIdempotency(self: *Self, key: []const u8, method: []const u8, path: []const u8, request_hash: [32]u8, response_status: i64, response_body: []const u8) !void {
        const stmt = try self.prepare(
            "INSERT INTO idempotency_keys (key, method, path, request_hash, response_status, response_body, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key, method, path) DO UPDATE SET request_hash = excluded.request_hash, response_status = excluded.response_status, response_body = excluded.response_body, created_at_ms = excluded.created_at_ms;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, key);
        self.bindText(stmt, 2, method);
        self.bindText(stmt, 3, path);
        _ = c.sqlite3_bind_blob(stmt, 4, &request_hash, @intCast(request_hash.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, response_status);
        self.bindText(stmt, 6, response_body);
        _ = c.sqlite3_bind_int64(stmt, 7, ids.nowMs());
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn getQueueRoleStats(self: *Self, near_expiry_window_ms: i64, stuck_window_ms: i64) ![]QueueRoleStats {
        var roles: std.ArrayListUnmanaged(QueueRoleStats) = .empty;
        const now_ms = ids.nowMs();

        const pipelines_stmt = try self.prepare("SELECT pipeline_id, stage, agent_role FROM pipeline_stage_roles ORDER BY pipeline_id, stage;");
        defer _ = c.sqlite3_finalize(pipelines_stmt);
        while (c.sqlite3_step(pipelines_stmt) == c.SQLITE_ROW) {
            const pipeline_id = self.colTextView(pipelines_stmt, 0);
            const stage = self.colTextView(pipelines_stmt, 1);
            const role = self.colTextView(pipelines_stmt, 2);
            const idx = try self.ensureRoleStatsIndex(&roles, role);

            const claimable_stmt = try self.prepare(
                "SELECT t.id, t.created_at_ms FROM tasks t WHERE t.pipeline_id = ? AND t.stage = ? AND t.dead_letter_reason IS NULL AND t.next_eligible_at_ms <= ? AND NOT EXISTS (SELECT 1 FROM leases l JOIN runs r ON l.run_id = r.id WHERE r.task_id = t.id AND l.expires_at_ms > ?) ORDER BY t.created_at_ms ASC;",
            );
            defer _ = c.sqlite3_finalize(claimable_stmt);
            self.bindText(claimable_stmt, 1, pipeline_id);
            self.bindText(claimable_stmt, 2, stage);
            _ = c.sqlite3_bind_int64(claimable_stmt, 3, now_ms);
            _ = c.sqlite3_bind_int64(claimable_stmt, 4, now_ms);
            while (c.sqlite3_step(claimable_stmt) == c.SQLITE_ROW) {
                const task_id = self.colTextView(claimable_stmt, 0);
                const created_at_ms = c.sqlite3_column_int64(claimable_stmt, 1);
                if (!(try self.isTaskDependenciesSatisfied(task_id))) continue;
                roles.items[idx].claimable_count += 1;
                const age = now_ms - created_at_ms;
                if (roles.items[idx].oldest_claimable_age_ms == null or age > roles.items[idx].oldest_claimable_age_ms.?) {
                    roles.items[idx].oldest_claimable_age_ms = age;
                }
            }

            const failed_stmt = try self.prepare("SELECT COUNT(*) FROM runs r JOIN tasks t ON t.id = r.task_id WHERE t.pipeline_id = ? AND t.stage = ? AND r.status = 'failed';");
            defer _ = c.sqlite3_finalize(failed_stmt);
            self.bindText(failed_stmt, 1, pipeline_id);
            self.bindText(failed_stmt, 2, stage);
            if (c.sqlite3_step(failed_stmt) == c.SQLITE_ROW) {
                roles.items[idx].failed_count += c.sqlite3_column_int64(failed_stmt, 0);
            }

            const stuck_stmt = try self.prepare(
                "SELECT COUNT(*) FROM runs r JOIN tasks t ON t.id = r.task_id WHERE t.pipeline_id = ? AND t.stage = ? AND r.status = 'running' AND r.started_at_ms <= ?;",
            );
            defer _ = c.sqlite3_finalize(stuck_stmt);
            self.bindText(stuck_stmt, 1, pipeline_id);
            self.bindText(stuck_stmt, 2, stage);
            _ = c.sqlite3_bind_int64(stuck_stmt, 3, now_ms - stuck_window_ms);
            if (c.sqlite3_step(stuck_stmt) == c.SQLITE_ROW) {
                roles.items[idx].stuck_count += c.sqlite3_column_int64(stuck_stmt, 0);
            }

            const lease_stmt = try self.prepare(
                "SELECT COUNT(*) FROM leases l JOIN runs r ON r.id = l.run_id JOIN tasks t ON t.id = r.task_id WHERE t.pipeline_id = ? AND t.stage = ? AND l.expires_at_ms > ? AND l.expires_at_ms <= ?;",
            );
            defer _ = c.sqlite3_finalize(lease_stmt);
            self.bindText(lease_stmt, 1, pipeline_id);
            self.bindText(lease_stmt, 2, stage);
            _ = c.sqlite3_bind_int64(lease_stmt, 3, now_ms);
            _ = c.sqlite3_bind_int64(lease_stmt, 4, now_ms + near_expiry_window_ms);
            if (c.sqlite3_step(lease_stmt) == c.SQLITE_ROW) {
                roles.items[idx].near_expiry_leases += c.sqlite3_column_int64(lease_stmt, 0);
            }
        }

        return roles.toOwnedSlice(self.allocator);
    }

    // ===== Store (KV) =====

    pub fn storePut(self: *Self, namespace: []const u8, key: []const u8, value_json: []const u8) !void {
        const now_ms = ids.nowMs();
        const stmt = try self.prepare(
            "INSERT INTO store (namespace, key, value_json, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT(namespace, key) DO UPDATE SET value_json = excluded.value_json, updated_at_ms = excluded.updated_at_ms;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, namespace);
        self.bindText(stmt, 2, key);
        self.bindText(stmt, 3, value_json);
        _ = c.sqlite3_bind_int64(stmt, 4, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 5, now_ms);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }

    pub fn storeGet(self: *Self, alloc: std.mem.Allocator, namespace: []const u8, key: []const u8) !?StoreEntry {
        const stmt = try self.prepare("SELECT namespace, key, value_json, created_at_ms, updated_at_ms FROM store WHERE namespace = ? AND key = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, namespace);
        self.bindText(stmt, 2, key);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .namespace = try alloc.dupe(u8, self.colTextView(stmt, 0)),
            .key = try alloc.dupe(u8, self.colTextView(stmt, 1)),
            .value_json = try alloc.dupe(u8, self.colTextView(stmt, 2)),
            .created_at_ms = c.sqlite3_column_int64(stmt, 3),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 4),
        };
    }

    pub fn storeList(self: *Self, alloc: std.mem.Allocator, namespace: []const u8) ![]StoreEntry {
        const stmt = try self.prepare("SELECT namespace, key, value_json, created_at_ms, updated_at_ms FROM store WHERE namespace = ? ORDER BY key;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, namespace);

        var results: std.ArrayListUnmanaged(StoreEntry) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(alloc, .{
                .namespace = try alloc.dupe(u8, self.colTextView(stmt, 0)),
                .key = try alloc.dupe(u8, self.colTextView(stmt, 1)),
                .value_json = try alloc.dupe(u8, self.colTextView(stmt, 2)),
                .created_at_ms = c.sqlite3_column_int64(stmt, 3),
                .updated_at_ms = c.sqlite3_column_int64(stmt, 4),
            });
        }
        return results.toOwnedSlice(alloc);
    }

    pub fn storeDelete(self: *Self, namespace: []const u8, key: []const u8) !void {
        const stmt = try self.prepare("DELETE FROM store WHERE namespace = ? AND key = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, namespace);
        self.bindText(stmt, 2, key);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
    }

    pub fn storeSearch(
        self: *Self,
        alloc: std.mem.Allocator,
        namespace: ?[]const u8,
        query: []const u8,
        limit: usize,
        filter_path: ?[]const u8,
        filter_value: ?[]const u8,
    ) ![]StoreEntry {
        const sql =
            "SELECT s.namespace, s.key, s.value_json, s.created_at_ms, s.updated_at_ms " ++
            "FROM store s " ++
            "JOIN store_fts f ON s.rowid = f.rowid " ++
            "WHERE store_fts MATCH ? " ++
            "AND (? IS NULL OR s.namespace = ?) " ++
            "AND (? IS NULL OR json_extract(s.value_json, ?) = ?) " ++
            "ORDER BY rank " ++
            "LIMIT ?;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        self.bindText(stmt, 1, query);
        if (namespace) |ns| {
            self.bindText(stmt, 2, ns);
            self.bindText(stmt, 3, ns);
        } else {
            _ = c.sqlite3_bind_null(stmt, 2);
            _ = c.sqlite3_bind_null(stmt, 3);
        }
        if (filter_path) |fp| {
            self.bindText(stmt, 4, fp);
            self.bindText(stmt, 5, fp);
            if (filter_value) |fv| {
                self.bindText(stmt, 6, fv);
            } else {
                _ = c.sqlite3_bind_null(stmt, 6);
            }
        } else {
            _ = c.sqlite3_bind_null(stmt, 4);
            _ = c.sqlite3_bind_null(stmt, 5);
            _ = c.sqlite3_bind_null(stmt, 6);
        }
        _ = c.sqlite3_bind_int64(stmt, 7, @intCast(limit));

        var results: std.ArrayListUnmanaged(StoreEntry) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(alloc, .{
                .namespace = try alloc.dupe(u8, self.colTextView(stmt, 0)),
                .key = try alloc.dupe(u8, self.colTextView(stmt, 1)),
                .value_json = try alloc.dupe(u8, self.colTextView(stmt, 2)),
                .created_at_ms = c.sqlite3_column_int64(stmt, 3),
                .updated_at_ms = c.sqlite3_column_int64(stmt, 4),
            });
        }
        return results.toOwnedSlice(alloc);
    }

    pub fn storeDeleteNamespace(self: *Self, namespace: []const u8) !void {
        const stmt = try self.prepare("DELETE FROM store WHERE namespace = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, namespace);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
    }

    pub fn freeStoreEntry(self: *Self, entry: StoreEntry) void {
        self.allocator.free(entry.namespace);
        self.allocator.free(entry.key);
        self.allocator.free(entry.value_json);
    }

    pub fn freeStoreEntries(self: *Self, entries: []StoreEntry) void {
        for (entries) |entry| self.freeStoreEntry(entry);
        self.allocator.free(entries);
    }

    // ===== Helpers =====

    pub fn execSimple(self: *Self, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("exec failed (rc={d}): {s}", .{ rc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.ExecFailed;
        }
    }

    pub fn prepare(self: *Self, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            if (self.db) |db| {
                log.err("prepare failed (rc={d}): {s}", .{ rc, std.mem.span(c.sqlite3_errmsg(db)) });
            }
            return error.PrepareFailed;
        }
        return stmt.?;
    }

    pub fn lastError(self: *Self) []const u8 {
        if (self.db) |db| {
            return std.mem.span(c.sqlite3_errmsg(db));
        }
        return "no database connection";
    }

    fn bindText(self: *Self, stmt: *c.sqlite3_stmt, col: c_int, text: []const u8) void {
        _ = self;
        _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), SQLITE_STATIC);
    }

    fn colTextView(_: *Self, stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return @as([*]const u8, @ptrCast(ptr.?))[0..len];
    }

    fn colText(self: *Self, stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        if (ptr) |p| {
            const span = std.mem.span(p);
            return self.allocator.dupe(u8, span) catch "";
        }
        return "";
    }

    fn colTextNullable(self: *Self, stmt: *c.sqlite3_stmt, col: c_int) ?[]const u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(stmt, col);
        if (ptr) |p| {
            return self.allocator.dupe(u8, std.mem.span(p)) catch null;
        }
        return null;
    }

    fn readTaskRowAlloc(self: *Self, allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !TaskRow {
        return .{
            .id = try allocator.dupe(u8, self.colTextView(stmt, 0)),
            .pipeline_id = try allocator.dupe(u8, self.colTextView(stmt, 1)),
            .stage = try allocator.dupe(u8, self.colTextView(stmt, 2)),
            .title = try allocator.dupe(u8, self.colTextView(stmt, 3)),
            .description = try allocator.dupe(u8, self.colTextView(stmt, 4)),
            .priority = c.sqlite3_column_int64(stmt, 5),
            .metadata_json = try allocator.dupe(u8, self.colTextView(stmt, 6)),
            .task_version = c.sqlite3_column_int64(stmt, 7),
            .next_eligible_at_ms = c.sqlite3_column_int64(stmt, 8),
            .max_attempts = self.colInt64Nullable(stmt, 9),
            .retry_delay_ms = c.sqlite3_column_int64(stmt, 10),
            .dead_letter_stage = if (c.sqlite3_column_type(stmt, 11) == c.SQLITE_NULL) null else try allocator.dupe(u8, self.colTextView(stmt, 11)),
            .dead_letter_reason = if (c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL) null else try allocator.dupe(u8, self.colTextView(stmt, 12)),
            .created_at_ms = c.sqlite3_column_int64(stmt, 13),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 14),
        };
    }

    fn dupeTaskRow(self: *Self, row: TaskRow) !TaskRow {
        return .{
            .id = try self.allocator.dupe(u8, row.id),
            .pipeline_id = try self.allocator.dupe(u8, row.pipeline_id),
            .stage = try self.allocator.dupe(u8, row.stage),
            .title = try self.allocator.dupe(u8, row.title),
            .description = try self.allocator.dupe(u8, row.description),
            .priority = row.priority,
            .metadata_json = try self.allocator.dupe(u8, row.metadata_json),
            .task_version = row.task_version,
            .next_eligible_at_ms = row.next_eligible_at_ms,
            .max_attempts = row.max_attempts,
            .retry_delay_ms = row.retry_delay_ms,
            .dead_letter_stage = if (row.dead_letter_stage) |v| try self.allocator.dupe(u8, v) else null,
            .dead_letter_reason = if (row.dead_letter_reason) |v| try self.allocator.dupe(u8, v) else null,
            .created_at_ms = row.created_at_ms,
            .updated_at_ms = row.updated_at_ms,
        };
    }

    fn colInt64Nullable(_: *Self, stmt: *c.sqlite3_stmt, col: c_int) ?i64 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(stmt, col);
    }

    // ===== Orchestration =====

    pub fn updateTaskRunId(self: *Self, task_id: []const u8, run_id: []const u8) !void {
        const stmt = try self.prepare("UPDATE tasks SET run_id = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, run_id);
        self.bindText(stmt, 2, task_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    }

    pub fn updateTaskWorkflowState(self: *Self, task_id: []const u8, state_json: []const u8) !void {
        const stmt = try self.prepare("UPDATE tasks SET workflow_state_json = ? WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, state_json);
        self.bindText(stmt, 2, task_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    }

    pub fn getTaskRunId(self: *Self, task_id: []const u8) !?[]const u8 {
        const stmt = try self.prepare("SELECT run_id FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.colTextNullable(stmt, 0);
    }
};

test "store CRUD" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    // Put + Get
    try store.storePut("ns1", "key1", "{\"x\":1}");
    const entry = (try store.storeGet(alloc, "ns1", "key1")).?;
    defer alloc.free(entry.namespace);
    defer alloc.free(entry.key);
    defer alloc.free(entry.value_json);
    try std.testing.expectEqualStrings("{\"x\":1}", entry.value_json);

    // Update (upsert preserves created_at_ms)
    try store.storePut("ns1", "key1", "{\"x\":2}");
    const entry2 = (try store.storeGet(alloc, "ns1", "key1")).?;
    defer alloc.free(entry2.namespace);
    defer alloc.free(entry2.key);
    defer alloc.free(entry2.value_json);
    try std.testing.expectEqualStrings("{\"x\":2}", entry2.value_json);
    try std.testing.expectEqual(entry.created_at_ms, entry2.created_at_ms);
    try std.testing.expect(entry2.updated_at_ms >= entry.updated_at_ms);

    // List
    const list = try store.storeList(alloc, "ns1");
    defer {
        for (list) |e| {
            alloc.free(e.namespace);
            alloc.free(e.key);
            alloc.free(e.value_json);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);

    // Delete
    try store.storeDelete("ns1", "key1");
    const gone = try store.storeGet(alloc, "ns1", "key1");
    try std.testing.expect(gone == null);

    // Delete namespace
    try store.storePut("ns2", "a", "1");
    try store.storePut("ns2", "b", "2");
    try store.storeDeleteNamespace("ns2");
    const ns2_list = try store.storeList(alloc, "ns2");
    defer alloc.free(ns2_list);
    try std.testing.expectEqual(@as(usize, 0), ns2_list.len);
}

test "store search" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    try store.storePut("docs", "readme", "{\"title\":\"Getting Started\",\"body\":\"Welcome to the project\"}");
    try store.storePut("docs", "api", "{\"title\":\"API Reference\",\"body\":\"Endpoints and methods\"}");
    try store.storePut("notes", "todo", "{\"title\":\"Todo List\",\"body\":\"Fix bugs and add features\"}");

    // Search across all namespaces
    const results = try store.storeSearch(alloc, null, "endpoints methods", 10, null, null);
    defer {
        for (results) |e| {
            alloc.free(e.namespace);
            alloc.free(e.key);
            alloc.free(e.value_json);
        }
        alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("api", results[0].key);

    // Search with namespace filter
    const ns_results = try store.storeSearch(alloc, "notes", "bugs features", 10, null, null);
    defer {
        for (ns_results) |e| {
            alloc.free(e.namespace);
            alloc.free(e.key);
            alloc.free(e.value_json);
        }
        alloc.free(ns_results);
    }
    try std.testing.expectEqual(@as(usize, 1), ns_results.len);
    try std.testing.expectEqualStrings("todo", ns_results[0].key);

    // Search with no results
    const empty_results = try store.storeSearch(alloc, null, "nonexistent_xyz", 10, null, null);
    defer alloc.free(empty_results);
    try std.testing.expectEqual(@as(usize, 0), empty_results.len);
}

test "task lifecycle: create, claim, event, transition" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    const pipeline_def =
        \\{"initial":"todo","states":{"todo":{"agent_role":"worker"},"done":{"terminal":true}},"transitions":[{"from":"todo","to":"done","trigger":"complete"}]}
    ;

    // Create pipeline
    const pipeline_id = try store.createPipeline("test-pipeline", pipeline_def);
    defer store.freeOwnedString(pipeline_id);

    // Create task
    const task_id = try store.createTask(pipeline_id, "Test Task", "A test task", 5, "{}", null, 0, null);
    defer store.freeOwnedString(task_id);

    // Verify task is in initial stage
    const task = (try store.getTask(task_id)).?;
    defer store.freeTaskRow(task);
    try std.testing.expectEqualStrings("todo", task.stage);
    try std.testing.expectEqual(@as(i64, 5), task.priority);

    // Claim task
    const claim = (try store.claimTask("agent-1", "worker", 300_000, null)).?;
    defer store.freeClaimResult(claim);
    try std.testing.expectEqualStrings(task_id, claim.task.id);
    try std.testing.expectEqualStrings("running", claim.run.status);
    try std.testing.expect(claim.lease_token.len > 0);

    // Add event
    const event_id = try store.addEvent(claim.run.id, "progress", "{\"step\":1}");
    try std.testing.expect(event_id > 0);

    // Transition
    const transition = try store.transitionRun(claim.run.id, "complete", null, null, "todo", null);
    defer store.freeTransitionResult(transition);
    try std.testing.expectEqualStrings("todo", transition.previous_stage);
    try std.testing.expectEqualStrings("done", transition.new_stage);

    // Verify task moved to terminal stage
    const task_after = (try store.getTask(task_id)).?;
    defer store.freeTaskRow(task_after);
    try std.testing.expectEqualStrings("done", task_after.stage);
    try std.testing.expectEqual(@as(i64, 2), task_after.task_version);

    // No more claimable work
    const no_claim = try store.claimTask("agent-1", "worker", 300_000, null);
    try std.testing.expect(no_claim == null);
}

test "claim respects per-state concurrency limits" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    const pipeline_def =
        \\{"initial":"review","states":{"review":{"agent_role":"reviewer"},"done":{"terminal":true}},"transitions":[{"from":"review","to":"done","trigger":"approve"}]}
    ;

    const pipeline_id = try store.createPipeline("concurrency-test", pipeline_def);
    defer store.freeOwnedString(pipeline_id);

    // Create 3 tasks
    const t1 = try store.createTask(pipeline_id, "Task 1", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(t1);
    const t2 = try store.createTask(pipeline_id, "Task 2", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(t2);
    const t3 = try store.createTask(pipeline_id, "Task 3", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(t3);

    // Set per-state concurrency limit of 2 for "review"
    var concurrency_map = std.json.ObjectMap.init(alloc);
    defer concurrency_map.deinit();
    try concurrency_map.put("review", .{ .integer = 2 });
    const per_state: std.json.Value = .{ .object = concurrency_map };

    // Claim first two tasks — should succeed
    const c1 = (try store.claimTask("a1", "reviewer", 300_000, per_state)).?;
    defer store.freeClaimResult(c1);
    const c2 = (try store.claimTask("a2", "reviewer", 300_000, per_state)).?;
    defer store.freeClaimResult(c2);

    // Third claim should be blocked by concurrency limit
    const c3 = try store.claimTask("a3", "reviewer", 300_000, per_state);
    try std.testing.expect(c3 == null);

    // Complete one task, freeing a slot
    const transition = try store.transitionRun(c1.run.id, "approve", null, null, null, null);
    defer store.freeTransitionResult(transition);

    // Now third claim should succeed
    const c3_retry = (try store.claimTask("a3", "reviewer", 300_000, per_state)).?;
    defer store.freeClaimResult(c3_retry);
    try std.testing.expectEqualStrings(t3, c3_retry.task.id);
}

test "claim: no work when no matching role" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    const pipeline_def =
        \\{"initial":"coding","states":{"coding":{"agent_role":"coder"},"done":{"terminal":true}},"transitions":[{"from":"coding","to":"done","trigger":"complete"}]}
    ;

    const pipeline_id = try store.createPipeline("role-test", pipeline_def);
    defer store.freeOwnedString(pipeline_id);

    const task_id = try store.createTask(pipeline_id, "Code Task", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(task_id);

    // Claim with wrong role returns null
    const result = try store.claimTask("agent-1", "reviewer", 300_000, null);
    try std.testing.expect(result == null);

    // Claim with correct role returns task
    const claim = (try store.claimTask("agent-1", "coder", 300_000, null)).?;
    defer store.freeClaimResult(claim);
    try std.testing.expectEqualStrings(task_id, claim.task.id);
}

test "claim isolates shared stage names by pipeline role mapping" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    const reviewer_pipeline =
        \\{"initial":"shared","states":{"shared":{"agent_role":"reviewer"},"done":{"terminal":true}},"transitions":[{"from":"shared","to":"done","trigger":"approve"}]}
    ;
    const coder_pipeline =
        \\{"initial":"shared","states":{"shared":{"agent_role":"coder"},"done":{"terminal":true}},"transitions":[{"from":"shared","to":"done","trigger":"complete"}]}
    ;

    const reviewer_pipeline_id = try store.createPipeline("shared-stage-reviewer", reviewer_pipeline);
    defer store.freeOwnedString(reviewer_pipeline_id);
    const coder_pipeline_id = try store.createPipeline("shared-stage-coder", coder_pipeline);
    defer store.freeOwnedString(coder_pipeline_id);

    const reviewer_task = try store.createTask(reviewer_pipeline_id, "Review Task", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(reviewer_task);
    const coder_task = try store.createTask(coder_pipeline_id, "Code Task", "desc", 0, "{}", null, 0, null);
    defer store.freeOwnedString(coder_task);

    const reviewer_claim = (try store.claimTask("agent-r", "reviewer", 300_000, null)).?;
    defer store.freeClaimResult(reviewer_claim);
    try std.testing.expectEqualStrings(reviewer_task, reviewer_claim.task.id);

    const coder_claim = (try store.claimTask("agent-c", "coder", 300_000, null)).?;
    defer store.freeClaimResult(coder_claim);
    try std.testing.expectEqualStrings(coder_task, coder_claim.task.id);
}

test "fail run with retry policy" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, ":memory:");
    defer store.deinit();

    const pipeline_def =
        \\{"initial":"process","states":{"process":{"agent_role":"worker"},"dead":{"terminal":true}},"transitions":[{"from":"process","to":"dead","trigger":"complete"}]}
    ;

    const pipeline_id = try store.createPipeline("retry-test", pipeline_def);
    defer store.freeOwnedString(pipeline_id);

    const task_id = try store.createTask(pipeline_id, "Retry Task", "desc", 0, "{}", 2, 1000, "dead");
    defer store.freeOwnedString(task_id);

    // First claim and fail
    const c1 = (try store.claimTask("agent-1", "worker", 300_000, null)).?;
    defer store.freeClaimResult(c1);
    try store.failRun(c1.run.id, "error 1", null);

    // Task should have next_eligible_at_ms set (retry delay)
    const task_after_1 = (try store.getTask(task_id)).?;
    defer store.freeTaskRow(task_after_1);
    try std.testing.expect(task_after_1.next_eligible_at_ms > 0);
    try std.testing.expect(task_after_1.dead_letter_reason == null);
}

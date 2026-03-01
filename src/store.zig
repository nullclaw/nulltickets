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
        domain.validatePipeline(validation_arena.allocator(), definition_json) catch |err| {
            log.err("pipeline validation failed: {s}", .{domain.validationErrorMessage(err)});
            return error.ValidationFailed;
        };

        const id_arr = ids.generateId();
        const id = try self.allocator.dupe(u8, &id_arr);
        errdefer self.allocator.free(id);
        const now_ms = ids.nowMs();

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

    pub fn createTask(self: *Self, pipeline_id: []const u8, title: []const u8, description: []const u8, priority: i64, metadata_json: []const u8) ![]const u8 {
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

        const stmt = try self.prepare("INSERT INTO tasks (id, pipeline_id, stage, title, description, priority, metadata_json, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);");
        defer _ = c.sqlite3_finalize(stmt);

        self.bindText(stmt, 1, id);
        self.bindText(stmt, 2, pipeline_id);
        self.bindText(stmt, 3, def.initial);
        self.bindText(stmt, 4, title);
        self.bindText(stmt, 5, description);
        _ = c.sqlite3_bind_int64(stmt, 6, priority);
        self.bindText(stmt, 7, metadata_json);
        _ = c.sqlite3_bind_int64(stmt, 8, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 9, now_ms);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;

        return id;
    }

    pub fn getTask(self: *Self, id: []const u8) !?TaskRow {
        const stmt = try self.prepare("SELECT id, pipeline_id, stage, title, description, priority, metadata_json, created_at_ms, updated_at_ms FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.readTaskRow(stmt);
    }

    pub fn listTasks(self: *Self, stage_filter: ?[]const u8, pipeline_id_filter: ?[]const u8, limit: ?i64) ![]TaskRow {
        // Build query dynamically
        var sql_buf: [512]u8 = undefined;
        var sql_len: usize = 0;
        const base = "SELECT id, pipeline_id, stage, title, description, priority, metadata_json, created_at_ms, updated_at_ms FROM tasks";
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
        }

        const order = " ORDER BY priority DESC, created_at_ms ASC";
        @memcpy(sql_buf[sql_len..][0..order.len], order);
        sql_len += order.len;

        if (limit != null) {
            const lim = " LIMIT ?";
            @memcpy(sql_buf[sql_len..][0..lim.len], lim);
            sql_len += lim.len;
        }

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
        if (limit) |l| {
            _ = c.sqlite3_bind_int64(stmt, bind_idx, l);
        }

        var results: std.ArrayListUnmanaged(TaskRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(self.allocator, self.readTaskRow(stmt));
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getLatestRun(self: *Self, task_id: []const u8) !?RunRow {
        const stmt = try self.prepare("SELECT id, task_id, attempt, status, agent_id, agent_role, started_at_ms, ended_at_ms, usage_json, error_text FROM runs WHERE task_id = ? ORDER BY attempt DESC LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, task_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return self.readRunRow(stmt);
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
            .created_at_ms = c.sqlite3_column_int64(stmt, 7),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 8),
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

    pub fn claimTask(self: *Self, agent_id: []const u8, agent_role: []const u8, lease_ttl_ms: i64) !?ClaimResult {
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
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                try stale_lease_ids.append(temp_alloc, try temp_alloc.dupe(u8, self.colTextView(stmt, 0)));
                try stale_run_ids.append(temp_alloc, try temp_alloc.dupe(u8, self.colTextView(stmt, 1)));
            }

            for (stale_run_ids.items) |run_id| {
                const upd = try self.prepare("UPDATE runs SET status = 'stale', ended_at_ms = ? WHERE id = ?;");
                defer _ = c.sqlite3_finalize(upd);
                _ = c.sqlite3_bind_int64(upd, 1, now_ms);
                self.bindText(upd, 2, run_id);
                _ = c.sqlite3_step(upd);
            }
            for (stale_lease_ids.items) |lease_id| {
                const del = try self.prepare("DELETE FROM leases WHERE id = ?;");
                defer _ = c.sqlite3_finalize(del);
                self.bindText(del, 1, lease_id);
                _ = c.sqlite3_step(del);
            }
        }

        // Find stages matching this role across all pipelines
        var all_stages: std.ArrayListUnmanaged([]const u8) = .empty;
        {
            const pstmt = try self.prepare("SELECT definition_json FROM pipelines;");
            defer _ = c.sqlite3_finalize(pstmt);
            while (c.sqlite3_step(pstmt) == c.SQLITE_ROW) {
                const def_json = self.colTextView(pstmt, 0);
                var parsed = domain.parseAndValidate(temp_alloc, def_json) catch continue;
                defer parsed.deinit();
                const stages = domain.getStagesForRole(temp_alloc, parsed.value, agent_role) catch continue;
                for (stages) |s| {
                    try all_stages.append(temp_alloc, s);
                }
            }
        }

        if (all_stages.items.len == 0) {
            try self.execSimple("COMMIT;");
            return null;
        }

        // Find task: stage matches, no active lease, ordered by priority
        var task_row: ?TaskRow = null;
        for (all_stages.items) |stage| {
            const find_sql = "SELECT t.id, t.pipeline_id, t.stage, t.title, t.description, t.priority, t.metadata_json, t.created_at_ms, t.updated_at_ms FROM tasks t WHERE t.stage = ? AND NOT EXISTS (SELECT 1 FROM leases l JOIN runs r ON l.run_id = r.id WHERE r.task_id = t.id AND l.expires_at_ms > ?) ORDER BY t.priority DESC, t.created_at_ms ASC LIMIT 1;";
            const fstmt = try self.prepare(find_sql);
            defer _ = c.sqlite3_finalize(fstmt);
            self.bindText(fstmt, 1, stage);
            _ = c.sqlite3_bind_int64(fstmt, 2, now_ms);

            if (c.sqlite3_step(fstmt) == c.SQLITE_ROW) {
                const candidate = try self.readTaskRowAlloc(temp_alloc, fstmt);
                if (task_row) |existing| {
                    // Keep higher priority or earlier created
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

    pub fn listEvents(self: *Self, run_id: []const u8) ![]EventRow {
        const stmt = try self.prepare("SELECT id, run_id, ts_ms, kind, data_json FROM events WHERE run_id = ? ORDER BY id ASC;");
        defer _ = c.sqlite3_finalize(stmt);
        self.bindText(stmt, 1, run_id);

        var results: std.ArrayListUnmanaged(EventRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(self.allocator, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .run_id = self.colText(stmt, 1),
                .ts_ms = c.sqlite3_column_int64(stmt, 2),
                .kind = self.colText(stmt, 3),
                .data_json = self.colText(stmt, 4),
            });
        }
        return results.toOwnedSlice(self.allocator);
    }

    // ===== Transition =====

    pub fn transitionRun(self: *Self, run_id: []const u8, trigger: []const u8, instructions: ?[]const u8, usage_json: ?[]const u8) !TransitionResult {
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
        const task_stmt = try self.prepare("SELECT pipeline_id, stage FROM tasks WHERE id = ?;");
        defer _ = c.sqlite3_finalize(task_stmt);
        self.bindText(task_stmt, 1, task_id);
        if (c.sqlite3_step(task_stmt) != c.SQLITE_ROW) return error.TaskNotFound;
        const pipeline_id = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 0));
        const current_stage = try temp_alloc.dupe(u8, self.colTextView(task_stmt, 1));

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
            const upd = try self.prepare("UPDATE tasks SET stage = ?, updated_at_ms = ? WHERE id = ?;");
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

        // Count failed attempts at this stage
        {
            const task_stmt = try self.prepare("SELECT stage FROM tasks WHERE id = ?;");
            defer _ = c.sqlite3_finalize(task_stmt);
            self.bindText(task_stmt, 1, task_id);
            if (c.sqlite3_step(task_stmt) == c.SQLITE_ROW) {
                // Count failed runs for this task (at any stage, simplified)
                const cnt_stmt = try self.prepare("SELECT COUNT(*) FROM runs WHERE task_id = ? AND status = 'failed';");
                defer _ = c.sqlite3_finalize(cnt_stmt);
                self.bindText(cnt_stmt, 1, task_id);
                if (c.sqlite3_step(cnt_stmt) == c.SQLITE_ROW) {
                    const fail_count = c.sqlite3_column_int64(cnt_stmt, 0);
                    if (fail_count >= 3) {
                        // Insert exhaustion event
                        const evt = try self.prepare("INSERT INTO events (run_id, ts_ms, kind, data_json) VALUES (?, ?, 'exhaustion', '{\"message\":\"Max retries exceeded\"}');");
                        defer _ = c.sqlite3_finalize(evt);
                        self.bindText(evt, 1, run_id);
                        _ = c.sqlite3_bind_int64(evt, 2, now_ms);
                        _ = c.sqlite3_step(evt);
                    }
                }
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

    pub fn listArtifacts(self: *Self, task_id: ?[]const u8, run_id: ?[]const u8) ![]ArtifactRow {
        var sql_buf: [256]u8 = undefined;
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
        }

        const order = " ORDER BY created_at_ms DESC;";
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
        }

        var results: std.ArrayListUnmanaged(ArtifactRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try results.append(self.allocator, .{
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
        return results.toOwnedSlice(self.allocator);
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
            .created_at_ms = c.sqlite3_column_int64(stmt, 7),
            .updated_at_ms = c.sqlite3_column_int64(stmt, 8),
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
            .created_at_ms = row.created_at_ms,
            .updated_at_ms = row.updated_at_ms,
        };
    }

    fn colInt64Nullable(_: *Self, stmt: *c.sqlite3_stmt, col: c_int) ?i64 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(stmt, col);
    }
};

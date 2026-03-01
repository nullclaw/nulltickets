const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const domain = @import("domain.zig");
const log = std.log.scoped(.api);

const version = "0.1.0";

pub const Context = struct {
    store: *Store,
    allocator: std.mem.Allocator,
};

pub const HttpResponse = struct {
    status: []const u8,
    body: []const u8,
    status_code: u16 = 200,
};

pub fn handleRequest(
    ctx: *Context,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    raw_request: []const u8,
) HttpResponse {
    const path = parsePath(target);
    const seg0 = getPathSegment(path.path, 0);
    const seg1 = getPathSegment(path.path, 1);
    const seg2 = getPathSegment(path.path, 2);

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");

    // GET /health
    if (is_get and eql(seg0, "health") and seg1 == null) {
        return handleHealth(ctx);
    }

    // Pipelines
    if (eql(seg0, "pipelines")) {
        if (is_post and seg1 == null) return handleCreatePipeline(ctx, body);
        if (is_get and seg1 == null) return handleListPipelines(ctx);
        if (is_get and seg1 != null and seg2 == null) return handleGetPipeline(ctx, seg1.?);
    }

    // Tasks
    if (eql(seg0, "tasks")) {
        if (is_post and seg1 == null) return handleCreateTask(ctx, body);
        if (is_get and seg1 == null) return handleListTasks(ctx, path.query);
        if (is_get and seg1 != null and seg2 == null) return handleGetTask(ctx, seg1.?);
    }

    // Leases
    if (eql(seg0, "leases")) {
        if (is_post and eql(seg1, "claim") and seg2 == null) return handleClaim(ctx, body);
        if (is_post and seg1 != null and eql(seg2, "heartbeat")) return handleHeartbeat(ctx, seg1.?, raw_request);
    }

    // Runs
    if (eql(seg0, "runs") and seg1 != null) {
        if (is_post and eql(seg2, "events")) return handleAddEvent(ctx, seg1.?, body, raw_request);
        if (is_get and eql(seg2, "events")) return handleListEvents(ctx, seg1.?);
        if (is_post and eql(seg2, "transition")) return handleTransition(ctx, seg1.?, body, raw_request);
        if (is_post and eql(seg2, "fail")) return handleFail(ctx, seg1.?, body, raw_request);
    }

    // Artifacts
    if (eql(seg0, "artifacts")) {
        if (is_post and seg1 == null) return handleAddArtifact(ctx, body);
        if (is_get and seg1 == null) return handleListArtifacts(ctx, path.query);
    }

    return respondError(ctx.allocator, 404, "not_found", "Not found");
}

// ===== Handlers =====

fn handleHealth(ctx: *Context) HttpResponse {
    var stats = ctx.store.getHealthStats() catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to get health stats");
    };
    defer ctx.store.freeHealthStats(&stats);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{") catch return serverError(ctx.allocator);
    writeStringField(&w, ctx.allocator, "status", "ok") catch return serverError(ctx.allocator);
    w.writeAll(",") catch return serverError(ctx.allocator);
    writeStringField(&w, ctx.allocator, "version", version) catch return serverError(ctx.allocator);
    w.writeAll(",\"tasks_by_stage\":[") catch return serverError(ctx.allocator);
    for (stats.tasks_by_stage, 0..) |sc, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "stage", sc.stage) catch return serverError(ctx.allocator);
        w.print(",\"count\":{d}", .{sc.count}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.print("],\"active_leases\":{d}", .{stats.active_leases}) catch return serverError(ctx.allocator);
    w.writeAll("}") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

fn handleCreatePipeline(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct { name: []const u8, definition: std.json.Value }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    // Stringify the definition back to JSON
    const def_json = jsonStringify(ctx.allocator, req.definition) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Cannot serialize definition");
    };

    const id = ctx.store.createPipeline(req.name, def_json) catch |err| {
        return switch (err) {
            error.ValidationFailed => respondError(ctx.allocator, 400, "validation_failed", "Pipeline definition validation failed"),
            error.DuplicateName => respondError(ctx.allocator, 409, "duplicate_name", "Pipeline name already exists"),
            else => serverError(ctx.allocator),
        };
    };
    defer ctx.store.freeOwnedString(id);

    const id_json = quoteJson(ctx.allocator, id) catch return serverError(ctx.allocator);
    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s}}}", .{id_json}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn handleListPipelines(ctx: *Context) HttpResponse {
    const pipelines = ctx.store.listPipelines() catch return serverError(ctx.allocator);
    defer ctx.store.freePipelineRows(pipelines);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (pipelines, 0..) |p, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        writePipelineJson(&w, ctx.allocator, p) catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

fn handleGetPipeline(ctx: *Context, id: []const u8) HttpResponse {
    const p = (ctx.store.getPipeline(id) catch return serverError(ctx.allocator)) orelse {
        return respondError(ctx.allocator, 404, "not_found", "Pipeline not found");
    };
    defer ctx.store.freePipelineRow(p);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    writePipelineJson(&w, ctx.allocator, p) catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = buf.items };
}

fn handleCreateTask(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        pipeline_id: []const u8,
        title: []const u8,
        description: []const u8,
        priority: ?i64 = null,
        metadata: ?std.json.Value = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    const meta = if (req.metadata) |m| (jsonStringify(ctx.allocator, m) catch "{}") else "{}";

    const id = ctx.store.createTask(req.pipeline_id, req.title, req.description, req.priority orelse 0, meta) catch |err| {
        return switch (err) {
            error.PipelineNotFound => respondError(ctx.allocator, 404, "pipeline_not_found", "Pipeline not found"),
            else => serverError(ctx.allocator),
        };
    };
    defer ctx.store.freeOwnedString(id);

    const id_json = quoteJson(ctx.allocator, id) catch return serverError(ctx.allocator);
    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s}}}", .{id_json}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn handleListTasks(ctx: *Context, query: ?[]const u8) HttpResponse {
    const stage = parseQueryParam(query, "stage");
    const pipeline_id = parseQueryParam(query, "pipeline_id");
    const limit_str = parseQueryParam(query, "limit");
    const limit: ?i64 = if (limit_str) |ls| (std.fmt.parseInt(i64, ls, 10) catch null) else null;

    const tasks = ctx.store.listTasks(stage, pipeline_id, limit) catch return serverError(ctx.allocator);
    defer ctx.store.freeTaskRows(tasks);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (tasks, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        writeTaskJson(&w, ctx.allocator, t) catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

fn handleGetTask(ctx: *Context, id: []const u8) HttpResponse {
    const task = (ctx.store.getTask(id) catch return serverError(ctx.allocator)) orelse {
        return respondError(ctx.allocator, 404, "not_found", "Task not found");
    };
    defer ctx.store.freeTaskRow(task);

    // Get pipeline definition for available transitions
    const pipeline = ctx.store.getPipeline(task.pipeline_id) catch null;
    defer if (pipeline) |p| ctx.store.freePipelineRow(p);
    const latest_run = ctx.store.getLatestRun(id) catch null;
    defer if (latest_run) |r| ctx.store.freeRunRow(r);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{") catch return serverError(ctx.allocator);
    writeTaskJsonFields(&w, ctx.allocator, task) catch return serverError(ctx.allocator);

    // Latest run
    if (latest_run) |run| {
        w.writeAll(",\"latest_run\":{") catch return serverError(ctx.allocator);
        writeRunFields(&w, ctx.allocator, run) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }

    // Available transitions
    if (pipeline) |pip| {
        var parsed_pipeline = domain.parseAndValidate(ctx.allocator, pip.definition_json) catch {
            w.writeAll(",\"available_transitions\":[]") catch return serverError(ctx.allocator);
            w.writeAll("}") catch return serverError(ctx.allocator);
            return .{ .status = "200 OK", .body = buf.items };
        };
        defer parsed_pipeline.deinit();

        const transitions = domain.getAvailableTransitions(ctx.allocator, parsed_pipeline.value, task.stage) catch &.{};
        w.writeAll(",\"available_transitions\":[") catch return serverError(ctx.allocator);
        for (transitions, 0..) |t, i| {
            if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
            w.writeAll("{") catch return serverError(ctx.allocator);
            writeStringField(&w, ctx.allocator, "trigger", t.trigger) catch return serverError(ctx.allocator);
            w.writeAll(",") catch return serverError(ctx.allocator);
            writeStringField(&w, ctx.allocator, "to", t.to) catch return serverError(ctx.allocator);
            w.writeAll("}") catch return serverError(ctx.allocator);
        }
        w.writeAll("]") catch return serverError(ctx.allocator);
    }

    w.writeAll("}") catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = buf.items };
}

fn handleClaim(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        agent_id: []const u8,
        agent_role: []const u8,
        lease_ttl_ms: ?i64 = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const ttl = req.lease_ttl_ms orelse 300_000; // 5 min default

    const result = ctx.store.claimTask(req.agent_id, req.agent_role, ttl) catch |err| {
        log.err("claim failed: {}", .{err});
        return serverError(ctx.allocator);
    };

    if (result) |claim| {
        defer ctx.store.freeClaimResult(claim);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = buf.writer(ctx.allocator);
        w.writeAll("{\"task\":") catch return serverError(ctx.allocator);
        writeTaskJson(&w, ctx.allocator, claim.task) catch return serverError(ctx.allocator);
        w.writeAll(",\"run\":{") catch return serverError(ctx.allocator);
        writeRunFields(&w, ctx.allocator, claim.run) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "lease_id", claim.lease_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "lease_token", claim.lease_token) catch return serverError(ctx.allocator);
        w.print(",\"expires_at_ms\":{d}", .{claim.expires_at_ms}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);

        return .{ .status = "200 OK", .body = buf.items };
    } else {
        return .{ .status = "204 No Content", .body = "", .status_code = 204 };
    }
}

fn handleHeartbeat(ctx: *Context, lease_id: []const u8, raw_request: []const u8) HttpResponse {
    const token = extractBearerToken(raw_request) orelse {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing or invalid Authorization header");
    };

    const new_expires = ctx.store.heartbeat(lease_id, token, 300_000) catch |err| {
        return switch (err) {
            error.LeaseNotFound => respondError(ctx.allocator, 404, "not_found", "Lease not found"),
            error.InvalidToken => respondError(ctx.allocator, 401, "unauthorized", "Invalid token"),
            error.LeaseExpired => respondError(ctx.allocator, 410, "expired", "Lease expired"),
            else => serverError(ctx.allocator),
        };
    };

    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"expires_at_ms\":{d}}}", .{new_expires}) catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = resp };
}

fn handleAddEvent(ctx: *Context, run_id: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
    const token = extractBearerToken(raw_request) orelse {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing Authorization header");
    };
    ctx.store.validateLeaseByRunId(run_id, token) catch |err| {
        return switch (err) {
            error.LeaseNotFound => respondError(ctx.allocator, 404, "not_found", "No active lease for this run"),
            error.InvalidToken => respondError(ctx.allocator, 401, "unauthorized", "Invalid token"),
            error.LeaseExpired => respondError(ctx.allocator, 410, "expired", "Lease expired"),
            else => serverError(ctx.allocator),
        };
    };

    var parsed = std.json.parseFromSlice(struct {
        kind: []const u8,
        data: ?std.json.Value = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const data_json = if (req.data) |d| (jsonStringify(ctx.allocator, d) catch "{}") else "{}";

    const event_id = ctx.store.addEvent(run_id, req.kind, data_json) catch return serverError(ctx.allocator);
    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{event_id}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn handleListEvents(ctx: *Context, run_id: []const u8) HttpResponse {
    const events = ctx.store.listEvents(run_id) catch return serverError(ctx.allocator);
    defer ctx.store.freeEventRows(events);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (events, 0..) |e, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        w.print("\"id\":{d},", .{e.id}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "run_id", e.run_id) catch return serverError(ctx.allocator);
        w.print(",\"ts_ms\":{d},", .{e.ts_ms}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "kind", e.kind) catch return serverError(ctx.allocator);
        w.print(",\"data\":{s}", .{e.data_json}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

fn handleTransition(ctx: *Context, run_id: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
    const token = extractBearerToken(raw_request) orelse {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing Authorization header");
    };
    ctx.store.validateLeaseByRunId(run_id, token) catch |err| {
        return switch (err) {
            error.LeaseNotFound => respondError(ctx.allocator, 404, "not_found", "No active lease for this run"),
            error.InvalidToken => respondError(ctx.allocator, 401, "unauthorized", "Invalid token"),
            error.LeaseExpired => respondError(ctx.allocator, 410, "expired", "Lease expired"),
            else => serverError(ctx.allocator),
        };
    };

    var parsed = std.json.parseFromSlice(struct {
        trigger: []const u8,
        instructions: ?[]const u8 = null,
        usage: ?std.json.Value = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const usage_json = if (req.usage) |u| (jsonStringify(ctx.allocator, u) catch null) else null;

    const result = ctx.store.transitionRun(run_id, req.trigger, req.instructions, usage_json) catch |err| {
        return switch (err) {
            error.RunNotFound => respondError(ctx.allocator, 404, "not_found", "Run not found"),
            error.RunNotRunning => respondError(ctx.allocator, 409, "conflict", "Run is not in running state"),
            error.InvalidTransition => respondError(ctx.allocator, 400, "invalid_transition", "No valid transition for this trigger from current stage"),
            else => serverError(ctx.allocator),
        };
    };
    defer ctx.store.freeTransitionResult(result);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{") catch return serverError(ctx.allocator);
    writeStringField(&w, ctx.allocator, "previous_stage", result.previous_stage) catch return serverError(ctx.allocator);
    w.writeAll(",") catch return serverError(ctx.allocator);
    writeStringField(&w, ctx.allocator, "new_stage", result.new_stage) catch return serverError(ctx.allocator);
    w.writeAll(",") catch return serverError(ctx.allocator);
    writeStringField(&w, ctx.allocator, "trigger", result.trigger) catch return serverError(ctx.allocator);
    w.writeAll("}") catch return serverError(ctx.allocator);
    const resp = buf.items;
    return .{ .status = "200 OK", .body = resp };
}

fn handleFail(ctx: *Context, run_id: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
    const token = extractBearerToken(raw_request) orelse {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing Authorization header");
    };
    ctx.store.validateLeaseByRunId(run_id, token) catch |err| {
        return switch (err) {
            error.LeaseNotFound => respondError(ctx.allocator, 404, "not_found", "No active lease for this run"),
            error.InvalidToken => respondError(ctx.allocator, 401, "unauthorized", "Invalid token"),
            error.LeaseExpired => respondError(ctx.allocator, 410, "expired", "Lease expired"),
            else => serverError(ctx.allocator),
        };
    };

    var parsed = std.json.parseFromSlice(struct {
        @"error": []const u8,
        usage: ?std.json.Value = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const usage_json = if (req.usage) |u| (jsonStringify(ctx.allocator, u) catch null) else null;

    ctx.store.failRun(run_id, req.@"error", usage_json) catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = "{\"status\":\"failed\"}" };
}

fn handleAddArtifact(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        task_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        kind: []const u8,
        uri: []const u8,
        sha256: ?[]const u8 = null,
        size_bytes: ?i64 = null,
        meta: ?std.json.Value = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const meta_json = if (req.meta) |m| (jsonStringify(ctx.allocator, m) catch "{}") else "{}";

    const id = ctx.store.addArtifact(req.task_id, req.run_id, req.kind, req.uri, req.sha256, req.size_bytes, meta_json) catch return serverError(ctx.allocator);
    defer ctx.store.freeOwnedString(id);
    const id_json = quoteJson(ctx.allocator, id) catch return serverError(ctx.allocator);
    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s}}}", .{id_json}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn handleListArtifacts(ctx: *Context, query: ?[]const u8) HttpResponse {
    const task_id = parseQueryParam(query, "task_id");
    const run_id = parseQueryParam(query, "run_id");

    const artifacts = ctx.store.listArtifacts(task_id, run_id) catch return serverError(ctx.allocator);
    defer ctx.store.freeArtifactRows(artifacts);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (artifacts, 0..) |a, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "id", a.id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "task_id", a.task_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "run_id", a.run_id) catch return serverError(ctx.allocator);
        w.print(",\"created_at_ms\":{d},", .{a.created_at_ms}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "kind", a.kind) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "uri", a.uri) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "sha256", a.sha256_hex) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        if (a.size_bytes) |sb| {
            w.print("\"size_bytes\":{d}", .{sb}) catch return serverError(ctx.allocator);
        } else {
            w.writeAll("\"size_bytes\":null") catch return serverError(ctx.allocator);
        }
        w.print(",\"meta\":{s}", .{a.meta_json}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

// ===== JSON helpers =====

fn quoteJson(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch return error.JsonStringifyFailed;
}

fn writeStringField(w: anytype, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try w.print("\"{s}\":", .{key});
    const quoted = try quoteJson(allocator, value);
    try w.writeAll(quoted);
}

fn writeNullableStringField(w: anytype, allocator: std.mem.Allocator, key: []const u8, val: ?[]const u8) !void {
    if (val) |v| {
        try writeStringField(w, allocator, key, v);
    } else {
        try w.print("\"{s}\":null", .{key});
    }
}

fn writePipelineJson(w: anytype, allocator: std.mem.Allocator, p: store_mod.PipelineRow) !void {
    try w.writeAll("{");
    try writeStringField(w, allocator, "id", p.id);
    try w.writeAll(",");
    try writeStringField(w, allocator, "name", p.name);
    try w.print(",\"definition\":{s},\"created_at_ms\":{d}", .{ p.definition_json, p.created_at_ms });
    try w.writeAll("}");
}

fn writeTaskJson(w: anytype, allocator: std.mem.Allocator, t: store_mod.TaskRow) !void {
    try w.writeAll("{");
    try writeTaskJsonFields(w, allocator, t);
    try w.writeAll("}");
}

fn writeTaskJsonFields(w: anytype, allocator: std.mem.Allocator, t: store_mod.TaskRow) !void {
    try writeStringField(w, allocator, "id", t.id);
    try w.writeAll(",");
    try writeStringField(w, allocator, "pipeline_id", t.pipeline_id);
    try w.writeAll(",");
    try writeStringField(w, allocator, "stage", t.stage);
    try w.writeAll(",");
    try writeStringField(w, allocator, "title", t.title);
    try w.writeAll(",");
    try writeStringField(w, allocator, "description", t.description);
    try w.print(",\"priority\":{d},\"metadata\":{s},\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
        t.priority,
        t.metadata_json,
        t.created_at_ms,
        t.updated_at_ms,
    });
}

fn writeRunFields(w: anytype, allocator: std.mem.Allocator, r: store_mod.RunRow) !void {
    try writeStringField(w, allocator, "id", r.id);
    try w.writeAll(",");
    try writeStringField(w, allocator, "task_id", r.task_id);
    try w.print(",\"attempt\":{d},", .{r.attempt});
    try writeStringField(w, allocator, "status", r.status);
    try w.writeAll(",");
    try writeNullableStringField(w, allocator, "agent_id", r.agent_id);
    try w.writeAll(",");
    try writeNullableStringField(w, allocator, "agent_role", r.agent_role);
    if (r.started_at_ms) |started| {
        try w.print(",\"started_at_ms\":{d}", .{started});
    } else {
        try w.writeAll(",\"started_at_ms\":null");
    }
    if (r.ended_at_ms) |ended| {
        try w.print(",\"ended_at_ms\":{d}", .{ended});
    } else {
        try w.writeAll(",\"ended_at_ms\":null");
    }
}

fn jsonStringify(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch return error.JsonStringifyFailed;
}

// ===== HTTP helpers =====

pub const ParsedPath = struct {
    path: []const u8,
    query: ?[]const u8,
};

pub fn parsePath(target: []const u8) ParsedPath {
    if (std.mem.indexOfScalar(u8, target, '?')) |qi| {
        return .{ .path = target[0..qi], .query = target[qi + 1 ..] };
    }
    return .{ .path = target, .query = null };
}

pub fn getPathSegment(path: []const u8, index: usize) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, path, '/');
    var i: usize = 0;
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (i == index) return segment;
        i += 1;
    }
    return null;
}

pub fn parseQueryParam(query: ?[]const u8, key: []const u8) ?[]const u8 {
    const q = query orelse return null;
    var iter = std.mem.splitScalar(u8, q, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], key)) {
                return pair[eq_pos + 1 ..];
            }
        }
    }
    return null;
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    if (a) |av| return std.mem.eql(u8, av, b);
    return false;
}

pub fn extractBody(raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |pos| {
        const body_start = pos + 4;
        if (body_start < raw.len) {
            return raw[body_start..];
        }
    }
    return "";
}

pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const headers = raw[0..header_end];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const hdr_key = line[0..colon];
            if (std.ascii.eqlIgnoreCase(hdr_key, name)) {
                return std.mem.trimLeft(u8, line[colon + 1 ..], " ");
            }
        }
    }
    return null;
}

fn extractBearerToken(raw: []const u8) ?[]const u8 {
    const auth = extractHeader(raw, "Authorization") orelse return null;
    if (std.mem.startsWith(u8, auth, "Bearer ")) {
        return auth["Bearer ".len..];
    }
    return null;
}

fn respondError(allocator: std.mem.Allocator, status_code: u16, code: []const u8, message: []const u8) HttpResponse {
    const status = switch (status_code) {
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        404 => "404 Not Found",
        409 => "409 Conflict",
        410 => "410 Gone",
        else => "500 Internal Server Error",
    };

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ code, message },
    ) catch "{\"error\":{\"code\":\"internal_error\",\"message\":\"allocation failed\"}}";

    return .{ .status = status, .body = body, .status_code = status_code };
}

fn serverError(allocator: std.mem.Allocator) HttpResponse {
    return respondError(allocator, 500, "internal_error", "Internal server error");
}

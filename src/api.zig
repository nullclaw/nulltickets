const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const domain = @import("domain.zig");
const ids = @import("ids.zig");
const log = std.log.scoped(.api);

const version = "2026.3.2";
const openapi_spec = @embedFile("openapi.json");

const OtlpKeyValue = struct {
    key: []const u8,
    value: std.json.Value,
};

const OtlpTraceSpan = struct {
    traceId: ?[]const u8 = null,
    spanId: ?[]const u8 = null,
    parentSpanId: ?[]const u8 = null,
    name: ?[]const u8 = null,
    kind: ?std.json.Value = null,
    startTimeUnixNano: ?[]const u8 = null,
    endTimeUnixNano: ?[]const u8 = null,
    attributes: ?[]const OtlpKeyValue = null,
    status: ?struct {
        code: ?std.json.Value = null,
        message: ?[]const u8 = null,
    } = null,
};

const OtlpScopeInfo = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

const OtlpScopeSpans = struct {
    scope: ?OtlpScopeInfo = null,
    instrumentationLibrary: ?OtlpScopeInfo = null,
    spans: ?[]const OtlpTraceSpan = null,
};

const OtlpResourceSpan = struct {
    resource: ?struct {
        attributes: ?[]const OtlpKeyValue = null,
    } = null,
    scopeSpans: ?[]const OtlpScopeSpans = null,
    instrumentationLibrarySpans: ?[]const OtlpScopeSpans = null,
};

const OtlpTraceExportRequest = struct {
    resourceSpans: ?[]const OtlpResourceSpan = null,
};

const RetryPolicyRequest = struct {
    max_attempts: ?i64 = null,
    retry_delay_ms: ?i64 = null,
    dead_letter_stage: ?[]const u8 = null,
};

const TaskCreatePayload = struct {
    pipeline_id: []const u8,
    title: []const u8,
    description: []const u8,
    priority: ?i64 = null,
    metadata: ?std.json.Value = null,
    retry_policy: ?RetryPolicyRequest = null,
    dependencies: ?[]const []const u8 = null,
    assigned_agent_id: ?[]const u8 = null,
    assigned_by: ?[]const u8 = null,
};

const IdempotencyContext = struct {
    key: []const u8,
    request_hash: [32]u8,
};

pub const Context = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    required_api_token: ?[]const u8 = null,
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
    const seg3 = getPathSegment(path.path, 3);
    const seg4 = getPathSegment(path.path, 4);

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    const is_delete = std.mem.eql(u8, method, "DELETE");

    const is_write = is_post or is_delete;
    const request_token = extractBearerToken(raw_request);

    if (!isAuthorized(ctx, seg0, seg1, seg2, request_token)) {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing or invalid Authorization header");
    }

    var idempotency: ?IdempotencyContext = null;

    if (is_write) {
        if (extractHeader(raw_request, "Idempotency-Key")) |idem_key| {
            const request_hash = ids.hashBytes(body);
            const existing = ctx.store.getIdempotency(idem_key, method, path.path) catch return serverError(ctx.allocator);
            if (existing) |row| {
                defer ctx.store.freeIdempotencyRow(row);
                if (!std.mem.eql(u8, row.request_hash[0..], request_hash[0..])) {
                    return respondError(ctx.allocator, 409, "idempotency_conflict", "Idempotency-Key was reused with a different request body");
                }
                const replay_body = ctx.allocator.dupe(u8, row.response_body) catch return serverError(ctx.allocator);
                return .{
                    .status = statusTextFromCode(@intCast(row.response_status)),
                    .body = replay_body,
                    .status_code = @intCast(row.response_status),
                };
            }
            idempotency = .{
                .key = idem_key,
                .request_hash = request_hash,
            };
        }
    }

    var response: HttpResponse = respondError(ctx.allocator, 404, "not_found", "Not found");

    // GET /health
    if (is_get and eql(seg0, "health") and seg1 == null) {
        response = handleHealth(ctx);
        return response;
    }

    // OpenAPI discovery
    if (is_get and eql(seg0, "openapi.json") and seg1 == null) {
        response = handleOpenApi();
        return response;
    }
    if (is_get and eql(seg0, ".well-known") and eql(seg1, "openapi.json") and seg2 == null) {
        response = handleOpenApi();
        return response;
    }

    // OpenTelemetry OTLP traces ingest
    if (is_post and eql(seg0, "v1") and eql(seg1, "traces") and seg2 == null) {
        response = handleOtlpTraces(ctx, body, raw_request);
        return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
    }
    if (is_post and eql(seg0, "otlp") and eql(seg1, "v1") and eql(seg2, "traces") and seg3 == null) {
        response = handleOtlpTraces(ctx, body, raw_request);
        return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
    }

    // Pipelines
    if (eql(seg0, "pipelines")) {
        if (is_post and seg1 == null) {
            response = handleCreatePipeline(ctx, body);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_get and seg1 == null) {
            response = handleListPipelines(ctx);
            return response;
        }
        if (is_get and seg1 != null and seg2 == null) {
            response = handleGetPipeline(ctx, seg1.?);
            return response;
        }
    }

    // Tasks
    if (eql(seg0, "tasks")) {
        if (is_post and seg1 == null) {
            response = handleCreateTask(ctx, body);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_post and eql(seg1, "bulk") and seg2 == null) {
            response = handleBulkCreateTasks(ctx, body);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_get and seg1 == null) {
            response = handleListTasks(ctx, path.query);
            return response;
        }
        if (is_get and seg1 != null and seg2 == null) {
            response = handleGetTask(ctx, seg1.?);
            return response;
        }

        if (seg1 != null and eql(seg2, "dependencies")) {
            if (is_post and seg3 == null) {
                response = handleAddTaskDependency(ctx, seg1.?, body);
                return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
            }
            if (is_get and seg3 == null) {
                response = handleListTaskDependencies(ctx, seg1.?);
                return response;
            }
        }

        if (seg1 != null and eql(seg2, "assignments")) {
            if (is_post and seg3 == null) {
                response = handleAssignTask(ctx, seg1.?, body);
                return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
            }
            if (is_get and seg3 == null) {
                response = handleListTaskAssignments(ctx, seg1.?);
                return response;
            }
            if (is_delete and seg3 != null and seg4 == null) {
                response = handleUnassignTask(ctx, seg1.?, seg3.?);
                return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
            }
        }
    }

    // Leases
    if (eql(seg0, "leases")) {
        if (is_post and eql(seg1, "claim") and seg2 == null) {
            response = handleClaim(ctx, body);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_post and seg1 != null and eql(seg2, "heartbeat")) {
            response = handleHeartbeat(ctx, seg1.?, raw_request);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
    }

    // Runs
    if (eql(seg0, "runs") and seg1 != null) {
        if (is_post and eql(seg2, "events")) {
            response = handleAddEvent(ctx, seg1.?, body, raw_request);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_get and eql(seg2, "events")) {
            response = handleListEvents(ctx, seg1.?, path.query);
            return response;
        }
        if (is_post and eql(seg2, "gates")) {
            response = handleAddGateResult(ctx, seg1.?, body, raw_request);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_get and eql(seg2, "gates")) {
            response = handleListGateResults(ctx, seg1.?);
            return response;
        }
        if (is_post and eql(seg2, "transition")) {
            response = handleTransition(ctx, seg1.?, body, raw_request);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_post and eql(seg2, "fail")) {
            response = handleFail(ctx, seg1.?, body, raw_request);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
    }

    // Artifacts
    if (eql(seg0, "artifacts")) {
        if (is_post and seg1 == null) {
            response = handleAddArtifact(ctx, body);
            return finalizeWithIdempotency(ctx, method, path.path, idempotency, response);
        }
        if (is_get and seg1 == null) {
            response = handleListArtifacts(ctx, path.query);
            return response;
        }
    }

    if (is_get and eql(seg0, "ops") and eql(seg1, "queue") and seg2 == null) {
        response = handleQueueOps(ctx, path.query);
        return response;
    }

    return response;
}

fn finalizeWithIdempotency(
    ctx: *Context,
    method: []const u8,
    path: []const u8,
    idempotency: ?IdempotencyContext,
    response: HttpResponse,
) HttpResponse {
    if (idempotency) |idem| {
        if (response.status_code < 500) {
            ctx.store.putIdempotency(
                idem.key,
                method,
                path,
                idem.request_hash,
                response.status_code,
                response.body,
            ) catch return serverError(ctx.allocator);
        }
    }
    return response;
}

fn statusTextFromCode(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        404 => "404 Not Found",
        409 => "409 Conflict",
        410 => "410 Gone",
        else => "500 Internal Server Error",
    };
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

fn handleOpenApi() HttpResponse {
    return .{ .status = "200 OK", .body = openapi_spec };
}

fn handleOtlpTraces(ctx: *Context, body: []const u8, raw_request: []const u8) HttpResponse {
    const content_type_raw = extractHeader(raw_request, "Content-Type") orelse "application/x-protobuf";
    const content_type = normalizeContentType(content_type_raw);

    if (!isJsonContentType(content_type)) {
        const batch_id = ctx.store.addOtlpBatchBlob(content_type, body) catch return serverError(ctx.allocator);
        const resp = std.fmt.allocPrint(
            ctx.allocator,
            "{{\"batch_id\":{d},\"accepted_spans\":0,\"stored\":\"blob\"}}",
            .{batch_id},
        ) catch return serverError(ctx.allocator);
        return .{ .status = "200 OK", .body = resp };
    }

    var parsed = std.json.parseFromSlice(OtlpTraceExportRequest, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid OTLP JSON payload");
    };
    defer parsed.deinit();

    ctx.store.execSimple("BEGIN IMMEDIATE;") catch return serverError(ctx.allocator);
    var should_rollback = true;
    defer if (should_rollback) ctx.store.execSimple("ROLLBACK;") catch {};

    const batch_id = ctx.store.addOtlpBatchJson(content_type, body, 0) catch return serverError(ctx.allocator);
    var accepted_spans: i64 = 0;

    const resource_spans = parsed.value.resourceSpans orelse @as([]const OtlpResourceSpan, &.{});
    for (resource_spans) |resource_span| {
        const resource_attributes: []const OtlpKeyValue = if (resource_span.resource) |resource| (resource.attributes orelse &.{}) else &.{};
        const resource_attributes_json = otlpAttributesJson(ctx.allocator, resource_attributes) catch return serverError(ctx.allocator);
        const resource_run_id = getOtlpAttributeText(ctx.allocator, resource_attributes, "nulltickets.run_id") catch return serverError(ctx.allocator);
        const resource_task_id = getOtlpAttributeText(ctx.allocator, resource_attributes, "nulltickets.task_id") catch return serverError(ctx.allocator);

        if (resource_span.scopeSpans) |scope_spans| {
            ingestOtlpScopeSpans(
                ctx,
                batch_id,
                resource_attributes_json,
                scope_spans,
                resource_run_id,
                resource_task_id,
                &accepted_spans,
            ) catch return serverError(ctx.allocator);
        }
        if (resource_span.instrumentationLibrarySpans) |scope_spans| {
            ingestOtlpScopeSpans(
                ctx,
                batch_id,
                resource_attributes_json,
                scope_spans,
                resource_run_id,
                resource_task_id,
                &accepted_spans,
            ) catch return serverError(ctx.allocator);
        }
    }

    ctx.store.updateOtlpBatchParsedSpans(batch_id, accepted_spans) catch return serverError(ctx.allocator);
    ctx.store.execSimple("COMMIT;") catch return serverError(ctx.allocator);
    should_rollback = false;

    const resp = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"batch_id\":{d},\"accepted_spans\":{d},\"stored\":\"json\"}}",
        .{ batch_id, accepted_spans },
    ) catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = resp };
}

fn ingestOtlpScopeSpans(
    ctx: *Context,
    batch_id: i64,
    resource_attributes_json: []const u8,
    scope_spans: []const OtlpScopeSpans,
    resource_run_id: ?[]const u8,
    resource_task_id: ?[]const u8,
    accepted_spans: *i64,
) !void {
    for (scope_spans) |scope_span| {
        const scope_name = if (scope_span.scope) |scope| scope.name else if (scope_span.instrumentationLibrary) |scope| scope.name else null;
        const scope_version = if (scope_span.scope) |scope| scope.version else if (scope_span.instrumentationLibrary) |scope| scope.version else null;
        const spans = scope_span.spans orelse @as([]const OtlpTraceSpan, &.{});
        for (spans) |span| {
            const trace_id = span.traceId orelse continue;
            const span_id = span.spanId orelse continue;
            const span_name = span.name orelse "unnamed";
            const attributes = span.attributes orelse @as([]const OtlpKeyValue, &.{});

            const attributes_json = try otlpAttributesJson(ctx.allocator, attributes);
            const raw_json = try std.json.Stringify.valueAlloc(ctx.allocator, span, .{});
            const kind = if (span.kind) |value| try jsonValueToText(ctx.allocator, value) else null;
            const status_code = if (span.status) |status| if (status.code) |code| try jsonValueToText(ctx.allocator, code) else null else null;
            const status_message = if (span.status) |status| status.message else null;
            const run_id = (try getOtlpAttributeText(ctx.allocator, attributes, "nulltickets.run_id")) orelse resource_run_id;
            const task_id = (try getOtlpAttributeText(ctx.allocator, attributes, "nulltickets.task_id")) orelse resource_task_id;

            try ctx.store.addOtlpSpan(batch_id, .{
                .trace_id = trace_id,
                .span_id = span_id,
                .parent_span_id = span.parentSpanId,
                .name = span_name,
                .kind = kind,
                .start_time_unix_nano = parseUnixNano(span.startTimeUnixNano),
                .end_time_unix_nano = parseUnixNano(span.endTimeUnixNano),
                .status_code = status_code,
                .status_message = status_message,
                .attributes_json = attributes_json,
                .resource_attributes_json = resource_attributes_json,
                .scope_name = scope_name,
                .scope_version = scope_version,
                .run_id = run_id,
                .task_id = task_id,
                .raw_json = raw_json,
            });
            accepted_spans.* += 1;
        }
    }
}

fn otlpAttributesJson(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue) ![]const u8 {
    if (attributes.len == 0) return "[]";
    return std.json.Stringify.valueAlloc(allocator, attributes, .{});
}

fn getOtlpAttributeText(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue, key: []const u8) !?[]const u8 {
    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.key, key)) {
            return try otlpAnyValueToText(allocator, attr.value);
        }
    }
    return null;
}

fn otlpAnyValueToText(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .object => |obj| {
            if (obj.get("stringValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("intValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("doubleValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("boolValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("bytesValue")) |v| return try jsonValueToText(allocator, v);
            return try std.json.Stringify.valueAlloc(allocator, value, .{});
        },
        else => return try jsonValueToText(allocator, value),
    }
}

fn jsonValueToText(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |v| v,
        .number_string => |v| v,
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .bool => |v| if (v) "true" else "false",
        else => try std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn parseUnixNano(value: ?[]const u8) ?i64 {
    const raw = value orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn normalizeContentType(value: []const u8) []const u8 {
    const ct = if (std.mem.indexOfScalar(u8, value, ';')) |idx| value[0..idx] else value;
    return std.mem.trim(u8, ct, " \t");
}

fn isJsonContentType(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "application/json");
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
    var parsed = std.json.parseFromSlice(TaskCreatePayload, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;

    ctx.store.execSimple("BEGIN IMMEDIATE;") catch return serverError(ctx.allocator);
    var should_rollback = true;
    defer if (should_rollback) ctx.store.execSimple("ROLLBACK;") catch {};

    const id = createTaskWithRelations(ctx, req) catch |err| {
        return switch (err) {
            error.PipelineNotFound => respondError(ctx.allocator, 404, "pipeline_not_found", "Pipeline not found"),
            error.TaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Dependency task not found"),
            error.DependencyTaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Dependency task not found"),
            error.DuplicateDependency => respondError(ctx.allocator, 409, "duplicate_dependency", "Dependency already exists"),
            error.InvalidDependency => respondError(ctx.allocator, 400, "invalid_dependency", "Task cannot depend on itself"),
            else => serverError(ctx.allocator),
        };
    };
    defer ctx.store.freeOwnedString(id);

    ctx.store.execSimple("COMMIT;") catch return serverError(ctx.allocator);
    should_rollback = false;

    const id_json = quoteJson(ctx.allocator, id) catch return serverError(ctx.allocator);
    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s}}}", .{id_json}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn createTaskWithRelations(ctx: *Context, req: TaskCreatePayload) ![]const u8 {
    const meta = if (req.metadata) |m| (jsonStringify(ctx.allocator, m) catch "{}") else "{}";
    const retry_policy = req.retry_policy orelse RetryPolicyRequest{};

    const id = try ctx.store.createTask(
        req.pipeline_id,
        req.title,
        req.description,
        req.priority orelse 0,
        meta,
        retry_policy.max_attempts,
        retry_policy.retry_delay_ms orelse 0,
        retry_policy.dead_letter_stage,
    );
    errdefer ctx.store.freeOwnedString(id);

    if (req.dependencies) |deps| {
        for (deps) |dep_task_id| {
            try ctx.store.addTaskDependency(id, dep_task_id);
        }
    }

    if (req.assigned_agent_id) |assigned_agent| {
        try ctx.store.assignTask(id, assigned_agent, req.assigned_by);
    }

    return id;
}

fn handleBulkCreateTasks(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        tasks: []const TaskCreatePayload,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();

    if (parsed.value.tasks.len == 0) {
        return respondError(ctx.allocator, 400, "invalid_request", "tasks list must not be empty");
    }

    ctx.store.execSimple("BEGIN IMMEDIATE;") catch return serverError(ctx.allocator);
    var should_rollback = true;
    defer if (should_rollback) ctx.store.execSimple("ROLLBACK;") catch {};

    var created_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (created_ids.items) |id| ctx.store.freeOwnedString(id);
        created_ids.deinit(ctx.allocator);
    }

    for (parsed.value.tasks) |task_req| {
        const id = createTaskWithRelations(ctx, task_req) catch |err| {
            return switch (err) {
                error.PipelineNotFound => respondError(ctx.allocator, 404, "pipeline_not_found", "Pipeline not found"),
                error.TaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Dependency task not found"),
                error.DependencyTaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Dependency task not found"),
                error.DuplicateDependency => respondError(ctx.allocator, 409, "duplicate_dependency", "Dependency already exists"),
                error.InvalidDependency => respondError(ctx.allocator, 400, "invalid_dependency", "Task cannot depend on itself"),
                else => serverError(ctx.allocator),
            };
        };
        created_ids.append(ctx.allocator, id) catch return serverError(ctx.allocator);
    }

    ctx.store.execSimple("COMMIT;") catch return serverError(ctx.allocator);
    should_rollback = false;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{\"ids\":[") catch return serverError(ctx.allocator);
    for (created_ids.items, 0..) |id, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        const id_json = quoteJson(ctx.allocator, id) catch return serverError(ctx.allocator);
        w.writeAll(id_json) catch return serverError(ctx.allocator);
    }
    w.writeAll("]}") catch return serverError(ctx.allocator);

    return .{ .status = "201 Created", .body = buf.items, .status_code = 201 };
}

fn handleListTasks(ctx: *Context, query: ?[]const u8) HttpResponse {
    const stage = parseQueryParam(query, "stage");
    const pipeline_id = parseQueryParam(query, "pipeline_id");
    const limit_str = parseQueryParam(query, "limit");
    const cursor = parseQueryParam(query, "cursor");
    const limit = if (limit_str) |ls| (std.fmt.parseInt(i64, ls, 10) catch 50) else 50;
    if (limit <= 0 or limit > 1000) {
        return respondError(ctx.allocator, 400, "invalid_limit", "limit must be between 1 and 1000");
    }

    var cursor_created_at_ms: ?i64 = null;
    var cursor_id: ?[]const u8 = null;
    if (cursor) |value| {
        const parsed = parseCompositeCursor(value) orelse {
            return respondError(ctx.allocator, 400, "invalid_cursor", "Invalid cursor format");
        };
        cursor_created_at_ms = parsed.ts_ms;
        cursor_id = parsed.id;
    }

    const page = ctx.store.listTasksPage(stage, pipeline_id, cursor_created_at_ms, cursor_id, limit) catch return serverError(ctx.allocator);
    defer ctx.store.freeTaskPage(page);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{\"items\":[") catch return serverError(ctx.allocator);
    for (page.items, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        writeTaskJson(&w, ctx.allocator, t) catch return serverError(ctx.allocator);
    }
    w.writeAll("],\"next_cursor\":") catch return serverError(ctx.allocator);
    if (page.next_cursor) |next_cursor| {
        const next_cursor_json = quoteJson(ctx.allocator, next_cursor) catch return serverError(ctx.allocator);
        w.writeAll(next_cursor_json) catch return serverError(ctx.allocator);
    } else {
        w.writeAll("null") catch return serverError(ctx.allocator);
    }
    w.writeAll("}") catch return serverError(ctx.allocator);

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
    const dependencies = ctx.store.listTaskDependencies(id) catch return serverError(ctx.allocator);
    defer ctx.store.freeDependencyRows(dependencies);
    const assignments = ctx.store.listTaskAssignments(id) catch return serverError(ctx.allocator);
    defer ctx.store.freeAssignmentRows(assignments);

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

    w.writeAll(",\"dependencies\":[") catch return serverError(ctx.allocator);
    for (dependencies, 0..) |dep, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "depends_on_task_id", dep.depends_on_task_id) catch return serverError(ctx.allocator);
        w.print(",\"resolved\":{s}", .{if (dep.resolved) "true" else "false"}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

    w.writeAll(",\"assignments\":[") catch return serverError(ctx.allocator);
    for (assignments, 0..) |a, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "agent_id", a.agent_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "assigned_by", a.assigned_by) catch return serverError(ctx.allocator);
        w.print(",\"active\":{s},\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
            if (a.active) "true" else "false",
            a.created_at_ms,
            a.updated_at_ms,
        }) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);

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
            w.writeAll(",\"required_gates\":") catch return serverError(ctx.allocator);
            if (t.required_gates) |required_gates| {
                w.writeAll("[") catch return serverError(ctx.allocator);
                for (required_gates, 0..) |gate, gi| {
                    if (gi > 0) w.writeAll(",") catch return serverError(ctx.allocator);
                    const gate_json = quoteJson(ctx.allocator, gate) catch return serverError(ctx.allocator);
                    w.writeAll(gate_json) catch return serverError(ctx.allocator);
                }
                w.writeAll("]") catch return serverError(ctx.allocator);
            } else {
                w.writeAll("[]") catch return serverError(ctx.allocator);
            }
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

fn handleListEvents(ctx: *Context, run_id: []const u8, query: ?[]const u8) HttpResponse {
    const cursor_str = parseQueryParam(query, "cursor");
    const limit_str = parseQueryParam(query, "limit");
    const limit = if (limit_str) |value| (std.fmt.parseInt(i64, value, 10) catch 100) else 100;
    if (limit <= 0 or limit > 1000) {
        return respondError(ctx.allocator, 400, "invalid_limit", "limit must be between 1 and 1000");
    }

    const cursor_id = if (cursor_str) |value| (std.fmt.parseInt(i64, value, 10) catch return respondError(ctx.allocator, 400, "invalid_cursor", "Invalid cursor format")) else null;

    const page = ctx.store.listEventsPage(run_id, cursor_id, limit) catch return serverError(ctx.allocator);
    defer ctx.store.freeEventPage(page);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{\"items\":[") catch return serverError(ctx.allocator);
    for (page.items, 0..) |e, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        w.print("\"id\":{d},", .{e.id}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "run_id", e.run_id) catch return serverError(ctx.allocator);
        w.print(",\"ts_ms\":{d},", .{e.ts_ms}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "kind", e.kind) catch return serverError(ctx.allocator);
        w.print(",\"data\":{s}", .{e.data_json}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("],\"next_cursor\":") catch return serverError(ctx.allocator);
    if (page.next_cursor) |next_cursor| {
        const next_cursor_json = quoteJson(ctx.allocator, next_cursor) catch return serverError(ctx.allocator);
        w.writeAll(next_cursor_json) catch return serverError(ctx.allocator);
    } else {
        w.writeAll("null") catch return serverError(ctx.allocator);
    }
    w.writeAll("}") catch return serverError(ctx.allocator);

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
        expected_stage: ?[]const u8 = null,
        expected_task_version: ?i64 = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();
    const req = parsed.value;
    const usage_json = if (req.usage) |u| (jsonStringify(ctx.allocator, u) catch null) else null;

    const result = ctx.store.transitionRun(run_id, req.trigger, req.instructions, usage_json, req.expected_stage, req.expected_task_version) catch |err| {
        return switch (err) {
            error.RunNotFound => respondError(ctx.allocator, 404, "not_found", "Run not found"),
            error.RunNotRunning => respondError(ctx.allocator, 409, "conflict", "Run is not in running state"),
            error.InvalidTransition => respondError(ctx.allocator, 400, "invalid_transition", "No valid transition for this trigger from current stage"),
            error.RequiredGatesNotPassed => respondError(ctx.allocator, 409, "required_gates_not_passed", "Required quality gates are not passed"),
            error.ExpectedStageMismatch => respondError(ctx.allocator, 409, "expected_stage_mismatch", "Current task stage does not match expected_stage"),
            error.TaskVersionMismatch => respondError(ctx.allocator, 409, "task_version_mismatch", "Current task version does not match expected_task_version"),
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
    const cursor = parseQueryParam(query, "cursor");
    const limit_str = parseQueryParam(query, "limit");
    const limit = if (limit_str) |value| (std.fmt.parseInt(i64, value, 10) catch 100) else 100;
    if (limit <= 0 or limit > 1000) {
        return respondError(ctx.allocator, 400, "invalid_limit", "limit must be between 1 and 1000");
    }

    var cursor_created_at_ms: ?i64 = null;
    var cursor_id: ?[]const u8 = null;
    if (cursor) |value| {
        const parsed = parseCompositeCursor(value) orelse return respondError(ctx.allocator, 400, "invalid_cursor", "Invalid cursor format");
        cursor_created_at_ms = parsed.ts_ms;
        cursor_id = parsed.id;
    }

    const page = ctx.store.listArtifactsPage(task_id, run_id, cursor_created_at_ms, cursor_id, limit) catch return serverError(ctx.allocator);
    defer ctx.store.freeArtifactPage(page);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{\"items\":[") catch return serverError(ctx.allocator);
    for (page.items, 0..) |a, i| {
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
    w.writeAll("],\"next_cursor\":") catch return serverError(ctx.allocator);
    if (page.next_cursor) |next_cursor| {
        const next_cursor_json = quoteJson(ctx.allocator, next_cursor) catch return serverError(ctx.allocator);
        w.writeAll(next_cursor_json) catch return serverError(ctx.allocator);
    } else {
        w.writeAll("null") catch return serverError(ctx.allocator);
    }
    w.writeAll("}") catch return serverError(ctx.allocator);

    return .{ .status = "200 OK", .body = buf.items };
}

fn handleAddTaskDependency(ctx: *Context, task_id: []const u8, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        depends_on_task_id: []const u8,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();

    ctx.store.addTaskDependency(task_id, parsed.value.depends_on_task_id) catch |err| {
        return switch (err) {
            error.TaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Task not found"),
            error.DependencyTaskNotFound => respondError(ctx.allocator, 404, "dependency_task_not_found", "Dependency task not found"),
            error.InvalidDependency => respondError(ctx.allocator, 400, "invalid_dependency", "Task cannot depend on itself"),
            error.DuplicateDependency => respondError(ctx.allocator, 409, "duplicate_dependency", "Dependency already exists"),
            else => serverError(ctx.allocator),
        };
    };

    return .{ .status = "201 Created", .body = "{\"status\":\"created\"}", .status_code = 201 };
}

fn handleListTaskDependencies(ctx: *Context, task_id: []const u8) HttpResponse {
    const deps = ctx.store.listTaskDependencies(task_id) catch return serverError(ctx.allocator);
    defer ctx.store.freeDependencyRows(deps);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (deps, 0..) |dep, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "depends_on_task_id", dep.depends_on_task_id) catch return serverError(ctx.allocator);
        w.print(",\"resolved\":{s}", .{if (dep.resolved) "true" else "false"}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = buf.items };
}

fn handleAssignTask(ctx: *Context, task_id: []const u8, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(struct {
        agent_id: []const u8,
        assigned_by: ?[]const u8 = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();

    ctx.store.assignTask(task_id, parsed.value.agent_id, parsed.value.assigned_by) catch |err| {
        return switch (err) {
            error.TaskNotFound => respondError(ctx.allocator, 404, "task_not_found", "Task not found"),
            else => serverError(ctx.allocator),
        };
    };

    return .{ .status = "201 Created", .body = "{\"status\":\"assigned\"}", .status_code = 201 };
}

fn handleListTaskAssignments(ctx: *Context, task_id: []const u8) HttpResponse {
    const rows = ctx.store.listTaskAssignments(task_id) catch return serverError(ctx.allocator);
    defer ctx.store.freeAssignmentRows(rows);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (rows, 0..) |row, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "task_id", row.task_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "agent_id", row.agent_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "assigned_by", row.assigned_by) catch return serverError(ctx.allocator);
        w.print(",\"active\":{s},\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
            if (row.active) "true" else "false",
            row.created_at_ms,
            row.updated_at_ms,
        }) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = buf.items };
}

fn handleUnassignTask(ctx: *Context, task_id: []const u8, agent_id: []const u8) HttpResponse {
    const changed = ctx.store.unassignTask(task_id, agent_id) catch return serverError(ctx.allocator);
    if (!changed) return respondError(ctx.allocator, 404, "not_found", "Assignment not found");
    return .{ .status = "200 OK", .body = "{\"status\":\"unassigned\"}" };
}

fn handleAddGateResult(ctx: *Context, run_id: []const u8, body: []const u8, raw_request: []const u8) HttpResponse {
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
        gate: []const u8,
        status: []const u8,
        evidence: ?std.json.Value = null,
        actor: ?[]const u8 = null,
    }, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid JSON body");
    };
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.status, "pass") and !std.mem.eql(u8, parsed.value.status, "fail")) {
        return respondError(ctx.allocator, 400, "invalid_status", "status must be pass or fail");
    }

    const evidence_json = if (parsed.value.evidence) |e| (jsonStringify(ctx.allocator, e) catch "{}") else "{}";
    const id = ctx.store.addGateResult(run_id, parsed.value.gate, parsed.value.status, evidence_json, parsed.value.actor) catch |err| {
        return switch (err) {
            error.RunNotFound => respondError(ctx.allocator, 404, "not_found", "Run not found"),
            else => serverError(ctx.allocator),
        };
    };

    const resp = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id}) catch return serverError(ctx.allocator);
    return .{ .status = "201 Created", .body = resp, .status_code = 201 };
}

fn handleListGateResults(ctx: *Context, run_id: []const u8) HttpResponse {
    const rows = ctx.store.listGateResults(run_id) catch return serverError(ctx.allocator);
    defer ctx.store.freeGateResultRows(rows);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("[") catch return serverError(ctx.allocator);
    for (rows, 0..) |row, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        w.print("\"id\":{d},", .{row.id}) catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "run_id", row.run_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "task_id", row.task_id) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "gate", row.gate) catch return serverError(ctx.allocator);
        w.writeAll(",") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "status", row.status) catch return serverError(ctx.allocator);
        w.print(",\"evidence\":{s},", .{row.evidence_json}) catch return serverError(ctx.allocator);
        writeNullableStringField(&w, ctx.allocator, "actor", row.actor) catch return serverError(ctx.allocator);
        w.print(",\"ts_ms\":{d}", .{row.ts_ms}) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("]") catch return serverError(ctx.allocator);
    return .{ .status = "200 OK", .body = buf.items };
}

fn handleQueueOps(ctx: *Context, query: ?[]const u8) HttpResponse {
    const near_expiry_ms = if (parseQueryParam(query, "near_expiry_ms")) |value| (std.fmt.parseInt(i64, value, 10) catch 60_000) else 60_000;
    const stuck_ms = if (parseQueryParam(query, "stuck_ms")) |value| (std.fmt.parseInt(i64, value, 10) catch 300_000) else 300_000;

    const rows = ctx.store.getQueueRoleStats(near_expiry_ms, stuck_ms) catch return serverError(ctx.allocator);
    defer ctx.store.freeQueueRoleStats(rows);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = buf.writer(ctx.allocator);
    w.writeAll("{\"roles\":[") catch return serverError(ctx.allocator);
    for (rows, 0..) |row, i| {
        if (i > 0) w.writeAll(",") catch return serverError(ctx.allocator);
        w.writeAll("{") catch return serverError(ctx.allocator);
        writeStringField(&w, ctx.allocator, "role", row.role) catch return serverError(ctx.allocator);
        w.print(",\"claimable_count\":{d}", .{row.claimable_count}) catch return serverError(ctx.allocator);
        w.writeAll(",\"oldest_claimable_age_ms\":") catch return serverError(ctx.allocator);
        if (row.oldest_claimable_age_ms) |age| {
            w.print("{d}", .{age}) catch return serverError(ctx.allocator);
        } else {
            w.writeAll("null") catch return serverError(ctx.allocator);
        }
        w.print(",\"failed_count\":{d},\"stuck_count\":{d},\"near_expiry_leases\":{d}", .{
            row.failed_count,
            row.stuck_count,
            row.near_expiry_leases,
        }) catch return serverError(ctx.allocator);
        w.writeAll("}") catch return serverError(ctx.allocator);
    }
    w.writeAll("],") catch return serverError(ctx.allocator);
    w.print("\"generated_at_ms\":{d}", .{std.time.milliTimestamp()}) catch return serverError(ctx.allocator);
    w.writeAll("}") catch return serverError(ctx.allocator);
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
    try w.print(",\"priority\":{d},\"metadata\":{s},\"task_version\":{d},\"next_eligible_at_ms\":{d},\"retry_delay_ms\":{d}", .{
        t.priority,
        t.metadata_json,
        t.task_version,
        t.next_eligible_at_ms,
        t.retry_delay_ms,
    });
    if (t.max_attempts) |value| {
        try w.print(",\"max_attempts\":{d}", .{value});
    } else {
        try w.writeAll(",\"max_attempts\":null");
    }
    try w.writeAll(",");
    try writeNullableStringField(w, allocator, "dead_letter_stage", t.dead_letter_stage);
    try w.writeAll(",");
    try writeNullableStringField(w, allocator, "dead_letter_reason", t.dead_letter_reason);
    try w.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
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

const CompositeCursor = struct {
    ts_ms: i64,
    id: []const u8,
};

fn parseCompositeCursor(value: []const u8) ?CompositeCursor {
    const sep = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    if (sep == 0 or sep + 1 >= value.len) return null;
    const ts_part = value[0..sep];
    const id_part = value[sep + 1 ..];
    const ts = std.fmt.parseInt(i64, ts_part, 10) catch return null;
    return .{ .ts_ms = ts, .id = id_part };
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    if (a) |av| return std.mem.eql(u8, av, b);
    return false;
}

fn isAuthorized(
    ctx: *Context,
    seg0: ?[]const u8,
    seg1: ?[]const u8,
    seg2: ?[]const u8,
    request_token: ?[]const u8,
) bool {
    const required = ctx.required_api_token orelse return true;

    if (eql(seg0, "health") and seg1 == null) return true;
    if (eql(seg0, "openapi.json") and seg1 == null) return true;
    if (eql(seg0, ".well-known") and eql(seg1, "openapi.json") and seg2 == null) return true;

    if (requiresLeaseOrAdminToken(seg0, seg1, seg2)) {
        return request_token != null;
    }

    const provided = request_token orelse return false;
    return std.mem.eql(u8, provided, required);
}

fn requiresLeaseOrAdminToken(seg0: ?[]const u8, seg1: ?[]const u8, seg2: ?[]const u8) bool {
    if (eql(seg0, "leases") and seg1 != null and eql(seg2, "heartbeat")) return true;
    if (eql(seg0, "runs") and seg1 != null and seg2 != null) {
        return eql(seg2, "events") or eql(seg2, "gates") or eql(seg2, "transition") or eql(seg2, "fail");
    }
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

test "auth allows health without API token" {
    var store = try Store.init(std.testing.allocator, ":memory:");
    defer store.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = std.testing.allocator,
        .required_api_token = "secret",
    };

    const resp = handleRequest(&ctx, "GET", "/health", "", "GET /health HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("200 OK", resp.status);
}

test "auth rejects protected endpoint without API token" {
    var store = try Store.init(std.testing.allocator, ":memory:");
    defer store.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = std.testing.allocator,
        .required_api_token = "secret",
    };

    const resp = handleRequest(&ctx, "GET", "/tasks", "", "GET /tasks HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("401 Unauthorized", resp.status);
}

test "auth accepts admin token for protected endpoint" {
    var store = try Store.init(std.testing.allocator, ":memory:");
    defer store.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = std.testing.allocator,
        .required_api_token = "secret",
    };

    const raw =
        "GET /tasks HTTP/1.1\r\n" ++
        "Authorization: Bearer secret\r\n\r\n";
    const resp = handleRequest(&ctx, "GET", "/tasks", "", raw);
    try std.testing.expectEqualStrings("200 OK", resp.status);
}

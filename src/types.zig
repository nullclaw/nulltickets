/// Shared response and data types for JSON serialization.
/// Zig structs used with std.json.stringify.

pub const HealthResponse = struct {
    status: []const u8,
    version: []const u8,
    tasks_by_stage: []const StageCount,
    active_leases: i64,
};

pub const StageCount = struct {
    stage: []const u8,
    count: i64,
};

pub const ErrorResponse = struct {
    @"error": ErrorDetail,
};

pub const ErrorDetail = struct {
    code: []const u8,
    message: []const u8,
};

pub const PipelineResponse = struct {
    id: []const u8,
    name: []const u8,
    definition: []const u8, // raw JSON string
    created_at_ms: i64,
};

pub const TaskResponse = struct {
    id: []const u8,
    pipeline_id: []const u8,
    stage: []const u8,
    title: []const u8,
    description: []const u8,
    priority: i64,
    metadata: []const u8, // raw JSON string
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const RunResponse = struct {
    id: []const u8,
    task_id: []const u8,
    attempt: i64,
    status: []const u8,
    agent_id: ?[]const u8,
    agent_role: ?[]const u8,
    started_at_ms: ?i64,
    ended_at_ms: ?i64,
};

pub const LeaseResponse = struct {
    lease_id: []const u8,
    lease_token: []const u8,
    expires_at_ms: i64,
};

pub const ClaimResponse = struct {
    task: TaskResponse,
    run: RunResponse,
    lease_id: []const u8,
    lease_token: []const u8,
    expires_at_ms: i64,
};

pub const EventResponse = struct {
    id: i64,
    run_id: []const u8,
    ts_ms: i64,
    kind: []const u8,
    data: []const u8, // raw JSON string
};

pub const TransitionResponse = struct {
    previous_stage: []const u8,
    new_stage: []const u8,
    trigger: []const u8,
};

pub const ArtifactResponse = struct {
    id: []const u8,
    task_id: ?[]const u8,
    run_id: ?[]const u8,
    created_at_ms: i64,
    kind: []const u8,
    uri: []const u8,
    sha256_hex: ?[]const u8,
    size_bytes: ?i64,
    meta: []const u8, // raw JSON string
};

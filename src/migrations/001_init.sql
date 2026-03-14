-- nulltickets schema v1

CREATE TABLE IF NOT EXISTS pipelines (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    definition_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    pipeline_id TEXT NOT NULL REFERENCES pipelines(id),
    stage TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    task_version INTEGER NOT NULL DEFAULT 1,
    next_eligible_at_ms INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER,
    retry_delay_ms INTEGER NOT NULL DEFAULT 0,
    dead_letter_stage TEXT,
    dead_letter_reason TEXT,
    run_id TEXT,
    workflow_state_json TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_stage ON tasks(stage);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority DESC, created_at_ms ASC);
CREATE INDEX IF NOT EXISTS idx_tasks_pipeline ON tasks(pipeline_id);

CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    attempt INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'running',
    agent_id TEXT,
    agent_role TEXT,
    started_at_ms INTEGER,
    ended_at_ms INTEGER,
    usage_json TEXT NOT NULL DEFAULT '{}',
    error_text TEXT,
    UNIQUE(task_id, attempt)
);
CREATE INDEX IF NOT EXISTS idx_runs_task ON runs(task_id);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);

CREATE TABLE IF NOT EXISTS leases (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    agent_id TEXT NOT NULL,
    token_hash BLOB NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    last_heartbeat_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_leases_expires ON leases(expires_at_ms);
CREATE INDEX IF NOT EXISTS idx_leases_run ON leases(run_id);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    ts_ms INTEGER NOT NULL,
    kind TEXT NOT NULL,
    data_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id, id);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    task_id TEXT REFERENCES tasks(id),
    run_id TEXT REFERENCES runs(id),
    created_at_ms INTEGER NOT NULL,
    kind TEXT NOT NULL,
    uri TEXT NOT NULL,
    sha256_hex TEXT,
    size_bytes INTEGER,
    meta_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_artifacts_task ON artifacts(task_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_run ON artifacts(run_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_created ON artifacts(created_at_ms, id);

CREATE TABLE IF NOT EXISTS task_dependencies (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    depends_on_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    created_at_ms INTEGER NOT NULL,
    PRIMARY KEY (task_id, depends_on_task_id)
);
CREATE INDEX IF NOT EXISTS idx_task_dependencies_depends_on ON task_dependencies(depends_on_task_id);

CREATE TABLE IF NOT EXISTS task_assignments (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    agent_id TEXT NOT NULL,
    assigned_by TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (task_id, agent_id)
);
CREATE INDEX IF NOT EXISTS idx_task_assignments_active_task ON task_assignments(task_id, active);
CREATE INDEX IF NOT EXISTS idx_task_assignments_agent_active ON task_assignments(agent_id, active);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    key TEXT NOT NULL,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    request_hash BLOB NOT NULL,
    response_status INTEGER NOT NULL,
    response_body TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    PRIMARY KEY (key, method, path)
);
CREATE INDEX IF NOT EXISTS idx_idempotency_created ON idempotency_keys(created_at_ms DESC);

CREATE TABLE IF NOT EXISTS otlp_batches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at_ms INTEGER NOT NULL,
    content_type TEXT NOT NULL,
    payload_json TEXT,
    payload_blob BLOB,
    parsed_spans INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_otlp_batches_received ON otlp_batches(received_at_ms DESC);

CREATE TABLE IF NOT EXISTS otlp_spans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id INTEGER NOT NULL REFERENCES otlp_batches(id),
    trace_id TEXT NOT NULL,
    span_id TEXT NOT NULL,
    parent_span_id TEXT,
    name TEXT NOT NULL,
    kind TEXT,
    start_time_unix_nano INTEGER,
    end_time_unix_nano INTEGER,
    status_code TEXT,
    status_message TEXT,
    attributes_json TEXT NOT NULL DEFAULT '[]',
    resource_attributes_json TEXT NOT NULL DEFAULT '[]',
    scope_name TEXT,
    scope_version TEXT,
    run_id TEXT,
    task_id TEXT,
    raw_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_otlp_spans_trace ON otlp_spans(trace_id);
CREATE INDEX IF NOT EXISTS idx_otlp_spans_run ON otlp_spans(run_id);
CREATE INDEX IF NOT EXISTS idx_otlp_spans_task ON otlp_spans(task_id);
CREATE INDEX IF NOT EXISTS idx_otlp_spans_batch ON otlp_spans(batch_id);

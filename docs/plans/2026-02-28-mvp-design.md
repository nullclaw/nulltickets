# nullTracker MVP Design

## Overview

nullTracker MVP — headless task tracker for AI agents. One binary, one SQLite file, REST API. Agents run a claim-loop: claim task → work → transition → claim next.

Key differentiator from Tasks.md baseline: **Pipeline FSM** — configurable state machine for task workflows. Tasks flow through stages (research → coding → testing → review → done), each stage bound to an agent role.

## Stack

- **Zig 0.15.2** (matching nullclaw)
- **SQLite** amalgamation vendored in `deps/sqlite/`, compiled as static lib via `@cImport`
- **HTTP** via `std.http.Server`
- **JSON** via `std.json`
- **IDs** UUID v4 via `std.crypto.random`

## Project Structure

```
nulltracker/
├── build.zig
├── build.zig.zon
├── deps/sqlite/
│   ├── sqlite3.c
│   └── sqlite3.h
├── src/
│   ├── main.zig      # CLI args (--port, --db), TCP listener, accept loop
│   ├── api.zig       # Router: path matching → handler, JSON request/response
│   ├── store.zig     # SQLite: all queries, transactions, migrations
│   ├── domain.zig    # Pipeline FSM validation, transition rules
│   ├── ids.zig       # UUID v4, sha256(lease_token), nowMs()
│   └── types.zig     # Shared structs: Task, Run, Lease, Event, Artifact, Pipeline
├── migrations/
│   └── 001_init.sql
└── tests/
    └── test_api.zig   # E2E: full agent loop via HTTP
```

## Database Schema (6 tables)

### pipelines
Stores FSM definitions as JSON. Created once, referenced by many tasks.

```sql
CREATE TABLE pipelines (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    definition_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
```

Pipeline JSON format:
```json
{
  "initial": "research",
  "states": {
    "research":  { "agent_role": "researcher", "description": "Research phase" },
    "coding":    { "agent_role": "coder",      "description": "Development" },
    "testing":   { "agent_role": "tester",     "description": "Testing" },
    "review":    { "agent_role": "reviewer",   "description": "Code review" },
    "done":      { "terminal": true,           "description": "Completed" }
  },
  "transitions": [
    { "from": "research", "to": "coding",  "trigger": "complete" },
    { "from": "coding",   "to": "testing", "trigger": "complete" },
    { "from": "testing",  "to": "review",  "trigger": "complete" },
    { "from": "testing",  "to": "coding",  "trigger": "reject", "instructions": "Tests failed" },
    { "from": "review",   "to": "done",    "trigger": "approve" },
    { "from": "review",   "to": "coding",  "trigger": "reject" }
  ]
}
```

### tasks
```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    pipeline_id TEXT NOT NULL REFERENCES pipelines(id),
    stage TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
CREATE INDEX idx_tasks_stage ON tasks(stage);
CREATE INDEX idx_tasks_priority ON tasks(priority DESC, created_at_ms ASC);
```

### runs
```sql
CREATE TABLE runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    attempt INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'running',
    agent_id TEXT,
    agent_role TEXT,
    started_at_ms INTEGER,
    ended_at_ms INTEGER,
    usage_json TEXT NOT NULL DEFAULT '{}',
    error TEXT,
    UNIQUE(task_id, attempt)
);
CREATE INDEX idx_runs_task ON runs(task_id);
```

Run status: `running | completed | failed | stale`

### leases
```sql
CREATE TABLE leases (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    agent_id TEXT NOT NULL,
    token_hash BLOB NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    last_heartbeat_ms INTEGER NOT NULL
);
CREATE INDEX idx_leases_expires ON leases(expires_at_ms);
```

### events
```sql
CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    ts_ms INTEGER NOT NULL,
    kind TEXT NOT NULL,
    data_json TEXT NOT NULL
);
CREATE INDEX idx_events_run ON events(run_id, id);
```

Event kinds: `tool_call | step | error | note | checkpoint | transition`

### artifacts
```sql
CREATE TABLE artifacts (
    id TEXT PRIMARY KEY,
    task_id TEXT REFERENCES tasks(id),
    run_id TEXT REFERENCES runs(id),
    created_at_ms INTEGER NOT NULL,
    kind TEXT NOT NULL,
    uri TEXT NOT NULL,
    sha256 TEXT,
    size_bytes INTEGER,
    meta_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_artifacts_task ON artifacts(task_id);
CREATE INDEX idx_artifacts_run ON artifacts(run_id);
```

## API Endpoints

### Health
- `GET /health` → `{ status, version, tasks_by_stage, active_leases }`

### Pipelines
- `POST /pipelines` → create pipeline from JSON definition
- `GET /pipelines` → list all pipelines
- `GET /pipelines/{id}` → pipeline detail with FSM graph

### Tasks
- `POST /tasks` → `{ pipeline_id, title, description, priority?, metadata? }` → 201 `{ task }`
- `GET /tasks?stage=...&pipeline_id=...&limit=N` → list tasks
- `GET /tasks/{id}` → task + latest run + available transitions from current stage

### Claim + Lease
- `POST /leases/claim` → `{ agent_id, agent_role, lease_ttl_ms? }`
  - Finds tasks where current stage's agent_role matches
  - Atomic transaction: janitor expired leases → pick task → create run → create lease
  - Returns: `{ task, run, lease_id, lease_token, expires_at_ms }`
  - 204 if no tasks available
- `POST /leases/{id}/heartbeat` → Bearer token auth → extends TTL

### Run lifecycle
- `POST /runs/{id}/events` → Bearer token → `{ kind, data }` → append event
- `GET /runs/{id}/events` → list events for run
- `POST /runs/{id}/transition` → Bearer token → `{ trigger, instructions?, usage? }`
  - Validates trigger against pipeline FSM from current stage
  - If valid: run.status = completed, task.stage = target, lease deleted
  - Stores transition event with instructions
  - If target is terminal: task is done
  - Returns: `{ previous_stage, new_stage, trigger }`
- `POST /runs/{id}/fail` → Bearer token → `{ error, usage? }`
  - run.status = failed, lease deleted
  - If attempts < 3: task stays in same stage (available for re-claim)
  - If attempts >= 3: task gets special "failed" handling

### Artifacts
- `POST /artifacts` → `{ task_id?, run_id?, kind, uri, sha256?, size_bytes?, meta? }` → 201
- `GET /artifacts?task_id=...&run_id=...` → list artifacts

## Agent Claim Loop

```
agent (role: "coder"):
  loop:
    response = POST /leases/claim { agent_id: "coder-1", agent_role: "coder" }
    if 204: sleep(poll_interval); continue

    task, run, lease = response
    timer = start_heartbeat(lease)
    try:
      result = do_work(task)
      POST /runs/{run.id}/events { kind: "step", data: ... }
      POST /runs/{run.id}/transition { trigger: "complete", instructions: "Done: ..." }
    catch:
      POST /runs/{run.id}/fail { error: str(err) }
    finally:
      timer.stop()
```

## Key Design Decisions

1. **Pipeline FSM as JSON** — maximum flexibility, single table, validated at creation time
2. **Claim filters by agent_role** — agent sees only tasks in stages matching its role
3. **Lease token as sha256 hash** — plaintext returned only at claim time
4. **Janitor in claim transaction** — expired leases cleaned up atomically, no background process
5. **BEGIN IMMEDIATE** — prevents double-claim race conditions
6. **Instructions at transitions** — two levels: static (in pipeline def) + dynamic (agent-provided)
7. **Events table for audit trail** — transition events include instructions for next agent
8. **Max 3 retries per stage** — fail 3 times → needs manual intervention

## What is NOT in MVP

- UI (API-only)
- DAG task dependencies
- WorkPackages / execution modes
- Budget enforcement
- Loop detection
- SSE streaming / Webhooks
- Agent registration table
- OTLP ingestion
- Role-based LLM selection
- Quality gates / guards

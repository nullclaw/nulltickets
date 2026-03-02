# nullTickets

Headless task tracker for autonomous AI agents.

`nullTickets` is a single Zig binary backed by SQLite. It exposes a REST API for
pipeline-driven task tracking and execution coordination: claim work by role, report progress, transition
stages, and attach artifacts.

## Why

- Keep agents running without manual nudging.
- Track long-running autonomous work with durable state.
- Enforce lease-based execution and safe retries.

## Design Principles

`nullTickets` should be treated as the task tracker and source of truth for AI-agent execution.

- `nullTickets` (this repository) is responsible for durable task state:
  - pipelines, stages, transitions
  - runs, leases, events, artifacts
  - dependencies, quality gates, assignments
  - idempotent writes and optimistic transition checks
- `nullTickets` is intentionally orchestration-light:
  - it does not decide global scheduling strategy
  - it does not run agent processes itself
- `nullboiler` is the orchestrator layer:
  - repository: [nullboiler](https://github.com/nullclaw/nullboiler)
  - plans execution, selects agents, balances queues, applies policies, and drives transitions
- `nullclaw` is the agent runtime/executor layer:
  - repository: [nullclaw](https://github.com/nullclaw/nullclaw)
  - executes role prompts, produces outputs, reports back through tracker APIs

Practical architecture:

1. `nullTickets` stores the work graph and execution history.
2. `nullboiler` orchestrates who should do what and when.
3. `nullclaw` agents do the actual work and publish evidence/results.

## Adoption Path

1. Use `nullclaw` only for one-off tasks.
2. Add `nullTickets` when you need a durable backlog (for example 100 tasks) and sequential execution with one agent loop.
3. Add `nullboiler` when you need multi-agent scheduling, balancing, and policy automation.

## Tech Stack

- Zig `0.15.2`
- SQLite (vendored, static dependency)
- JSON over HTTP/1.1

## Quick Start

```bash
zig build
zig build run -- --port 7700 --db tracker.db
```

Default values:

- `--port`: `7700`
- `--db`: `nulltickets.db`

## Test

```bash
zig build test
bash tests/test_e2e.sh
```

## Project Layout

- `src/main.zig` - process entrypoint, argument parsing, socket accept loop
- `src/api.zig` - HTTP routing, request validation, response serialization
- `src/store.zig` - SQLite queries, transactions, ownership/free helpers
- `src/domain.zig` - pipeline FSM parsing and validation
- `src/ids.zig` - UUID/token/hash/time helpers
- `src/migrations/001_init.sql` - database schema
- `tests/test_e2e.sh` - end-to-end API flow

## API Surface

| Method | Path | Description |
|---|---|---|
| `GET` | `/openapi.json` | Full OpenAPI 3.1 schema for agent integration |
| `GET` | `/.well-known/openapi.json` | Well-known OpenAPI discovery endpoint |
| `POST` | `/v1/traces` | OTLP traces ingest (`application/json` or `application/x-protobuf`) |
| `POST` | `/otlp/v1/traces` | OTLP collector-compatible traces ingest path |
| `GET` | `/health` | Service and queue health |
| `POST` | `/pipelines` | Create pipeline definition |
| `GET` | `/pipelines` | List pipelines |
| `GET` | `/pipelines/{id}` | Get pipeline by id |
| `POST` | `/tasks` | Create task |
| `POST` | `/tasks/bulk` | Bulk create tasks |
| `GET` | `/tasks?stage=&pipeline_id=&limit=&cursor=` | List tasks (cursor paginated) |
| `GET` | `/tasks/{id}` | Get task details |
| `POST` | `/tasks/{id}/dependencies` | Add dependency |
| `GET` | `/tasks/{id}/dependencies` | List dependencies |
| `POST` | `/tasks/{id}/assignments` | Assign task to agent |
| `GET` | `/tasks/{id}/assignments` | List assignments |
| `DELETE` | `/tasks/{id}/assignments/{agent_id}` | Unassign task |
| `POST` | `/leases/claim` | Claim next task by role |
| `POST` | `/leases/{id}/heartbeat` | Extend lease |
| `POST` | `/runs/{id}/events` | Append run event |
| `GET` | `/runs/{id}/events?limit=&cursor=` | List run events (cursor paginated) |
| `POST` | `/runs/{id}/gates` | Add quality gate result |
| `GET` | `/runs/{id}/gates` | List quality gate results |
| `POST` | `/runs/{id}/transition` | Move task to next stage |
| `POST` | `/runs/{id}/fail` | Mark run as failed |
| `POST` | `/artifacts` | Attach artifact |
| `GET` | `/artifacts?task_id=&run_id=&limit=&cursor=` | List artifacts (cursor paginated) |
| `GET` | `/ops/queue` | Per-role queue stats for orchestrator |

## Agent Loop

```text
POST /leases/claim { agent_id, agent_role, lease_ttl_ms? }
-> 200 { task, run, lease_id, lease_token, expires_at_ms }
-> 204 (no work)

POST /runs/{run_id}/events      (Bearer <lease_token>)
POST /runs/{run_id}/gates       (Bearer <lease_token>)
POST /runs/{run_id}/transition  (Bearer <lease_token>)
POST /runs/{run_id}/fail        (Bearer <lease_token>)

GET /tasks?limit=&cursor=
GET /runs/{run_id}/events?limit=&cursor=
GET /artifacts?limit=&cursor=
```

For practical `nullclaw` integration patterns (single-agent first, multi-agent optional), see [nullclaw.md](nullclaw.md).

## Documentation

- [Docs Index](docs/README.md)
- [Architecture](docs/architecture.md)
- [API Reference](docs/api.md)
- [Workflows](docs/workflows.md)
- [Agent Lifecycle](docs/agent-lifecycle.md)

Agent bootstrap endpoint:

- `GET /openapi.json`

## OpenTelemetry

`nullTickets` accepts OTLP traces on:

- `POST /v1/traces`
- `POST /otlp/v1/traces`

Behavior:

- `application/json`: parses OTLP `ExportTraceServiceRequest` and stores normalized spans in `otlp_spans`.
- Non-JSON payloads (for example `application/x-protobuf`): stores raw payload in `otlp_batches.payload_blob`.

To link telemetry to tracker entities, include span/resource attributes:

- `nulltickets.run_id`
- `nulltickets.task_id`

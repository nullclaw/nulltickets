# nullTracker

Headless task tracker for autonomous AI agents.

`nullTracker` is a single Zig binary backed by SQLite. It exposes a REST API for
pipeline-driven task orchestration: claim work by role, report progress, transition
stages, and attach artifacts.

## Why

- Keep agents running without manual nudging.
- Track long-running autonomous work with durable state.
- Enforce lease-based execution and safe retries.

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
- `--db`: `nulltracker.db`

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
| `GET` | `/health` | Service and queue health |
| `POST` | `/pipelines` | Create pipeline definition |
| `GET` | `/pipelines` | List pipelines |
| `GET` | `/pipelines/{id}` | Get pipeline by id |
| `POST` | `/tasks` | Create task |
| `GET` | `/tasks?stage=&pipeline_id=&limit=` | List tasks |
| `GET` | `/tasks/{id}` | Get task details |
| `POST` | `/leases/claim` | Claim next task by role |
| `POST` | `/leases/{id}/heartbeat` | Extend lease |
| `POST` | `/runs/{id}/events` | Append run event |
| `GET` | `/runs/{id}/events` | List run events |
| `POST` | `/runs/{id}/transition` | Move task to next stage |
| `POST` | `/runs/{id}/fail` | Mark run as failed |
| `POST` | `/artifacts` | Attach artifact |
| `GET` | `/artifacts?task_id=&run_id=` | List artifacts |

## Agent Loop

```text
POST /leases/claim { agent_id, agent_role, lease_ttl_ms? }
-> 200 { task, run, lease_id, lease_token, expires_at_ms }
-> 204 (no work)

POST /runs/{run_id}/events      (Bearer <lease_token>)
POST /runs/{run_id}/transition  (Bearer <lease_token>)
POST /runs/{run_id}/fail        (Bearer <lease_token>)
```

## Documentation

- [Docs Index](docs/README.md)
- [Architecture](docs/architecture.md)
- [API Reference](docs/api.md)
- [Workflows](docs/workflows.md)
- [Agent Lifecycle](docs/agent-lifecycle.md)

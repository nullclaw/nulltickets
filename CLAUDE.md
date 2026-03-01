# nullTracker

Headless task tracker for AI agents. One Zig binary, one SQLite file, REST API.

## Build & Run

```bash
zig build                                    # compile
zig build run -- --port 7700 --db tracker.db # run
zig build test                               # unit tests
bash tests/test_e2e.sh                       # E2E tests
```

Default port: 7700. Default DB: nulltracker.db.

## Architecture

- `src/main.zig` — CLI args, TCP listener, accept loop
- `src/api.zig` — HTTP router, JSON request/response handlers
- `src/store.zig` — SQLite queries, transactions, migrations
- `src/domain.zig` — Pipeline FSM validation, transition rules
- `src/ids.zig` — UUID v4, SHA-256, token generation
- `src/types.zig` — Shared response structs
- `deps/sqlite/` — Vendored SQLite 3.51.2 amalgamation

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | /health | Health check with task counts |
| POST | /pipelines | Create pipeline with FSM definition |
| GET | /pipelines | List pipelines |
| GET | /pipelines/{id} | Get pipeline |
| POST | /tasks | Create task in pipeline |
| GET | /tasks?stage=&pipeline_id=&limit= | List tasks |
| GET | /tasks/{id} | Task detail + available transitions |
| POST | /leases/claim | Claim task by agent role |
| POST | /leases/{id}/heartbeat | Extend lease (Bearer token) |
| POST | /runs/{id}/events | Add event (Bearer token) |
| GET | /runs/{id}/events | List run events |
| POST | /runs/{id}/transition | Transition task stage (Bearer token) |
| POST | /runs/{id}/fail | Fail run (Bearer token) |
| POST | /artifacts | Add artifact |
| GET | /artifacts?task_id=&run_id= | List artifacts |

## Agent Claim Loop

```
POST /leases/claim { agent_id, agent_role, lease_ttl_ms? }
→ 200 { task, run, lease_id, lease_token, expires_at_ms }
→ 204 (no tasks available)

POST /runs/{run_id}/events { kind, data } (Bearer token)
POST /runs/{run_id}/transition { trigger, instructions? } (Bearer token)
POST /runs/{run_id}/fail { error } (Bearer token)
```

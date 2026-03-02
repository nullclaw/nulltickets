# API Reference

## Conventions

- Content type: `application/json`
- Time values: Unix milliseconds
- Idempotency for writes: optional `Idempotency-Key` header
- Lease-protected endpoints: `Authorization: Bearer <lease_token>`

## Discovery

- `GET /openapi.json`
- `GET /.well-known/openapi.json`

## OpenTelemetry

- `POST /v1/traces`
- `POST /otlp/v1/traces`

OTLP attribute mapping keys:

- `nulltickets.run_id`
- `nulltickets.task_id`

## Health

- `GET /health`

## Pipelines

- `POST /pipelines`
- `GET /pipelines`
- `GET /pipelines/{id}`

Pipeline transitions support `required_gates`:

```json
{ "from": "coding", "to": "review", "trigger": "complete", "required_gates": ["tests_passed"] }
```

## Tasks

- `POST /tasks`
- `POST /tasks/bulk`
- `GET /tasks?stage=&pipeline_id=&limit=&cursor=`
- `GET /tasks/{id}`

`POST /tasks` and bulk items support:

- `retry_policy`: `{ max_attempts?, retry_delay_ms?, dead_letter_stage? }`
- `dependencies`: `string[]` (task ids)
- `assigned_agent_id`, `assigned_by`

### Dependencies

- `POST /tasks/{id}/dependencies` with `{ "depends_on_task_id": "..." }`
- `GET /tasks/{id}/dependencies`

### Assignments

- `POST /tasks/{id}/assignments` with `{ "agent_id": "...", "assigned_by": "..." }`
- `GET /tasks/{id}/assignments`
- `DELETE /tasks/{id}/assignments/{agent_id}`

## Leases

- `POST /leases/claim`
- `POST /leases/{id}/heartbeat` (Bearer)

## Runs

- `POST /runs/{id}/events` (Bearer)
- `GET /runs/{id}/events?limit=&cursor=`
- `POST /runs/{id}/gates` (Bearer)
- `GET /runs/{id}/gates`
- `POST /runs/{id}/transition` (Bearer)
- `POST /runs/{id}/fail` (Bearer)

`POST /runs/{id}/transition` request fields:

- `trigger` (required)
- `instructions` (optional)
- `usage` (optional JSON)
- `expected_stage` (optional)
- `expected_task_version` (optional)

Transition returns `409` when:

- required gates are not passed
- `expected_stage` does not match
- `expected_task_version` does not match

## Artifacts

- `POST /artifacts`
- `GET /artifacts?task_id=&run_id=&limit=&cursor=`

## Ops

- `GET /ops/queue?near_expiry_ms=&stuck_ms=`

Returns per-role stats:

- `claimable_count`
- `oldest_claimable_age_ms`
- `failed_count`
- `stuck_count`
- `near_expiry_leases`

## Pagination Contract

Paginated endpoints return:

```json
{
  "items": [...],
  "next_cursor": "..." 
}
```

`next_cursor = null` means end of list.

## Error Format

```json
{
  "error": {
    "code": "not_found",
    "message": "Task not found"
  }
}
```

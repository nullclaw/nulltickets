# API Reference

## Conventions

- Content type: `application/json`
- Time values: Unix milliseconds
- Auth: `Authorization: Bearer <lease_token>` for lease-protected endpoints

## Discovery

### `GET /openapi.json`

Returns the full OpenAPI 3.1 document for machine-readable integration.

### `GET /.well-known/openapi.json`

Same document at a well-known discovery path.

## OpenTelemetry

### `POST /v1/traces`

Ingests OpenTelemetry OTLP traces.

- `Content-Type: application/json`: parsed as OTLP `ExportTraceServiceRequest`.
- Any other content type (for example `application/x-protobuf`): raw payload is stored as blob.

Response:

```json
{
  "batch_id": 1,
  "accepted_spans": 3,
  "stored": "json"
}
```

### `POST /otlp/v1/traces`

Same OTLP ingest behavior at a collector-compatible path.

### OTLP Attribute Mapping

If present in span or resource attributes, these keys are mapped to tracker entities:

- `nulltracker.run_id`
- `nulltracker.task_id`

## Health

### `GET /health`

Returns service status, version, task counts by stage, and number of active leases.

## Pipelines

### `POST /pipelines`

Creates a pipeline.

Request:

```json
{
  "name": "dev-pipeline",
  "definition": {
    "initial": "research",
    "states": {
      "research": { "agent_role": "researcher" },
      "coding": { "agent_role": "coder" },
      "done": { "terminal": true }
    },
    "transitions": [
      { "from": "research", "to": "coding", "trigger": "complete" },
      { "from": "coding", "to": "done", "trigger": "complete" }
    ]
  }
}
```

Response: `201 { "id": "<pipeline-id>" }`

### `GET /pipelines`

Lists all pipelines.

### `GET /pipelines/{id}`

Returns a single pipeline object.

## Tasks

### `POST /tasks`

Creates a task for a pipeline.

Request fields:

- `pipeline_id` (required)
- `title` (required)
- `description` (required)
- `priority` (optional, default `0`)
- `metadata` (optional JSON)

### `GET /tasks`

Filters:

- `stage`
- `pipeline_id`
- `limit`

### `GET /tasks/{id}`

Returns task details, latest run (if any), and available transitions.

## Leases

### `POST /leases/claim`

Claims the next available task for `agent_role`.

Request:

```json
{
  "agent_id": "coder-1",
  "agent_role": "coder",
  "lease_ttl_ms": 60000
}
```

Responses:

- `200` with `{ task, run, lease_id, lease_token, expires_at_ms }`
- `204` when no work is available

### `POST /leases/{id}/heartbeat`

Extends lease expiration. Requires bearer token.

## Runs

### `POST /runs/{id}/events`

Appends event data for a running task. Requires bearer token.

### `GET /runs/{id}/events`

Lists run events in ascending order.

### `POST /runs/{id}/transition`

Transitions task stage by pipeline trigger. Requires bearer token.

Request fields:

- `trigger` (required)
- `instructions` (optional)
- `usage` (optional JSON)

### `POST /runs/{id}/fail`

Marks run as failed and releases lease. Requires bearer token.

## Artifacts

### `POST /artifacts`

Creates an artifact linked to task and/or run.

### `GET /artifacts`

Filters:

- `task_id`
- `run_id`

## Error Format

```json
{
  "error": {
    "code": "not_found",
    "message": "Task not found"
  }
}
```

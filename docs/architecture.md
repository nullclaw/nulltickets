# Architecture

## Overview

`nullTickets` is a headless task tracker and lease coordinator for AI agents.

- Single-process Zig service
- SQLite persistence
- JSON REST API
- Lease-based run ownership
- No built-in global orchestrator

## Scope Boundaries

In scope:

- Pipeline/task state and durable history
- Lease ownership and retries
- Run events and artifacts
- Task dependencies (DAG)
- Optional task assignments
- Key-value store with full-text search
- Orchestrator-facing queue metrics (`/ops/queue`)

Out of scope:

- Starting/stopping agent processes
- Scheduling and balancing policy across many agents
- External orchestrator logic

## Runtime Components

- `main.zig`: process lifecycle, CLI flags, socket listener, request loop
- `api.zig`: route dispatch, auth checks, JSON validation and response formatting
- `store.zig`: SQL operations, transactions, migrations, data ownership helpers
- `domain.zig`: pipeline FSM parse/validate and transition lookup

## Data Model

- `pipelines`: workflow state machine definitions
- `tasks`: units of work with current stage and metadata
- `runs`: execution attempts for tasks
- `leases`: short-lived ownership locks with token hash
- `events`: append-only run timeline
- `artifacts`: task/run outputs
- `task_dependencies`: DAG edges (`task -> depends_on_task`)
- `task_assignments`: optional explicit owner binding for agents
- `store`: namespaced key-value entries with FTS5 search
- `idempotency_keys`: deduplication store for write retries

## Execution Semantics

1. Agent claims work using role (`/leases/claim`).
2. Service starts a new run and grants a lease token.
3. Agent sends events and periodic heartbeats.
4. Agent either transitions the run to the next stage or fails it.
5. Transition can enforce optimistic checks (`expected_stage`, `expected_task_version`).
6. Failures apply retry policy and optional dead-letter routing.
7. Lease is released on transition/failure or expires automatically.

## Safety and Correctness

- State-changing paths use SQL transactions (`BEGIN IMMEDIATE`) to avoid double-claim races.
- Lease tokens are stored as SHA-256 hashes, not plaintext.
- Pipeline transitions are validated against declared FSM definitions.
- Claim excludes blocked dependencies, non-eligible retries, and foreign assignments.
- API string fields are JSON-escaped at serialization time.

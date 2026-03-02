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
- Quality gate evidence and enforcement
- Optional task assignments
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
- `gate_results`: pass/fail evidence per run and gate
- `task_assignments`: optional explicit owner binding for agents
- `idempotency_keys`: deduplication store for write retries

## Execution Semantics

1. Agent claims work using role (`/leases/claim`).
2. Service starts a new run and grants a lease token.
3. Agent sends events and periodic heartbeats.
4. Agent (or orchestrator) may submit gate results for run quality checks.
5. Agent either transitions the run to the next stage or fails it.
6. Transition can require gate pass state and optimistic checks (`expected_stage`, `expected_task_version`).
7. Failures apply retry policy and optional dead-letter routing.
8. Lease is released on transition/failure or expires automatically.

## Safety and Correctness

- State-changing paths use SQL transactions (`BEGIN IMMEDIATE`) to avoid double-claim races.
- Lease tokens are stored as SHA-256 hashes, not plaintext.
- Pipeline transitions are validated against declared FSM definitions.
- Required quality gates are enforced server-side on transition.
- Claim excludes blocked dependencies, non-eligible retries, and foreign assignments.
- API string fields are JSON-escaped at serialization time.

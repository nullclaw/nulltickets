# Architecture

## Overview

`nullTracker` is a headless control plane for autonomous agent execution.

- Single-process Zig service
- SQLite persistence
- JSON REST API
- Lease-based run ownership

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

## Execution Semantics

1. Agent claims work using role (`/leases/claim`).
2. Service starts a new run and grants a lease token.
3. Agent sends events and periodic heartbeats.
4. Agent either transitions the run to the next stage or fails it.
5. Lease is released on transition/failure or expires automatically.

## Safety and Correctness

- State-changing paths use SQL transactions (`BEGIN IMMEDIATE`) to avoid double-claim races.
- Lease tokens are stored as SHA-256 hashes, not plaintext.
- Pipeline transitions are validated against declared FSM definitions.
- API string fields are JSON-escaped at serialization time.

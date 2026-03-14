# AGENTS.md - nullTickets Engineering Protocol

This file defines the default working protocol for coding agents in this repository.
Scope: entire repository.

## 1) Project Snapshot (Read First)

nullTickets is a headless task tracker for autonomous AI agents:

- one Zig binary
- one SQLite database file
- REST API over HTTP

Primary modules:

- `src/main.zig` - process args, TCP accept loop, request/response lifecycle
- `src/api.zig` - routing + HTTP handlers + JSON contracts
- `src/store.zig` - SQLite access, transactions, migrations, ownership/free helpers
- `src/domain.zig` - pipeline FSM parse/validation/transition logic
- `src/ids.zig` - UUID/token/hash/time helpers
- `src/config.zig` - config loading and resolution
- `src/export_manifest.zig` - nullhub manifest export
- `src/from_json.zig` - JSON config bootstrap
- `src/migrations/001_init.sql` - schema
- `src/migrations/003_store.sql` - KV store table
- `src/migrations/004_store_fts.sql` - FTS5 search index

Baseline commands:

```bash
zig build
zig build test
bash tests/test_e2e.sh
```

## 2) Architecture Contracts

1. Keep boundaries strict.
- `api` orchestrates HTTP behavior only.
- `store` owns SQL and DB transactions.
- `domain` owns FSM validation and transition rules.

2. Keep ownership explicit.
- Anything allocated by `Store` and returned to callers must be explicitly released by matching `free*` helpers.
- `std.json.parseFromSlice` results must be paired with `parsed.deinit()` unless allocator lifetime intentionally matches request scope.

3. Preserve API behavior.
- Existing endpoint paths/status semantics are contract-level behavior.
- If behavior changes, update tests/docs in the same patch.

## 3) Engineering Principles (Required)

### 3.1 KISS
- Prefer explicit SQL/flow over abstraction layers.
- Keep handler logic straightforward and debuggable.

### 3.2 YAGNI
- No speculative flags/config knobs.
- No new subsystem unless there is a concrete caller.

### 3.3 DRY (Rule of Three)
- Avoid premature helper extraction.
- Extract only after repeated stable patterns appear.

### 3.4 Fail Fast + Explicit Errors
- Return explicit HTTP errors for invalid input/auth/state.
- Do not silently skip security checks.

### 3.5 Determinism
- Tests must be reproducible and isolated.
- No external network dependencies in test flows.

## 4) Zig + SQLite Rules

- Zig baseline: `0.15.2`.
- Use `std.ArrayListUnmanaged(...)=.empty` correctly with allocator on each call.
- Do not rely on allocator leaks for correctness.
- Use `SQLITE_STATIC` (`null`) for sqlite text/blob binds in this codebase.
- Multi-step state mutations (`claim`, `transition`, `fail`) must remain transactionally safe.
- Keep schema changes additive and migration-based.

## 5) JSON and API Safety

- Do not build JSON with unescaped user strings.
- Use `std.json.Stringify` helpers for string quoting/serialization.
- Keep raw JSON fields (`definition`, `metadata`, `usage`, `meta`) valid JSON objects.

## 6) Risk Tiers by Path

- Low: docs, comments, formatting-only changes.
- Medium: most handler/query behavior changes.
- High: auth/lease token validation, state transition logic, transaction boundaries, schema migration.

When unsure, treat the change as High risk.

## 7) Required Workflow

1. Read relevant module(s) and adjacent tests before editing.
2. Keep patch scope focused (one concern per change).
3. Implement smallest viable change.
4. Validate with:

```bash
zig build
zig build test
bash tests/test_e2e.sh
```

5. Document what changed, what did not, and remaining risks.

## 8) Anti-Patterns (Do Not)

- Do not bypass free helpers for `Store`-owned return values.
- Do not return unescaped strings inside JSON payloads.
- Do not weaken lease/token checks.
- Do not mix unrelated refactors into behavior/security patches.
- Do not use destructive git commands.

## 9) Handoff Template

When handing off work, include:

1. What changed
2. What did not change
3. Validation run and results
4. Remaining risks/unknowns
5. Next recommended action

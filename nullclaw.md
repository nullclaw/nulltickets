# nullTracker + NullClaw Executors

This guide explains how to run `nullclaw` agents as role-based executors for `nullTracker`.

## 1. Prepare nullclaw

```bash
cd /Users/igorsomov/Code/nullclaw
zig build -Doptimize=ReleaseSmall
zig-out/bin/nullclaw onboard --interactive
```

Useful runtime flags per role:

- `--provider` (for example `openrouter`, `openai`)
- `--model` (for example `openrouter/anthropic/claude-sonnet-4`)
- `--temperature`

## 2. Create pipeline states with explicit `agent_role`

Example role mapping:

- `llm-planner`
- `llm-dev`
- `llm-reviewer`
- `llm-tester`
- `llm-devops`

Each state in pipeline `definition.states.*.agent_role` should match the worker role exactly.

## 3. Run one worker process per role

Each worker loop should:

1. `POST /leases/claim` with its `agent_id` and `agent_role`.
2. If `204`, sleep and retry.
3. If `200`, run `nullclaw agent -m "<prompt>"` to produce output.
4. `POST /runs/{id}/events` to stream progress.
5. `POST /artifacts` to store result file URI.
6. `POST /runs/{id}/transition` with a valid trigger from `GET /tasks/{task_id}` `available_transitions`.
7. If execution fails, `POST /runs/{id}/fail`.

## 4. Realistic Example: Expense Tracker App

Project (neutral and practical):

- Build a small "Team Expense Tracker" application.
- Stack example: API + SQLite + web UI/CLI.
- MVP scope:
  - create/edit/delete expense
  - categories and tags
  - monthly summary report
  - CSV export
  - basic authentication

### Roles

- `llm-planner`:
  - decomposes project into implementation tasks
  - writes acceptance criteria per task
  - creates one separate release task
- `llm-dev`:
  - implements feature tasks
  - may run in parallel with multiple workers
- `llm-reviewer`:
  - checks code quality, test quality, and TDD discipline
  - returns task back to dev if checks fail
- `llm-tester`:
  - validates each completed feature task
  - performs full release regression when all feature tasks are ready
- `llm-devops`:
  - builds binary artifacts
  - deploys release and verifies rollout

### Pipeline A: Feature Task Flow

Use this pipeline for each feature task.

States:

- `backlog` (`agent_role: llm-planner`)
- `in_dev` (`agent_role: llm-dev`)
- `review` (`agent_role: llm-reviewer`)
- `qa_task` (`agent_role: llm-tester`)
- `ready_for_release` (terminal)

Transitions:

- `start_dev`: `backlog -> in_dev`
- `submit_review`: `in_dev -> review`
- `changes_requested`: `review -> in_dev`
- `review_approved`: `review -> qa_task`
- `qa_failed`: `qa_task -> in_dev`
- `qa_passed`: `qa_task -> ready_for_release`

Reviewer gate (minimum):

- tests added/updated for changed behavior
- local test command passes
- no obvious regressions or broken API contracts
- code is understandable and maintainable

### Pipeline B: Release Flow

Create one release task (for example `release-2026-03-01`) in a separate pipeline.

States:

- `collect_ready` (`agent_role: llm-planner`)
- `release_qa` (`agent_role: llm-tester`)
- `deploy` (`agent_role: llm-devops`)
- `released` (terminal)

Transitions:

- `all_tasks_ready`: `collect_ready -> release_qa`
- `release_qa_failed`: `release_qa -> collect_ready`
- `release_qa_passed`: `release_qa -> deploy`
- `deploy_done`: `deploy -> released`

Release QA gate:

- all feature tasks for this release are in `ready_for_release`
- smoke tests pass on assembled build
- integration/regression checks pass

### Parallel Development

Run multiple workers with the same role `llm-dev` but different `agent_id`.
`nullTracker` lease claims guarantee exclusive ownership of each claimed run.

Example:

```bash
./worker.sh llm-dev dev-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-dev dev-2 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-dev dev-3 openrouter/anthropic/claude-sonnet-4
```

Use the same strategy for `llm-tester` when many task-level QA checks are queued.

### Suggested Task Breakdown (Planner Output)

For the Expense Tracker MVP, `llm-planner` can create tasks like:

1. API skeleton + health endpoint
2. Expense CRUD (DB schema + handlers)
3. Categories/tags
4. Monthly summary aggregation
5. CSV export endpoint
6. Auth middleware
7. UI/CLI integration
8. Release task (`release-<date>`)

Each feature task should include explicit acceptance criteria in `metadata`.

## 5. Minimal worker example (bash)

```bash
#!/usr/bin/env bash
set -euo pipefail

TRACKER_BASE="${TRACKER_BASE:-http://127.0.0.1:7700}"
ROLE="${1:?role required}"         # e.g. llm-dev
AGENT_ID="${2:?agent id required}" # e.g. dev-1
MODEL="${3:-openrouter/anthropic/claude-sonnet-4}"
WORK_DIR="${WORK_DIR:-./runtime/executor-$ROLE}"
mkdir -p "$WORK_DIR"

while true; do
  CLAIM=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"agent_role\":\"$ROLE\",\"lease_ttl_ms\":300000}" \
    "$TRACKER_BASE/leases/claim")

  if [ -z "$CLAIM" ]; then
    sleep 2
    continue
  fi

  RUN_ID=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["run"]["id"])')
  TASK_ID=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["task"]["id"])')
  LEASE_ID=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["lease_id"])')
  TOKEN=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["lease_token"])')
  TITLE=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["task"]["title"])')
  DESC=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["task"]["description"])')

  (
    while true; do
      sleep 20
      curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$TRACKER_BASE/leases/$LEASE_ID/heartbeat" >/dev/null || break
    done
  ) &
  HB_PID=$!

  cleanup_hb() { kill "$HB_PID" 2>/dev/null || true; wait "$HB_PID" 2>/dev/null || true; }
  trap cleanup_hb EXIT

  PROMPT="Role: $ROLE
Task: $TITLE
Description: $DESC
Return a concise, production-ready result."

  OUT_FILE="$WORK_DIR/$RUN_ID.md"
  if /Users/igorsomov/Code/nullclaw/zig-out/bin/nullclaw agent --model "$MODEL" -m "$PROMPT" > "$OUT_FILE"; then
    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d "{\"kind\":\"step\",\"data\":{\"message\":\"Completed by $ROLE\",\"output_file\":\"$OUT_FILE\"}}" \
      "$TRACKER_BASE/runs/$RUN_ID/events" >/dev/null

    curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"task_id\":\"$TASK_ID\",\"run_id\":\"$RUN_ID\",\"kind\":\"result\",\"uri\":\"file://$OUT_FILE\"}" \
      "$TRACKER_BASE/artifacts" >/dev/null

    TRIGGER=$(curl -s "$TRACKER_BASE/tasks/$TASK_ID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["available_transitions"][0]["trigger"] if d.get("available_transitions") else "")')
    if [ -n "$TRIGGER" ]; then
      curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
        -d "{\"trigger\":\"$TRIGGER\"}" \
        "$TRACKER_BASE/runs/$RUN_ID/transition" >/dev/null
    fi
  else
    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d '{"error":"nullclaw execution failed"}' \
      "$TRACKER_BASE/runs/$RUN_ID/fail" >/dev/null
  fi

  cleanup_hb
  trap - EXIT
done
```

Start workers:

```bash
./worker.sh llm-planner planner-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-dev dev-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-dev dev-2 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-reviewer reviewer-1 openrouter/anthropic/claude-opus-4
./worker.sh llm-tester tester-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-devops devops-1 openrouter/anthropic/claude-opus-4
```

# nullTicket + NullClaw Executors

This guide explains how to run `nullclaw` agents as role-based executors for `nullTicket`.

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

## 2. Create pipelines with explicit `agent_role` (copy-paste)

Start `nullTicket` first:

```bash
cd /Users/igorsomov/Code/nullTicket
zig build run -- --port 7700 --db runtime/tracker.db
```

In another terminal:

```bash
BASE="http://127.0.0.1:7700"
```

Role mapping used in this guide:

- `llm-planner`
- `llm-dev`
- `llm-reviewer`
- `llm-tester`
- `llm-devops`

Important: `agent_role` is defined inside each state object in `definition.states`.
Workers can claim only tasks whose current stage has matching `agent_role`.

### 2.1 Create feature pipeline

```bash
FEATURE_PIPELINE_PAYLOAD='{
  "name": "expense-feature-flow",
  "definition": {
    "initial": "backlog",
    "states": {
      "backlog": { "agent_role": "llm-planner", "description": "Task decomposition and acceptance criteria" },
      "in_dev": { "agent_role": "llm-dev", "description": "Implementation" },
      "review": { "agent_role": "llm-reviewer", "description": "Code and tests review" },
      "qa_task": { "agent_role": "llm-tester", "description": "Task-level QA" },
      "ready_for_release": { "terminal": true, "description": "Feature task accepted" }
    },
    "transitions": [
      { "from": "backlog", "to": "in_dev", "trigger": "start_dev" },
      { "from": "in_dev", "to": "review", "trigger": "submit_review" },
      { "from": "review", "to": "in_dev", "trigger": "changes_requested" },
      { "from": "review", "to": "qa_task", "trigger": "review_approved" },
      { "from": "qa_task", "to": "in_dev", "trigger": "qa_failed" },
      { "from": "qa_task", "to": "ready_for_release", "trigger": "qa_passed" }
    ]
  }
}'

FEATURE_PIPELINE_ID=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$FEATURE_PIPELINE_PAYLOAD" \
  "$BASE/pipelines" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

echo "FEATURE_PIPELINE_ID=$FEATURE_PIPELINE_ID"
```

### 2.2 Create release pipeline

```bash
RELEASE_PIPELINE_PAYLOAD='{
  "name": "expense-release-flow",
  "definition": {
    "initial": "collect_ready",
    "states": {
      "collect_ready": { "agent_role": "llm-planner", "description": "Collect ready feature tasks" },
      "release_qa": { "agent_role": "llm-tester", "description": "Release regression and smoke tests" },
      "deploy": { "agent_role": "llm-devops", "description": "Build binaries and deploy" },
      "released": { "terminal": true, "description": "Release complete" }
    },
    "transitions": [
      { "from": "collect_ready", "to": "release_qa", "trigger": "all_tasks_ready" },
      { "from": "release_qa", "to": "collect_ready", "trigger": "release_qa_failed" },
      { "from": "release_qa", "to": "deploy", "trigger": "release_qa_passed" },
      { "from": "deploy", "to": "released", "trigger": "deploy_done" }
    ]
  }
}'

RELEASE_PIPELINE_ID=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$RELEASE_PIPELINE_PAYLOAD" \
  "$BASE/pipelines" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

echo "RELEASE_PIPELINE_ID=$RELEASE_PIPELINE_ID"
```

### 2.3 Verify `agent_role` in stored pipeline

```bash
curl -s "$BASE/pipelines/$FEATURE_PIPELINE_ID" | python3 -c '
import json,sys
p=json.load(sys.stdin)
print("backlog role:", p["definition"]["states"]["backlog"]["agent_role"])
print("in_dev role:", p["definition"]["states"]["in_dev"]["agent_role"])
print("review role:", p["definition"]["states"]["review"]["agent_role"])
print("qa_task role:", p["definition"]["states"]["qa_task"]["agent_role"])
'
```

Expected output:

```text
backlog role: llm-planner
in_dev role: llm-dev
review role: llm-reviewer
qa_task role: llm-tester
```

### 2.4 Create feature and release tasks

Create feature tasks:

```bash
for TITLE in \
  "API skeleton + health endpoint" \
  "Expense CRUD (DB + handlers)" \
  "Categories and tags" \
  "Monthly summary" \
  "CSV export" \
  "Auth middleware" \
  "UI integration"
do
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"pipeline_id\":\"$FEATURE_PIPELINE_ID\",\"title\":\"$TITLE\",\"description\":\"$TITLE for Expense Tracker MVP\",\"priority\":50,\"metadata\":{\"release\":\"2026.03\",\"acceptance_criteria\":[\"tests pass\",\"code reviewed\",\"qa passed\"]}}" \
    "$BASE/tasks" >/dev/null
done
```

Create one release task:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"pipeline_id\":\"$RELEASE_PIPELINE_ID\",\"title\":\"Release 2026.03\",\"description\":\"Run release QA, deploy and publish binary artifacts\",\"priority\":100,\"metadata\":{\"release\":\"2026.03\"}}" \
  "$BASE/tasks"
```

## 3. Run role automation with nullclaw cron (Zig-native)

Use cron agent jobs when you want scheduled role execution without wrapping model calls in bash.

Requirements:

- `nullclaw` build that includes `cron add-agent` and `cron once-agent`
- (at the moment, this is available in the implementation branch and then in the next merged release)

### 3.1 Example cron jobs by role

```bash
cd /Users/igorsomov/Code/nullclaw

# Planner: refresh backlog every 15 minutes
zig-out/bin/nullclaw cron add-agent "*/15 * * * *" \
  "Role: llm-planner. Review open tasks for Expense Tracker and propose next backlog updates with acceptance criteria." \
  --model "openrouter/anthropic/claude-sonnet-4"

# Reviewer: periodic quality pass
zig-out/bin/nullclaw cron add-agent "*/20 * * * *" \
  "Role: llm-reviewer. Review recent completed feature work, verify tests/TDD quality, and list changes requested if needed." \
  --model "openrouter/anthropic/claude-opus-4"

# One-shot MVP scope generation
zig-out/bin/nullclaw cron once-agent "30s" \
  "Role: llm-planner. Give me MVP Scope for Team Expense Tracker (API + SQLite + web UI) with feature breakdown and acceptance criteria." \
  --model "openrouter/anthropic/claude-sonnet-4"
```

Inspect jobs:

```bash
zig-out/bin/nullclaw cron list
```

### 3.2 Tracker executor contract

For full `nullTicket` workflow execution, each role executor must still perform this API contract:

1. `POST /leases/claim` with its `agent_id` and `agent_role`.
2. If `204`, sleep and retry.
3. If `200`, run the role prompt and generate output.
4. `POST /runs/{id}/events` to stream progress.
5. `POST /artifacts` to store result file URI.
6. `POST /runs/{id}/transition` with a valid trigger from `GET /tasks/{task_id}` `available_transitions`.
7. If execution fails, `POST /runs/{id}/fail`.

## 4. Realistic Example: Expense Tracker App

Project:

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

### Generate MVP scope with one nullclaw prompt

This is the fastest way to show the LLM value at project start.

```bash
cd /Users/igorsomov/Code/nullclaw
zig-out/bin/nullclaw agent -m "Give me MVP Scope for Team Expense Tracker (API + SQLite + web UI) with feature breakdown and acceptance criteria" > /tmp/mvp_scope.md
```

Then planner (`llm-planner`) converts `/tmp/mvp_scope.md` into separate tasks in `nullTicket` (one task per feature, plus one release task).
This lets you go from idea to executable backlog in a few minutes.

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
`nullTicket` lease claims guarantee exclusive ownership of each claimed run.

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

## 5. Tracker Executor Bridge (bash, current practical adapter)

Use this when you want a complete end-to-end executor loop for `nullTicket` today.
It bridges role claims/transitions and artifact writes through HTTP APIs.

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

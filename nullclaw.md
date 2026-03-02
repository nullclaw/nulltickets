# nullTickets + nullclaw

This guide shows an incremental setup:

1. Use `nullclaw` only for one-off work.
2. Add `nullTickets` for durable backlog tracking and sequential autonomous execution.
3. Add an external orchestrator only when you need multi-agent coordination.

## 1. Mode A: `nullclaw` only (no tracker)

Use this when you want one task and one answer.

```bash
cd /path/to/nullclaw
zig build -Doptimize=ReleaseSmall
zig-out/bin/nullclaw onboard --interactive
zig-out/bin/nullclaw agent -m "Write a concise API design for expense tracking"
```

## 2. Mode B: `nullTickets` + `nullclaw` (no orchestrator)

This is the recommended starting point.

- You keep a durable queue of tasks in `nullTickets`.
- One worker loop processes tasks sequentially.
- No external orchestrator is required.

### 2.1 Start `nullTickets`

```bash
cd /path/to/nulltickets
zig build run -- --port 7700 --db runtime/nulltickets.db
```

In another terminal:

```bash
BASE="http://127.0.0.1:7700"
```

### 2.2 Create a simple sequential pipeline

```bash
PIPELINE_PAYLOAD='{
  "name": "sequential-work",
  "definition": {
    "initial": "todo",
    "states": {
      "todo": { "agent_role": "llm-executor", "description": "Ready to execute" },
      "done": { "terminal": true, "description": "Completed" }
    },
    "transitions": [
      { "from": "todo", "to": "done", "trigger": "complete" }
    ]
  }
}'

PIPELINE_ID=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PIPELINE_PAYLOAD" \
  "$BASE/pipelines" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

echo "PIPELINE_ID=$PIPELINE_ID"
```

### 2.3 Create many tasks (for example 100)

```bash
for i in $(seq 1 100); do
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Task #$i\",\"description\":\"Implement item #$i\",\"priority\":50}" \
    "$BASE/tasks" >/dev/null
done
```

### 2.4 Tracker executor contract

Any runtime (bash, Zig, Go, Python) can be used. The worker must do:

1. `POST /leases/claim` with `agent_id` and `agent_role`.
2. On `204`, sleep and retry.
3. On `200`, run `nullclaw` with task title/description in prompt.
4. `POST /runs/{id}/events` for progress logs.
5. `POST /artifacts` for output file URI.
6. `POST /runs/{id}/transition` with trigger `complete`.
7. On failure, `POST /runs/{id}/fail`.

### 2.5 Minimal worker adapter (bash example)

This adapter is intentionally small. Replace with Zig/Go/Python when needed.

```bash
#!/usr/bin/env bash
set -euo pipefail

TRACKER_BASE="${TRACKER_BASE:-http://127.0.0.1:7700}"
ROLE="${1:?role required}"         # llm-executor
AGENT_ID="${2:?agent id required}" # worker-1
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
  TOKEN=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["lease_token"])')
  TITLE=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["task"]["title"])')
  DESC=$(printf '%s' "$CLAIM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["task"]["description"])')

  OUT_FILE="$WORK_DIR/$RUN_ID.md"
  PROMPT="Task: $TITLE
Description: $DESC
Return a concise, production-ready result."

  if /path/to/nullclaw/zig-out/bin/nullclaw agent --model "$MODEL" -m "$PROMPT" > "$OUT_FILE"; then
    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d "{\"kind\":\"step\",\"data\":{\"message\":\"completed\",\"output_file\":\"$OUT_FILE\"}}" \
      "$TRACKER_BASE/runs/$RUN_ID/events" >/dev/null

    curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"task_id\":\"$TASK_ID\",\"run_id\":\"$RUN_ID\",\"kind\":\"result\",\"uri\":\"file://$OUT_FILE\"}" \
      "$TRACKER_BASE/artifacts" >/dev/null

    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d '{"trigger":"complete"}' \
      "$TRACKER_BASE/runs/$RUN_ID/transition" >/dev/null
  else
    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
      -d '{"error":"nullclaw execution failed"}' \
      "$TRACKER_BASE/runs/$RUN_ID/fail" >/dev/null
  fi
done
```

Run worker:

```bash
./worker.sh llm-executor worker-1 openrouter/anthropic/claude-sonnet-4
```

## 3. Practical Example: Team Expense Tracker

A realistic sequential setup:

1. Generate MVP scope with `nullclaw`.
2. Convert scope into many tasks in `nullTickets`.
3. Process tasks one by one with a single `llm-executor` loop.

Generate scope:

```bash
cd /path/to/nullclaw
zig-out/bin/nullclaw agent -m "Give me MVP Scope for Team Expense Tracker (API + SQLite + web UI) with feature breakdown and acceptance criteria" > /tmp/mvp_scope.md
```

Then create tasks from scope (manual or scripted) and process sequentially in `nullTickets`.

## 4. Optional: External Orchestrator (multi-agent only)

You do not need an orchestrator for the baseline flow above.

Add one only if you need:

- Multiple agent pools (`dev`, `review`, `qa`, `devops`)
- Dynamic assignment and balancing
- Global retry/escalation policies

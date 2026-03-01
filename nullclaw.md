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

- `llm-coder`
- `llm-analyst`
- `llm-judge`

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

## 4. Minimal worker example (bash)

```bash
#!/usr/bin/env bash
set -euo pipefail

TRACKER_BASE="${TRACKER_BASE:-http://127.0.0.1:7700}"
ROLE="${1:?role required}"         # e.g. llm-coder
AGENT_ID="${2:?agent id required}" # e.g. coder-1
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
./worker.sh llm-coder coder-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-analyst analyst-1 openrouter/anthropic/claude-sonnet-4
./worker.sh llm-judge judge-1 openrouter/anthropic/claude-opus-4
```

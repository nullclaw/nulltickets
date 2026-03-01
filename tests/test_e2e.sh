#!/usr/bin/env bash
set -euo pipefail

# E2E test for nulltracker
# Tests full pipeline flow: create pipeline → create tasks → claim → events → transition → fail

PORT=${PORT:-7799}
DB="/tmp/nulltracker_e2e_$$.db"
BIN="./zig-out/bin/nulltracker"
PASS=0
FAIL=0

cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$DB" "${DB}-wal" "${DB}-shm"
}
trap cleanup EXIT

assert_status() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo "  PASS: $label (HTTP $actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — expected $expected, got $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_json() {
    local body="$1"
    local query="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual=$(echo "$body" | python3 -c "import sys,json; data=json.load(sys.stdin); print($query)" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $label ($actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# Build
echo "Building nulltracker..."
zig build 2>&1

# Start server
echo "Starting server on port $PORT..."
"$BIN" --port "$PORT" --db "$DB" &
SERVER_PID=$!
sleep 1

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: Server failed to start"
    exit 1
fi

BASE="http://127.0.0.1:$PORT"

# ===== 1. Health =====
echo ""
echo "=== 1. Health Check ==="
RESP=$(curl -s -w "\n%{http_code}" "$BASE/health")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /health"
assert_json "$BODY" "data['status']" "ok" "health status"

# ===== 2. Create Pipeline =====
echo ""
echo "=== 2. Create Pipeline ==="
PIPELINE_DEF='{
  "name": "dev-pipeline",
  "definition": {
    "initial": "research",
    "states": {
      "research":  { "agent_role": "researcher", "description": "Research phase" },
      "coding":    { "agent_role": "coder",      "description": "Development" },
      "review":    { "agent_role": "reviewer",   "description": "Code review" },
      "done":      { "terminal": true,           "description": "Completed" }
    },
    "transitions": [
      { "from": "research", "to": "coding",  "trigger": "complete" },
      { "from": "coding",   "to": "review",  "trigger": "complete" },
      { "from": "review",   "to": "done",    "trigger": "approve" },
      { "from": "review",   "to": "coding",  "trigger": "reject" }
    ]
  }
}'
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$PIPELINE_DEF" "$BASE/pipelines")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /pipelines"
PIPELINE_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Pipeline ID: $PIPELINE_ID"

# List pipelines
RESP=$(curl -s -w "\n%{http_code}" "$BASE/pipelines")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "GET /pipelines"

# Get pipeline
RESP=$(curl -s -w "\n%{http_code}" "$BASE/pipelines/$PIPELINE_ID")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "GET /pipelines/{id}"

# ===== 3. Create Tasks =====
echo ""
echo "=== 3. Create Tasks ==="
for i in 1 2 3; do
    PRIORITY=$((4 - i))
    RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d "{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Task $i\",\"description\":\"Description for task $i\",\"priority\":$PRIORITY}" \
        "$BASE/tasks")
    CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')
    assert_status 201 "$CODE" "POST /tasks (task $i)"
    eval "TASK${i}_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")"
done
echo "  Task IDs: $TASK1_ID, $TASK2_ID, $TASK3_ID"

# List tasks
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks?stage=research")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks?stage=research"
TASK_COUNT=$(echo "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
assert_json "{\"count\":$TASK_COUNT}" "data['count']" "3" "3 tasks in research"

# Get task detail
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks/$TASK1_ID")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks/{id}"
assert_json "$BODY" "data['stage']" "research" "task starts in research stage"

# ===== 4. Claim as Researcher =====
echo ""
echo "=== 4. Claim + Work + Transition (researcher) ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"researcher-1","agent_role":"researcher","lease_ttl_ms":60000}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /leases/claim (researcher)"

CLAIMED_TASK=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['task']['id'])")
RUN_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
LEASE_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_id'])")
LEASE_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")
echo "  Claimed task: $CLAIMED_TASK, run: $RUN_ID"
echo "  Lease: $LEASE_ID"

# Should claim highest priority task (task1 has priority 3)
assert_json "{\"id\":\"$CLAIMED_TASK\"}" "data['id']" "$TASK1_ID" "highest priority task claimed"

# Heartbeat
RESP=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer $LEASE_TOKEN" \
    "$BASE/leases/$LEASE_ID/heartbeat")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "POST /leases/{id}/heartbeat"

# Add events
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE_TOKEN" \
    -d '{"kind":"step","data":{"message":"Researching..."}}' \
    "$BASE/runs/$RUN_ID/events")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /runs/{id}/events"

# List events
RESP=$(curl -s -w "\n%{http_code}" "$BASE/runs/$RUN_ID/events")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /runs/{id}/events"

# Transition: research → coding
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE_TOKEN" \
    -d '{"trigger":"complete","instructions":"Research complete, ready for coding"}' \
    "$BASE/runs/$RUN_ID/transition")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /runs/{id}/transition (research→coding)"
assert_json "$BODY" "data['new_stage']" "coding" "transitioned to coding"

# ===== 5. Claim as Coder =====
echo ""
echo "=== 5. Claim as Coder + Transition to Review ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"coder-1","agent_role":"coder"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /leases/claim (coder)"

RUN2_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
LEASE2_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")

# Transition: coding → review
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE2_TOKEN" \
    -d '{"trigger":"complete"}' \
    "$BASE/runs/$RUN2_ID/transition")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /runs/{id}/transition (coding→review)"
assert_json "$BODY" "data['new_stage']" "review" "transitioned to review"

# ===== 6. Reviewer rejects =====
echo ""
echo "=== 6. Reviewer Rejects → Back to Coding ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"reviewer-1","agent_role":"reviewer"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /leases/claim (reviewer)"

RUN3_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
LEASE3_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")

# Transition: review → coding (reject)
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE3_TOKEN" \
    -d '{"trigger":"reject","instructions":"Needs more tests"}' \
    "$BASE/runs/$RUN3_ID/transition")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /runs/{id}/transition (review→coding reject)"
assert_json "$BODY" "data['new_stage']" "coding" "rejected back to coding"

# ===== 7. Simulate Failure =====
echo ""
echo "=== 7. Simulate Failure ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"coder-2","agent_role":"coder"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /leases/claim (coder for failure test)"

RUN4_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
LEASE4_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")

# Fail the run
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE4_TOKEN" \
    -d '{"error":"Compilation failed","usage":{"tokens":1500}}' \
    "$BASE/runs/$RUN4_ID/fail")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "POST /runs/{id}/fail"

# Should be re-claimable (< 3 failures)
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"coder-3","agent_role":"coder"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "Task re-claimable after failure"

# Complete it this time
RUN5_ID=$(echo "$RESP" | sed '$d' | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
LEASE5_TOKEN=$(echo "$RESP" | sed '$d' | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE5_TOKEN" \
    -d '{"trigger":"complete"}' \
    "$BASE/runs/$RUN5_ID/transition")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "Complete after retry"

# ===== 8. Artifacts =====
echo ""
echo "=== 8. Artifacts ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"task_id\":\"$TASK1_ID\",\"kind\":\"code\",\"uri\":\"file:///output/main.zig\",\"size_bytes\":2048}" \
    "$BASE/artifacts")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /artifacts"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/artifacts?task_id=$TASK1_ID")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "GET /artifacts?task_id=..."

# ===== 9. No tasks for non-existent role =====
echo ""
echo "=== 9. Edge Cases ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"nobody","agent_role":"nonexistent"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
assert_status 204 "$CODE" "No tasks for unknown role"

# 404
RESP=$(curl -s -w "\n%{http_code}" "$BASE/nonexistent")
CODE=$(echo "$RESP" | tail -1)
assert_status 404 "$CODE" "404 for unknown path"

# ===== 10. Final Health =====
echo ""
echo "=== 10. Final Health Check ==="
RESP=$(curl -s -w "\n%{http_code}" "$BASE/health")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /health (final)"
echo "  Health: $BODY"

# ===== Summary =====
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

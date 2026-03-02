#!/usr/bin/env bash
set -euo pipefail

# E2E test for nulltickets
# Tests full pipeline flow: create pipeline → create tasks → claim → events → transition → fail

PORT=${PORT:-7799}
DB="/tmp/nulltickets_e2e_$$.db"
BIN="./zig-out/bin/nulltickets"
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
echo "Building nulltickets..."
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

# ===== 1.1 OpenAPI Discovery =====
echo ""
echo "=== 1.1 OpenAPI Discovery ==="
RESP=$(curl -s -w "\n%{http_code}" "$BASE/openapi.json")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /openapi.json"
assert_json "$BODY" "data['openapi']" "3.1.0" "openapi version"
assert_json "$BODY" "\"/v1/traces\" in data['paths']" "True" "openapi exposes /v1/traces"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/.well-known/openapi.json")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "GET /.well-known/openapi.json"

# ===== 1.2 OpenTelemetry OTLP =====
echo ""
echo "=== 1.2 OpenTelemetry OTLP ==="
OTLP_JSON='{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "nulltickets-e2e" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "e2e", "version": "1.0.0" },
          "spans": [
            {
              "traceId": "0123456789abcdef0123456789abcdef",
              "spanId": "0123456789abcdef",
              "name": "e2e.ingest",
              "kind": 2,
              "startTimeUnixNano": "1735689600000000000",
              "endTimeUnixNano": "1735689601000000000",
              "attributes": [
                { "key": "nulltickets.run_id", "value": { "stringValue": "run-e2e" } },
                { "key": "nulltickets.task_id", "value": { "stringValue": "task-e2e" } }
              ],
              "status": { "code": 1, "message": "ok" }
            }
          ]
        }
      ]
    }
  ]
}'
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$OTLP_JSON" "$BASE/v1/traces")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /v1/traces"
assert_json "$BODY" "str(data['accepted_spans'])" "1" "OTLP json accepted 1 span"
assert_json "$BODY" "data['stored']" "json" "OTLP json stored mode"

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/x-protobuf" --data-binary "abc" "$BASE/otlp/v1/traces")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /otlp/v1/traces (protobuf)"
assert_json "$BODY" "str(data['accepted_spans'])" "0" "OTLP protobuf accepted 0 parsed spans"
assert_json "$BODY" "data['stored']" "blob" "OTLP protobuf stored mode"

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
      { "from": "coding",   "to": "review",  "trigger": "complete", "required_gates": ["tests_passed"] },
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
TASK_COUNT=$(echo "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['items']))")
assert_json "{\"count\":$TASK_COUNT}" "data['count']" "3" "3 tasks in research"

# Get task detail
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks/$TASK1_ID")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks/{id}"
assert_json "$BODY" "data['stage']" "research" "task starts in research stage"

# ===== 3.1 Dependency Blocking =====
echo ""
echo "=== 3.1 Dependencies ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Blocked Task\",\"description\":\"Should be blocked by dependency\",\"priority\":100,\"dependencies\":[\"$TASK3_ID\"]}" \
    "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /tasks (blocked dependency task)"
BLOCKED_TASK_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks/$BLOCKED_TASK_ID/dependencies")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks/{id}/dependencies"
assert_json "$BODY" "str(len(data))" "1" "dependency count"
assert_json "$BODY" "str(data[0]['resolved'])" "False" "dependency unresolved initially"

# ===== 3.2 Idempotency-Key =====
echo ""
echo "=== 3.2 Idempotency-Key ==="
IDEMP_PAYLOAD="{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Idempotent Task\",\"description\":\"Created once\",\"priority\":1}"
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -H "Idempotency-Key: idem-task-1" \
    -d "$IDEMP_PAYLOAD" "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /tasks with Idempotency-Key"
IDEMP_ID_A=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -H "Idempotency-Key: idem-task-1" \
    -d "$IDEMP_PAYLOAD" "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "Retry POST /tasks with same Idempotency-Key"
IDEMP_ID_B=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
assert_json "{\"id\":\"$IDEMP_ID_B\"}" "data['id']" "$IDEMP_ID_A" "same idempotent response id"

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -H "Idempotency-Key: idem-task-1" \
    -d "{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Different\",\"description\":\"Different\",\"priority\":1}" "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
assert_status 409 "$CODE" "Idempotency conflict on different payload"

# ===== 3.3 Bulk Create =====
echo ""
echo "=== 3.3 Bulk Create ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"tasks\":[{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Bulk A\",\"description\":\"Bulk A\"},{\"pipeline_id\":\"$PIPELINE_ID\",\"title\":\"Bulk B\",\"description\":\"Bulk B\"}]}" \
    "$BASE/tasks/bulk")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /tasks/bulk"
assert_json "$BODY" "str(len(data['ids']))" "2" "bulk created two tasks"

# ===== 3.4 Cursor Pagination (tasks) =====
echo ""
echo "=== 3.4 Tasks Pagination ==="
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks?stage=research&limit=2")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks paginated first page"
assert_json "$BODY" "str(len(data['items']))" "2" "tasks first page size"
NEXT_CURSOR=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_cursor') or '')")
if [ -n "$NEXT_CURSOR" ]; then
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks?stage=research&limit=2&cursor=$NEXT_CURSOR")
    CODE=$(echo "$RESP" | tail -1)
    assert_status 200 "$CODE" "GET /tasks paginated second page"
fi

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
assert_json "$BODY" "str(len(data['items']))" "1" "events first list has one item"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/runs/$RUN_ID/events?limit=1")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /runs/{id}/events paginated"
assert_json "$BODY" "str(len(data['items']))" "1" "events paginated size"

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

# Transition without gate should fail
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE2_TOKEN" \
    -d '{"trigger":"complete"}' \
    "$BASE/runs/$RUN2_ID/transition")
CODE=$(echo "$RESP" | tail -1)
assert_status 409 "$CODE" "POST /runs/{id}/transition blocked by required gates"

# Add gate result
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE2_TOKEN" \
    -d '{"gate":"tests_passed","status":"pass","evidence":{"tests":"ok"},"actor":"review-bot"}' \
    "$BASE/runs/$RUN2_ID/gates")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /runs/{id}/gates"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/runs/$RUN2_ID/gates")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /runs/{id}/gates"
assert_json "$BODY" "str(len(data))" "1" "gate result persisted"

# Transition: coding → review
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LEASE2_TOKEN" \
    -d '{"trigger":"complete","expected_stage":"coding","expected_task_version":2}' \
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
    -d '{"gate":"tests_passed","status":"pass","evidence":{"tests":"ok"}}' \
    "$BASE/runs/$RUN5_ID/gates")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /runs/{id}/gates before retry completion"

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
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /artifacts?task_id=..."
assert_json "$BODY" "str(len(data['items']))" "1" "artifacts list has one item"

# Add second artifact and verify cursor pagination
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"task_id\":\"$TASK1_ID\",\"kind\":\"log\",\"uri\":\"file:///output/log.txt\",\"size_bytes\":1024}" \
    "$BASE/artifacts")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /artifacts (second artifact)"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/artifacts?task_id=$TASK1_ID&limit=1")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /artifacts paginated"
assert_json "$BODY" "str(len(data['items']))" "1" "artifacts paginated size"

# ===== 8.1 Retry policy + dead letter =====
echo ""
echo "=== 8.1 Dead Letter Policy ==="
DEAD_PIPELINE='{
  "name": "deadletter-pipeline",
  "definition": {
    "initial": "coding",
    "states": {
      "coding": { "agent_role": "dl-coder" },
      "done": { "terminal": true }
    },
    "transitions": [
      { "from": "coding", "to": "done", "trigger": "complete" }
    ]
  }
}'
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$DEAD_PIPELINE" "$BASE/pipelines")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /pipelines (deadletter)"
DEAD_PIPELINE_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"pipeline_id\":\"$DEAD_PIPELINE_ID\",\"title\":\"Dead Task\",\"description\":\"Should dead-letter\",\"retry_policy\":{\"max_attempts\":1,\"retry_delay_ms\":0,\"dead_letter_stage\":\"done\"}}" \
    "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /tasks with retry policy"
DEAD_TASK_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"dl-coder-1","agent_role":"dl-coder"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "POST /leases/claim (dl-coder)"
DEAD_RUN_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['run']['id'])")
DEAD_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['lease_token'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEAD_TOKEN" \
    -d '{"error":"intentional failure"}' \
    "$BASE/runs/$DEAD_RUN_ID/fail")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "POST /runs/{id}/fail (dead-letter task)"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks/$DEAD_TASK_ID")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks/{id} dead-letter task"
assert_json "$BODY" "data['stage']" "done" "task moved to dead_letter_stage"
assert_json "$BODY" "data['dead_letter_reason']" "max_attempts_exceeded" "dead letter reason set"

# ===== 8.2 Optional assignments =====
echo ""
echo "=== 8.2 Optional Assignments ==="
ASSIGN_PIPELINE='{
  "name": "assign-pipeline",
  "definition": {
    "initial": "todo",
    "states": {
      "todo": { "agent_role": "assignee-role" },
      "done": { "terminal": true }
    },
    "transitions": [
      { "from": "todo", "to": "done", "trigger": "complete" }
    ]
  }
}'
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$ASSIGN_PIPELINE" "$BASE/pipelines")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /pipelines (assign)"
ASSIGN_PIPELINE_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"pipeline_id\":\"$ASSIGN_PIPELINE_ID\",\"title\":\"Assigned Task\",\"description\":\"Assigned to worker-2\",\"assigned_agent_id\":\"worker-2\"}" \
    "$BASE/tasks")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 201 "$CODE" "POST /tasks with assigned_agent_id"
ASSIGNED_TASK_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"worker-1","agent_role":"assignee-role"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
assert_status 204 "$CODE" "Assigned task not claimable by other agent"

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"worker-1","assigned_by":"orchestrator"}' \
    "$BASE/tasks/$ASSIGNED_TASK_ID/assignments")
CODE=$(echo "$RESP" | tail -1)
assert_status 201 "$CODE" "POST /tasks/{id}/assignments"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/tasks/$ASSIGNED_TASK_ID/assignments")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /tasks/{id}/assignments"
assert_json "$BODY" "str(len(data))" "2" "assignment history includes records"

RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"agent_id":"worker-1","agent_role":"assignee-role"}' \
    "$BASE/leases/claim")
CODE=$(echo "$RESP" | tail -1)
assert_status 200 "$CODE" "Assigned task claimable by assigned agent"

# ===== 8.3 Queue Ops =====
echo ""
echo "=== 8.3 Queue Ops ==="
RESP=$(curl -s -w "\n%{http_code}" "$BASE/ops/queue")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_status 200 "$CODE" "GET /ops/queue"
assert_json "$BODY" "str(len(data['roles']) > 0)" "True" "queue roles present"

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

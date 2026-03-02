# Agent Lifecycle

## Claim-Work Loop

Agents are expected to run a continuous loop:

1. `POST /leases/claim`
2. If `204`, sleep and retry later
3. If `200`, execute work for the returned run
4. Send periodic heartbeat while working
5. Report events, then transition or fail
6. Repeat from step 1

## Lease Behavior

- Lease is required for protected run operations.
- Heartbeat extends lease expiration.
- Expired leases are cleaned during claim flow.
- Expired runs are marked stale when cleanup occurs.

## Failure and Retry

- `POST /runs/{id}/fail` marks run as failed and releases lease.
- Task retry behavior is controlled by task retry policy:
  - `retry_delay_ms` schedules next eligibility
  - `max_attempts` limits retries
  - `dead_letter_stage` (optional) reroutes exhausted tasks
- Exhausted tasks set `dead_letter_reason` and emit `dead_letter` events.

## Handoff Between Roles

When a transition moves task stage to a different `agent_role`, the next role can
claim the task in its next poll cycle. This enables role-based asynchronous handoff.

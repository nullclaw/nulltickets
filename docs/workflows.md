# Workflows

## Model

`nullTickets` uses pipeline definitions to model workflow stages and transitions.
Each task belongs to one pipeline and has exactly one active stage at a time.

## Pipeline Definition

Required fields:

- `initial`: initial stage id
- `states`: map of stage id to metadata
- `transitions`: allowed edges (`from`, `to`, `trigger`)

State metadata supports:

- `agent_role`: role that can claim tasks in this stage
- `description`: optional description
- `terminal`: whether this stage is terminal

## Transition Rules

- Every transition must reference existing states.
- At least one terminal state is required.
- Every non-terminal state must have at least one outgoing transition.

## Suggested Authoring Pattern

1. Start with minimal stages (`research -> coding -> review -> done`).
2. Assign one `agent_role` per non-terminal stage.
3. Keep triggers explicit and stable (`complete`, `reject`, `approve`).
4. Add loop-back transitions (`review -> coding`) for rework.

## Operational Notes

- Claim eligibility depends on current stage `agent_role`.
- Claim excludes tasks blocked by unresolved dependencies.
- Claim excludes tasks assigned to another agent.
- Claim excludes tasks that are not yet eligible by retry delay.
- Stage changes only happen through `/runs/{id}/transition`.
- Transitions can enforce optimistic checks: `expected_stage` and `expected_task_version`.
- Failed runs apply retry policy (`max_attempts`, `retry_delay_ms`) and may move task to `dead_letter_stage`.

## Dependencies (DAG)

- Add edge: `POST /tasks/{id}/dependencies`
- Inspect: `GET /tasks/{id}/dependencies`

Dependencies are resolved only when the upstream task reaches a terminal pipeline stage.

## Assignments (Optional)

- Assign: `POST /tasks/{id}/assignments`
- List: `GET /tasks/{id}/assignments`
- Unassign: `DELETE /tasks/{id}/assignments/{agent_id}`

Assignments are optional and intended for multi-agent orchestration.

## No-Orchestrator Baseline

You can run `nullTickets` with one agent loop and no external orchestrator:

1. Create a simple pipeline (`todo -> done`) with one `agent_role`.
2. Add many tasks (for example 100 tasks).
3. Run one worker loop that repeatedly claims, executes, and transitions tasks.

This is enough for sequential autonomous execution.

## When To Add Orchestrator

Add an external orchestrator only when you need:

- Multiple agents and dynamic assignments
- Global prioritization and capacity balancing
- Advanced retry/escalation policies
- Queue observability via `GET /ops/queue`

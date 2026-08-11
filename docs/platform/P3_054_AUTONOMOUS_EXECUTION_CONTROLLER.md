# P3-054 – Autonomous SIS Execution Controller / Supersupervisor Runtime

Stand: 2026-08-11

## Goal

P3-054 adds a persistent DEV/TEST orchestration consumer for the canonical controller worker `sis.controller.orchestration` while preserving the existing separation of responsibility:

`User -> SIS Execution Controller -> sis.supervisor -> Jobs -> specialized Workers -> Independent Reviewer -> Supervisor Completion Gate -> Execution Controller -> User`

The controller only starts, observes, recovers, and stops orchestration. `sis.supervisor` remains responsible for planning and delegation.

## Runtime model

### Persistent controller consumer

The controller loop is durable in PostgreSQL and is driven in DEV/TEST by `pg_cron` once per minute.

Runtime state is stored in `sis_controller_runtime_state` with:

- environment (`dev` / `test` only),
- logical lease owner,
- heartbeat,
- lease expiry,
- recovery count,
- last tick/error state.

Each `sis_supervisor_activations` request is converted into one durable `sis_controller_dispatches` row. The controller claims activations through the existing `sis_execution_controller_supervisor_claim_v1` contract instead of bypassing it.

### Supervisor dispatch lease

A bound `sis.supervisor` runtime claims a dispatch through `sis_supervisor_dispatch_claim_v1`. The claim has a lease token, heartbeat, expiry, and recovery counter. Expired supervisor leases return to `awaiting_supervisor` on the next controller tick.

The supervisor submits a plan through `sis_supervisor_dispatch_submit_plan_v1`. That function delegates every job through the existing `sis_agent_supervisor_queue_job_v1` contract; the controller never selects a specialized worker itself.

### Runtime API

DEV and TEST `sis-agent-runtime-*` Edge Functions expose these JWT-protected routes in runtime version 2:

- `POST /orchestration/claim`
- `POST /orchestration/heartbeat`
- `POST /orchestration/submit-plan`

The database RPCs verify that `auth.uid()` is the active runtime binding for `sis.supervisor` in the matching environment. Direct table access remains denied.

## v1 autonomy boundary

P3-054 v1 is intentionally conservative. Autonomous plans may use only:

- `database.read`
- `runtime.read`
- `finance.read`
- `integration.provider_read`

`database.migration`, repository writes, provider writes, destructive capabilities, external financial writes, and other capabilities fail closed before any job is queued.

This is a DEV/TEST autonomy bootstrap, not a P3-048 authorization cutover and not a PROD autonomy activation.

## Stop / cancel

`sis_controller_consumer_stop_v1` uses the controller's `orchestration.stop` capability. It cancels only job IDs stored on the selected controller dispatch, then marks the dispatch and activation cancelled. It does not scan or cancel unrelated work-item jobs.

## TEST activation

The DEV/TEST runtime activation is operational configuration, not part of the portable schema migration. The current TEST project has these active `pg_cron` jobs:

- `sis-controller-consumer-dev-v1` -> every minute
- `sis-controller-consumer-test-v1` -> every minute

Each invokes `sis_controller_consumer_tick_v1(<environment>, now(), 50, 120)`.

Keeping the cron activation outside the migration prevents a future schema promotion from implicitly activating an autonomous PROD consumer.

## Verified TEST evidence

Two synthetic TEST activations were used under `P3-054-TEST-FIXTURE`.

### Safe plan flow

Activation `9d209cff-f864-4f66-b1ce-8ea9f36cd51f`:

1. controller start returned `requested`,
2. consumer tick claimed the activation and created dispatch `2c358444-9985-4f2c-b6df-12d86bb59510`,
3. bound `sis.supervisor` claimed the dispatch,
4. a single `runtime.read` job was submitted through `sis_agent_supervisor_queue_job_v1`,
5. job `79279b26-9e5c-4904-8cfd-54c77981ac03` was assigned to `sis.worker.runtime`, with no approval required and no review required,
6. controller stop cancelled exactly that queued job and the activation.

No provider write or PROD action occurred.

### Lease recovery and write-block flow

Activation `9287c930-bc5d-4316-bec9-8c656008fe9c` / dispatch `5bc6f27e-1c3b-4b99-a49b-7fdc6eadc118`:

- a deliberately expired supervisor lease was recovered on the next controller tick (`recovered=1`),
- the dispatch was reclaimable with a new lease token,
- heartbeat extension succeeded,
- a plan requesting `database.migration` failed with `P3_054_CAPABILITY_NOT_IN_DEV_TEST_AUTONOMY_ALLOWLIST`,
- zero forbidden migration jobs were created,
- the fixture activation was cancelled after the test.

### Scheduler evidence

Both controller cron jobs have completed successful runs. The loop is therefore active rather than only manually callable.

## Security boundary

P3-054 v1 does not authorize or perform:

- PROD autonomous controller activation,
- customer PROD workload activation,
- P3-048 authorization cutover,
- provider writes,
- external financial writes,
- destructive changes,
- repository writes,
- database migrations through the autonomous planner,
- removal or weakening of downstream approval/review gates.

P3-048 remains separately `in_progress` and shadow-only.

## Current limitation / next stage

The persistent controller loop is autonomous and the supervisor dispatch contract is live. The actual reasoning process for `sis.supervisor` remains the bound supervisor runtime client: it must claim a dispatch and submit a structured plan through the JWT-protected runtime route. P3-054 v1 does not embed a public or unauthenticated always-on LLM invocation inside PostgreSQL or an Edge Function.

A later P3-054 stage may add a dedicated continuously running supervisor model process, but it must preserve the same runtime binding, lease, allowlist, review, approval, and P3-048 gates.

# P3-049 Phase 2 — Agents SDK Human-in-the-Loop

Status: TEST-only verified, no authorization cutover, no provider write, no PROD promotion.

## Contract

P3-048 remains the authorization decision source. `APPROVAL_REQUIRED` is mapped to an Agents SDK interruption. The paused `RunState` is serialized server-side and later restored for approve/reject and resume.

The resolver path is serialized by a database-side atomic resolution claim before the SDK state is mutated:

`pending_approval -> resolution claim -> RunState approve/reject -> resume -> atomic finalize`

The claim is stored as `resolution_claim_id`, `resolution_claim_decision`, `resolution_claimed_at`, and `resolution_claimed_by` on `sis_agent_hitl_runs`.

## Concurrency invariant

`public.sis_agent_hitl_resolution_claim_v1(...)` locks the HITL row and creates exactly one durable decision claim.

- First `approve` claim wins: any later `reject` receives `RESOLUTION_ALREADY_CLAIMED`.
- First `reject` claim wins: any later `approve` receives `RESOLUTION_ALREADY_CLAIMED`.
- Repeating the same decision returns the same claim idempotently.
- Finalization requires the same claim id.
- An approve finalization requires `tool_execution_count = 1`.
- A reject finalization requires `tool_execution_count = 0`.

This removes the previous window in which approve and reject could independently restore the same pending `RunState` before either final status CAS was written.

## Canonical action fingerprint

For approve, the claim derives the action fingerprint server-side from the immutable HITL scope (`hitl_id`, environment, resource, action, tool and tool-call id) using SHA-256. A caller does not choose the canonical fingerprint.

P3-049's evidence-only tool is claim-bound. P3-050 further binds its effect ledger to this same claim and canonical fingerprint.

## TEST regression evidence

Verified after the atomic-claim change:

- `approve_then_reject`: approve wins; reject fails `RESOLUTION_ALREADY_CLAIMED`; exactly one evidence effect after approve.
- `reject_then_approve`: reject wins; approve fails `RESOLUTION_ALREADY_CLAIMED`; zero evidence effects.
- `approve_then_approve`: second approve returns the same claim idempotently.
- duplicate effect under the same approve claim remains idempotent.
- non-canonical fingerprint is rejected by the P3-050 compatibility layer.
- existing crash/recovery suite remains 5/5 green after the claim change.

## Safety boundary

This phase does not activate Gmail or Make writes. `P3-048` remains shadow/non-enforcing for the Gmail-trash contract. The GMA-002 trash executor remains disabled and real mail writes still require separate explicit authorization.

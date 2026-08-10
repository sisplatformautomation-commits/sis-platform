# P3-050 — SIS-native Crash/Recovery Critical Tests

Date: 2026-08-11 (Europe/Berlin)

Scope: `P3-049 + Supabase + Agents RunState`, after introduction of the P3-049 atomic HITL resolution claim.

Safety invariants: TEST only; no Gmail/Make/provider write; no PROD change; no external financial write.

## Result

The native durability suite remains **5/5 PASS** after the concurrency fix.

1. `pause_process_exit_then_resume` — PASS. Persisted pending state can be claimed and completed in a later transaction/process boundary.
2. `resume_after_runtime_version_change` — PASS. A state marked as originating from the prior runtime version completed under Edge function version 6 without changing the durable contract.
3. `duplicate_approval_idempotency` — PASS. Repeating the same approve decision returns the same resolution claim; effect/finalize are idempotent.
4. `crash_after_effect_commit_before_ack` — PASS. After the effect committed and finalization was intentionally omitted, re-entry returned the same approve claim, replayed the existing effect, and finalized normally. Exactly one effect row remained with replay count 1 and tool execution count 1.
5. `orphan_pending_timeout_recovery` — PASS. The real TEST `pg_cron` sweeper marked the expired fixture `expired_recoverable` before the manual sweep ran. RunState was preserved, controlled recovery issued a new lease, and the run was subsequently rejected with zero effects.

## Concurrency regression

The new decision serialization is also verified:

- `approve_then_reject_single_winner` — PASS. Approve claim created; later Reject returned `RESOLUTION_ALREADY_CLAIMED`; final state `approved_resumed`; exactly one effect.
- `reject_then_approve_single_winner` — PASS. Reject claim created; later Approve returned `RESOLUTION_ALREADY_CLAIMED`; final state `rejected_resumed`; zero effects.
- `same_approve_idempotent` — PASS. Second Approve returned the same claim id; duplicate effect was replay-only; duplicate finalization was idempotent.
- `fingerprint_mismatch_rejected` — PASS. The compatibility effect RPC rejected a non-canonical fingerprint with `HITL_ACTION_FINGERPRINT_NOT_CANONICAL`.

## Architecture consequence

The resolution decision is now durably claimed before `RunState.approve()` or `RunState.reject()` is applied. P3-050 binds its effect ledger to the same approve claim and server-derived canonical action fingerprint. A Reject claim can never commit an effect through the durability RPC.

The current SIS-native durability bar therefore remains satisfied. Temporal and Restate remain fallback evaluation assets rather than required runtime dependencies.

## Boundary

The evidence-only effect is internal and constrained to `provider_write_performed=false` / `mail_write_performed=false`. Real external provider writes still require provider/action-specific idempotency semantics before claiming exactly-once external behavior.

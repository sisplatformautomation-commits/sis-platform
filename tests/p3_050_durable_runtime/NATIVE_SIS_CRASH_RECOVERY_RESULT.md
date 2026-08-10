# P3-050 — SIS-native Crash/Recovery Critical Tests

Date: 2026-08-11 (Europe/Berlin)

Scope: current P3-049 durability semantics (`Supabase + Agents RunState`) before selecting Temporal or Restate.

Safety invariants: TEST only; no Gmail/Make/provider write; no PROD change; no external financial write.

## Result

3 of 5 critical cases pass.

1. `pause_process_exit_then_resume` — PASS. Serialized state survives a process boundary and resumes.
2. `resume_after_runtime_version_change` — PASS. Compatible persisted state resumes after a runtime-version change.
3. `duplicate_approval_idempotency` — PASS. A second resolution is rejected and the evidence effect remains exactly once.
4. `crash_after_effect_commit_before_ack` — FAIL. Current semantics fail closed, but a retry cannot finalize the run after the evidence effect has already committed; the committed effect is treated as an error instead of replayable success.
5. `orphan_pending_timeout_recovery` — FAIL. The current HITL state model has no lease/expiry/sweeper transition, so a stale pending approval remains pending indefinitely.

## Interpretation

The native SIS approach is already adequate for persisted pause/resume, service/runtime restart and duplicate approval protection. It is not yet sufficient for the two hardest durability guarantees: commit-before-ack recovery and automatic stale-run recovery.

The next step should therefore harden these two points in TEST and rerun this exact five-case suite. Temporal/Restate evaluation should remain paused until the native path either passes the bar or demonstrably cannot meet it without comparable orchestration complexity.

No engine selection is made by this result.

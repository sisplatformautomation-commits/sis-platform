# P3-050 — SIS-native Crash/Recovery Critical Tests

Date: 2026-08-11 (Europe/Berlin)

Scope: hardened P3-049 durability semantics (`Supabase + Agents RunState`) before selecting Temporal or Restate.

Safety invariants: TEST only; no Gmail/Make/provider write; no PROD change; no external financial write.

## Hardening implemented

1. Replay-safe evidence-effect ledger keyed by a stable SHA-256 action fingerprint. A retry after commit-before-ack returns the previously committed result rather than executing the effect again.
2. Approval lease fields on durable HITL runs plus a service-role-only expiry sweeper and controlled recovery RPC. Expiry never approves or executes the action; the serialized RunState remains persisted.
3. TEST `pg_cron` sweeper runs every five minutes.
4. `sis-agent-hitl-test` version 5 uses the new ledger and lease semantics while keeping P3-048 as the authorization decision source.

## Result

**5 of 5 critical cases pass.**

1. `pause_process_exit_then_resume` — PASS. Serialized state survives a process boundary and resumes.
2. `resume_after_runtime_version_change` — PASS. Compatible persisted state resumes after runtime version change.
3. `duplicate_approval_idempotency` — PASS. A second resolution is rejected and the evidence effect remains exactly once.
4. `crash_after_effect_commit_before_ack` — PASS. The committed effect is retained exactly once; retry returns replayed success and the pending run finalizes normally.
5. `orphan_pending_timeout_recovery` — PASS. An expired pending approval is marked `expired_recoverable` without changing approval or RunState; controlled recovery issues a new lease and the run can later resolve normally.

## Live TEST evidence for the two former gaps

- Effect commit transaction: `replay=false`, one ledger row, tool execution count 1.
- Separate retry transaction: `replay=true`, still one ledger row, replay count 1, tool execution count still 1.
- Expiry sweep: pending run moved from recovery state `active` to `expired_recoverable`; serialized state remained present; tool execution count remained 0.
- Recovery: recovery state returned to `active`, recovery count incremented, new lease issued; no approval was granted by recovery.
- All dedicated DB fixtures were deleted after verification; ledger fixture residue is zero.

## Security

- `sis_agent_hitl_effect_ledger`: RLS enabled, no permissive policies, no `anon` or `authenticated` SELECT.
- `sis_agent_hitl_effect_commit_v1`, `sis_agent_hitl_sweep_expired_v1`, and `sis_agent_hitl_recover_expired_v1`: service-role-only.
- Security Advisor added no new P3-050 WARN. The ledger has the intentional `rls_enabled_no_policy` INFO for deny-by-default access.
- Provider/Gmail write flags remain constrained to false in the TEST durability ledger.

## Interpretation

The current critical durability bar is met natively by SIS for this evidence-only HITL workflow. P3-050 therefore does **not** currently justify adding Temporal or Restate as a required runtime layer. The external-engine harness remains in the branch as a fallback benchmark if future workflows exceed the native durability envelope.

Important boundary: this result proves replay safety for the internal evidence-only action used by P3-049. Real external provider writes still require provider/action-specific idempotency semantics before claiming exactly-once external side effects.

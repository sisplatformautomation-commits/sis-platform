# P3-048 – Unified Authorization & Approval Model – Runtime Action Shadow v4

Stand: 2026-08-11
Status: TEST verified; non-enforcing; no PROD cutover.

## Ziel

Shadow v4 integrates the runtime-session / runtime-write-approval decision path into the same normalized authorization observation model used by P3-048 v3.

Legacy runtime authority remains unchanged:

- `sis_runtime_access_sessions`
- `sis_runtime_write_approvals`
- `sis_approve_runtime_write_v1`
- `sis_consume_runtime_write_approval_v1`

The new bridge never calls the consuming RPC and never creates an approval in normal operation.

## Normalized runtime-action decision

RPCs:

- `sis_authorization_shadow_runtime_action_decide_v1(session_id, write_approval_id, action_fingerprint)`
- `sis_authorization_shadow_runtime_action_evaluate_v1(session_id, write_approval_id, action_fingerprint, metadata)`

Decision enum remains:

- `ALLOW`
- `DENY`
- `APPROVAL_REQUIRED`

Rules:

- valid active runtime session + approved, unexpired, same-session approval + exact fingerprint -> `ALLOW`
- missing/unknown/inactive/expired runtime session -> `APPROVAL_REQUIRED`
- missing/unknown/wrong-session/non-active/expired approval -> `APPROVAL_REQUIRED`
- missing action fingerprint -> `DENY`
- approval fingerprint mismatch -> `DENY`

`legacy_allow` is computed as the exact non-mutating predicate that would allow `sis_consume_runtime_write_approval_v1` to succeed. The consuming RPC is not invoked by the shadow bridge.

The normalized shadow scope is `runtime_write`.

## Evidence storage

Runtime-action evaluations are appended through the service-role-only evaluate RPC to the existing P3-048 v3 evidence table:

`public.sis_authorization_shadow_approval_bridge_evaluations`

`source_type` is extended with `runtime_action_approval`.

Direct table access remains denied to `anon`, `authenticated`, and `service_role`.

## Observed real TEST flow

The append-only SIS event log contains an earlier actual TEST runtime-approval lifecycle:

- Event 106: `runtime.session_opened`
- Event 108: `runtime.write_approved`
- environment: `test`
- action: `update_doc_fixture`

The corresponding mutable session/approval rows had already been cleaned up before this v4 work. Therefore this historical flow is used as lifecycle evidence only; v4 does not fabricate a current decision from missing source rows.

## TEST v4 regression

A temporary TEST runtime fixture was used only to exercise the read-only decision bridge.

Cases:

1. active session + valid matching approval -> `ALLOW`: PASS
2. approval fingerprint mismatch -> `DENY`: PASS
3. missing write approval -> `APPROVAL_REQUIRED`: PASS
4. revoked session / revoked approval -> `APPROVAL_REQUIRED`: PASS

Aggregate runtime-action evidence:

- runtime-action parity PASS: 4
- runtime-action parity FAIL: 0
- prior v3 parity PASS retained: 7
- combined observed parity evidence: 11 PASS / 0 FAIL

Security verification:

- `anon` execute on runtime shadow decide RPC: false
- `authenticated` execute: false
- `service_role` execute: true
- direct `service_role` SELECT on evidence table: false
- approval consumption by shadow bridge: false
- provider calls: 0
- worker execution: 0
- external financial writes: 0
- PROD changes: 0

All mutable runtime fixture rows were removed after regression: runtime environment = 0, runtime sessions = 0, runtime approvals = 0.

## Test harness note

The initial regression invocation used PostgreSQL composite expansion syntax `(function()).*` for a composite-returning session RPC. PostgreSQL can evaluate such an expression more than once; in this run it created multiple TEST-only fixture session rows and corresponding append-only `runtime.session_opened` audit events.

The duplicate mutable session rows were immediately removed before the approval regression. No provider action, worker action, approval consumption, or PROD action occurred. The audit events remain intentionally append-only and identify the fixture actor. Subsequent calls use `SELECT * FROM function(...)` to guarantee one invocation.

## Security boundary

Shadow v4 does not:

- replace `sis_consume_runtime_write_approval_v1`,
- create or consume runtime approvals,
- weaken session expiry or step-up rules,
- remove job-level or ASOG approval gates,
- activate provider writes,
- change PROD schema/runtime,
- perform P3-048 cutover.

## Next P3-048 step

After v3 + v4 merge, continue collecting real DEV/TEST parity evidence across the unified resource, job, ASOG, and runtime-action surfaces. If parity remains stable, prepare a separate cutover proposal that derives legacy work-item gate fields from the unified decision model. Any provider-write activation, legacy-gate removal, PROD cutover, or security weakening remains separately approval-gated.

# P3-048 – Unified Authorization & Approval Model – Shadow v3

Stand: 2026-08-11
Status: TEST verified; non-enforcing; no PROD cutover.

## Ziel

Shadow v3 integrates the two remaining legacy approval decision surfaces into the unified authorization observation model without changing authority:

- job-level approvals: `sis_agent_job_approvals` + `sis_agent_job_approval_ok_v1`
- provider-specific Make PROD approvals: `asog_make_approval_requests` + `asog_make_consume_prod_approval`

The legacy paths remain authoritative. Shadow v3 only computes normalized decisions and records parity evidence.

## Normalized decision contract

Decision enum:

- `ALLOW`
- `DENY`
- `APPROVAL_REQUIRED`

Every bridge result contains:

- `policy_version = p3_048_shadow_v3`
- `enforced = false`
- source type/id and environment
- `legacy_allow`
- normalized shadow `decision`
- `parity`
- `approval_required`
- `approval_valid`
- required approval scopes
- reason codes
- source-state summary
- risk summary

## Job-level approval bridge

RPCs:

- `sis_authorization_shadow_job_approval_decide_v1(job_id)`
- `sis_authorization_shadow_job_approval_evaluate_v1(job_id, metadata)`

Rules:

- approval not required -> `ALLOW`
- required scopes missing -> `DENY`
- required approval missing/expired -> `APPROVAL_REQUIRED`
- latest valid explicit deny for any scope -> `DENY`
- every required scope validly granted -> `ALLOW`

Parity is measured against `sis_agent_job_approval_ok_v1`; false legacy results remain distinguishable in shadow as either `DENY` or `APPROVAL_REQUIRED`.

## ASOG Make PROD approval bridge

RPCs:

- `sis_authorization_shadow_asog_approval_decide_v1(approval_id, actual_state_hash)`
- `sis_authorization_shadow_asog_approval_evaluate_v1(approval_id, actual_state_hash, metadata)`

This bridge is read-only and never calls `asog_make_consume_prod_approval`.

Rules:

- pending -> `APPROVAL_REQUIRED`
- expired -> `APPROVAL_REQUIRED`
- approved + valid expiry + matching state hash -> `ALLOW`
- state-hash mismatch -> `DENY`
- rejected/cancelled/consumed -> `DENY`

Mapped shadow scopes are `execute`, `prod_promotion`, and `provider_write`. This mapping is observational only and does not grant any scope.

## Evidence storage

Append-only-style shadow evidence is written through SECURITY DEFINER evaluate RPCs to:

`public.sis_authorization_shadow_approval_bridge_evaluations`

Direct table access is denied to `anon`, `authenticated`, and `service_role`; the bridge RPCs are executable only by `service_role`.

## TEST regression

Verified on `sis-platform-test`.

Job-level cases:

1. approval not required -> `ALLOW`: PASS
2. required approval missing -> `APPROVAL_REQUIRED`: PASS
3. one required scope explicitly denied -> `DENY`: PASS
4. all required scopes granted -> `ALLOW`: PASS

ASOG cases:

5. pending approval -> `APPROVAL_REQUIRED`: PASS
6. approved + matching state hash -> `ALLOW`: PASS
7. approved + state-hash mismatch -> `DENY`: PASS

Aggregate evidence:

- parity PASS: 7
- parity FAIL: 0
- worker attempts: 0
- provider actions: 0
- external financial writes: 0
- PROD changes: 0

Fixture source rows were removed where mutable. The synthetic job/work-item fixture was cancelled rather than deleted because the SIS job-event log is append-only. Temporary job approval rows and ASOG approval rows were removed.

## Security boundary

- no legacy gate is removed or weakened
- no approval record is created by the new bridge in normal operation
- no approval is consumed
- no provider call is made
- no worker is started
- no PROD schema/runtime change is made
- no P3-048 cutover is performed
- Gmail trash remains disabled and shadow-only
- P3-045 review/approval gates remain authoritative

## Next P3-048 step

Observe the bridge against additional real DEV/TEST flows and consolidate runtime-action approval semantics into the same normalized contract. Only after sustained parity should an explicit cutover proposal be prepared. Any executable provider-write activation, legacy-gate removal, PROD cutover, or security weakening still requires separate explicit approval.

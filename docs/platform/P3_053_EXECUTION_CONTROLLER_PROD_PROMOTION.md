# P3-053 – SIS Execution Controller PROD Promotion

Stand: 2026-08-11
Status: PROD promotion explicitly authorized by user; TEST regression verified; PROD deployment pending branch merge.

## Ziel

P3-053 promotes the canonical SIS Execution Controller from DEV/TEST-only availability to controlled PROD availability.

Canonical flow remains:

`User -> SIS Router -> sis.controller.orchestration -> Supervisor Activation -> sis.supervisor -> P3-045 Job Queue -> specialized worker -> review -> completion gate`

The promotion does not turn the controller into a domain worker and does not grant provider, repository, database, runtime, finance, approval-creation, or destructive capabilities.

## PROD capability boundary

`sis.controller.orchestration` receives exactly these PROD grants:

- `orchestration.start`
- `orchestration.observe`
- `orchestration.stop`

The controller remains a logical orchestration role. `sis.supervisor` remains responsible for planning/delegation, and P3-045 remains authoritative for worker selection, review, and action-level approval scopes.

## Migration

`20260811005327_p3_053_execution_controller_prod_promotion_v1`

The migration:

1. requires the P3-052 canonical controller to exist,
2. expands `sis_supervisor_activations.environment_key` to `dev`, `test`, `prod`,
3. grants only the three orchestration capabilities to the controller in PROD,
4. updates `sis_execution_controller_start_v1` to allow PROD while keeping explicit execution intent mandatory,
5. keeps the RPC service-role only.

## TEST promotion regression

Verified on `sis-platform-test` using the PROD environment key without provider execution.

PASS:

- PROD controller grants = 3
- PROD non-orchestration controller grants = 0
- `anon` start execute = false
- `authenticated` start execute = false
- `service_role` start execute = true
- PROD activation create = PASS
- repeated PROD start is idempotent = PASS
- PROD supervisor claim = PASS
- claim created no job = PASS
- missing execution intent rejected with `EXPLICIT_EXECUTION_INTENT_REQUIRED` = PASS
- UAT rejected with `EXECUTION_CONTROLLER_ENVIRONMENT_NOT_ALLOWED` = PASS
- test fixture cleanup = PASS

### Downstream approval-gate proof

A PROD regression job requiring `database.migration` was queued only to verify gate behavior and was never executed.

Observed:

- assigned worker: `sis.worker.database`
- reviewer: `sis.reviewer.qa_security`
- review required: true
- job status: `blocked`
- approval required: true
- required scopes: `execute`, `prod_promotion`
- `sis_agent_job_approval_ok_v1` returned false
- approval rows: 0
- attempts: 0

The regression job/assignment were cancelled after verification; the activation was completed and the fixture Work Item cancelled. Audit events remain as evidence.

## Authorization boundary

The PROD promotion was explicitly requested by the user after P3-052 was merged. P3-048 remains in shadow/consolidation mode; this promotion does not perform P3-048 cutover, remove legacy gates, enable provider writes, or weaken security.

Future PROD jobs still receive their P3-045 approval scopes based on required capabilities. Provider-write, external-financial-write, destructive, and PROD-promotion gates are not bypassed by the controller.

## Remaining deployment step

Merge the P3-053 branch to `main`, then apply the already-merged P3-052 baseline, P3-052 identity migration, and P3-053 PROD-promotion migration to the PROD control-plane project. Verify controller grants, RPC ACL, activation behavior, and downstream blocked-job approval behavior before marking P3-053 complete.

# P3-047 – Control → TEST Execution Bridge v1

Status: implemented and live-verified for the P3-046 Make DEV inventory job. PROD runtime promotion is not part of this change.

## Purpose

Connect a queued job in the central SIS Control Plane to a concrete role-bound runtime in the TEST Execution Plane without exposing central lease tokens or service-role credentials to the model/runtime.

## Trust model

- TEST Supabase Auth is the machine-identity issuer for the concrete agent runtime.
- The central bridge validates the TEST JWT against TEST Auth.
- The central database maps the validated `auth_subject` to an explicitly provisioned worker/reviewer binding.
- The central lease token is generated and stored only in `sis_control_execution_sessions` and is never returned to the worker.
- Worker and reviewer identities are separate; self-review remains forbidden.
- Provider access remains behind P3-043 resource/action guards.

## P3-046 binding

The bridge is intentionally narrow for the first consumer:

- work item: `P3-046`
- job type: `make_dev_read_inventory`
- job id: `0e90d6ed-337d-4382-aae6-cef841c8a641`
- worker: `sis.worker.integration`
- reviewer: `sis.reviewer.qa_security`
- environment: `dev`
- required resource: `make.inventory.dev.sis_platform`
- provider writes: forbidden
- external financial writes: forbidden
- PROD changes: forbidden

## Lifecycle

1. Worker presents its TEST JWT to `sis-control-execution-bridge-dev`.
2. Bridge validates the JWT against TEST Auth and resolves the server-side binding.
3. Claim creates a central attempt with a concrete `runtime_ref`; lease token remains server-side.
4. Worker uses the P3-043 guarded Make read gateway for provider reads.
5. Worker records central steps and heartbeats through the bridge.
6. Worker submits the sanitized inventory result.
7. Independent `sis.reviewer.qa_security` subject reads review context and submits `pass`, `changes_required`, or `fail`.

## Live verification – 2026-08-10

Recovered attempt #1 was `timed_out` with `LEASE_EXPIRED`. Attempt #2 executed through the new bridge and completed successfully:

- runtime ref present: yes
- seven inventory steps: 7/7 succeeded
- DEV scenarios: 13
- active DEV scenarios: 10
- blueprint summaries: 13
- total blueprint modules: 61
- raw blueprints returned: no
- connections: 11, metadata only
- hooks: 3, URLs omitted
- worker JWT login: verified
- reviewer JWT login: verified
- independent QA/security review: pass
- final job state: `succeeded`
- final assignment state: `accepted`
- provider writes: 0
- external financial writes: 0
- PROD changes: 0
- secrets exposed: no
- access tokens persisted: no

## Security properties

The bridge tables have RLS enabled and no client policies. Direct `anon`/`authenticated` table access is revoked. Lifecycle RPCs are service-role only and are called from the central Edge Function after cross-project JWT validation. The Edge Function returns a session identifier but never a lease token or service-role credential.

Concrete auth-subject UUIDs are environment data and are deliberately not committed to the repository.

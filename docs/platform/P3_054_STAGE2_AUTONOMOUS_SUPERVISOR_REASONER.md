# P3-054 Stage 2 – Autonomous `sis.supervisor` Reasoner

Stand: 2026-08-11
Status: code-ready on feature branch; DEV/TEST deployment and continuous scheduler activation are pending a runtime security gate.

## Goal

Stage 2 adds a model-backed reasoning step to the existing P3-054 orchestration contract without changing the responsibility boundary:

`User -> SIS Execution Controller -> sis.supervisor -> Jobs -> specialized Workers -> Independent Reviewer -> Supervisor Completion Gate -> Execution Controller -> User`

The SIS Execution Controller continues to start, observe, recover and stop orchestration. `sis.supervisor` remains the only planning/delegation layer.

## Runtime route

Both existing JWT-protected agent runtimes gain:

- `POST /orchestration/reason`

The route executes under the already bound `sis.supervisor` auth subject and calls only existing P3-054/P3-045 RPC contracts:

1. `sis_supervisor_dispatch_claim_v1`
2. model reasoning through the OpenAI Responses API
3. `sis_supervisor_dispatch_submit_plan_v1`

No direct service-role planning path is introduced.

## Model configuration

Stage 2 intentionally has **no hardcoded fallback model**. `SIS_SUPERVISOR_MODEL` must be explicitly configured to a currently approved OpenAI API model before the reasoner can claim a dispatch.

If `SIS_SUPERVISOR_MODEL` is missing or blank, the route fails closed with `SIS_SUPERVISOR_MODEL_MISSING` and performs no claim or model call. This avoids silently depending on a stale or unverified model identifier.

Stage 2 uses low reasoning effort for the bootstrap because model calls occur only after a durable dispatch has been claimed, not while the controller is idle.

Requests use `store: false` and a strict JSON-schema plan response.

## Explicit activation opt-in

Stage 2 does not reason over every dispatch automatically. The activation must contain:

```json
{
  "reasoner_mode": "read_only_autonomous"
}
```

Without this marker, the reasoner refuses to plan. The dispatch remains recoverable through the existing P3-054 lease-recovery path.

## Stage-2 autonomy boundary

The model may produce exactly one job per reasoning invocation.

Allowed capabilities:

- `database.read`
- `runtime.read`
- `finance.read`
- `integration.provider_read`

The route never accepts:

- database migrations,
- repository writes,
- provider writes,
- external financial writes,
- destructive changes,
- PROD autonomous actions,
- P3-048 cutover actions.

`integration.provider_read` additionally requires non-empty `required_resource_keys`, and every requested resource must already be listed in `activation_metadata.resource_keys`.

The downstream `sis_supervisor_dispatch_submit_plan_v1` contract remains authoritative and delegates through `sis_agent_supervisor_queue_job_v1`, so worker selection, independent review and approval requirements remain outside the model.

## Prompt-injection / secret boundary

Dispatch context is treated as untrusted data. The reasoner instructions explicitly forbid treating work-item content as higher-priority instructions.

Before model submission, nested context is depth/length limited and fields whose names indicate tokens, secrets, passwords, authorization values, credentials or API keys are removed.

The model response can describe only a strict one-job schema; it cannot emit executable SQL, provider credentials or arbitrary tool calls.

## Failure behavior

If model configuration is missing, model output is invalid, the activation lacks the explicit reasoner mode, or the model attempts a capability/resource outside the allowlist:

- no job is submitted,
- no provider call occurs,
- missing model configuration fails before a dispatch is claimed,
- otherwise the dispatch remains protected by its supervisor lease,
- the existing controller lease-recovery path can return it to `awaiting_supervisor` after expiry.

Stage 2 intentionally does not add a new privileged "mark blocked" RPC in this phase.

## Current deployment gate

During implementation, the connected Supabase control plane rejected the following runtime mutations before execution:

- a new service-role-only reasoner DB core,
- a custom-auth scheduled reasoner Edge Function,
- a small authenticated blocked-dispatch RPC,
- deployment of the JWT-only v3 runtime source.

Therefore no claim is made that Stage 2 is already running in DEV/TEST. Stage 1 remains active and unchanged.

The code in this branch is designed to deploy by replacing the current DEV/TEST `sis-agent-runtime-*` v2 source while retaining `verify_jwt=true`.

## Continuous reasoner requirement

A fully autonomous Stage 2 still needs a safe scheduler identity capable of invoking `/orchestration/reason` as the bound `sis.supervisor` subject. The scheduler must not introduce an unauthenticated admin path or embed a privileged token in repository source.

Acceptable future activation paths include:

1. a platform-approved internal scheduler that can mint/use the existing supervisor runtime identity, or
2. a Supabase-supported secret-backed scheduler setup approved by the runtime security gate.

Until that gate exists, the Reasoner route is code-ready but not continuously scheduled.

## Verification after deployment

Before enabling a continuous scheduler:

1. Confirm `verify_jwt=true` on both DEV/TEST agent runtime functions.
2. Confirm `OPENAI_API_KEY` is present without exposing its value.
3. Explicitly configure `SIS_SUPERVISOR_MODEL` to a currently approved and available OpenAI API model; there is no fallback model.
4. Create a TEST-only fixture activation with `reasoner_mode=read_only_autonomous` and a `runtime.read`-only objective.
5. Invoke `/orchestration/reason` with the bound TEST `sis.supervisor` identity.
6. Verify exactly one job is planned through `sis_agent_supervisor_queue_job_v1`.
7. Verify the controller did not choose the worker.
8. Verify no provider write, external financial write, repository write, migration or PROD action occurred.
9. Verify invalid/missing reasoner mode yields zero jobs and is recovered through lease expiry.
10. Only then enable a continuous scheduler.

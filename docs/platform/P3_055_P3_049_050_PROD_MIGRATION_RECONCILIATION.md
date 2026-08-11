# P3-055 – P3-049/P3-050 PROD Migration Reconciliation

Stand: 2026-08-11

## Scope

Promote the canonical P3-049 Agent Runtime Observability/HITL migration chain followed by the canonical P3-050 native durable HITL migration chain into the SIS PROD control-plane database.

This is a schema and migration-history reconciliation. It does **not** activate a customer PROD workload, a PROD HITL runtime, provider writes, external financial writes, or the P3-048 authorization cutover.

## Canonical promotion order

P3-049:

1. `20260810212558_p3_049_agents_sdk_trace_projection_v1`
2. `20260810214547_p3_049_agents_sdk_hitl_state_v1`
3. `20260810214711_p3_049_hitl_resolver_role_v1`
4. `20260810214719_p3_049_hitl_trace_metadata_v1`
5. `20260810215621_p3_049_hitl_canonicalize_runstate_trace_v1`
6. `20260810224030_p3_049_hitl_atomic_resolution_claim_v1`

P3-050:

7. `20260810224122_p3_050_native_hitl_durability_hardening_v1`
8. `20260810224154_p3_050_hitl_expiry_sweeper_schedule_v1`
9. `20260810230607_p3_050_hitl_claim_lease_effect_binding_v2`

Production safety follow-up:

10. `20260811070000_p3_055_p3_049_050_prod_reconciliation_safety_v1`

## Production safety boundary

The historical P3-049/P3-050 schema remains constrained to DEV/TEST environment keys. Promotion is therefore not equivalent to PROD runtime activation.

The canonical P3-050 schedule migration creates a TEST-only cron job named `sis-agent-hitl-expiry-sweeper-test`. P3-055 immediately removes this job after the canonical migration chain so the PROD control plane does not retain a TEST scheduler.

No Agents SDK HITL edge function is promoted by this database migration reconciliation.

## Approval boundary

The user explicitly approved the P3-049 -> P3-050 PROD migration promotion on 2026-08-11. That approval is scoped to this migration reconciliation only.

It does not approve:

- P3-048 authorization cutover,
- removal or weakening of legacy approval gates,
- provider writes,
- customer PROD activation,
- external financial writes,
- autonomous/background controller runtime activation.

## Verification requirements

After deployment verify:

- all nine canonical P3-049/P3-050 migration versions are present in PROD history,
- the P3-055 safety migration is present,
- `sis_agent_hitl_runs` and `sis_agent_hitl_effect_ledger` exist,
- PROD environment values remain disallowed by the historical HITL tables,
- no PROD HITL rows exist,
- the TEST HITL cron job is absent,
- HITL RPCs remain service-role only,
- anon/authenticated access remains denied,
- no provider/worker/customer execution is triggered by the migration.

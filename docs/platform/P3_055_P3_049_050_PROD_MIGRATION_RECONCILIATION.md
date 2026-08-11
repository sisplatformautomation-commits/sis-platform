# P3-055 – P3-049/P3-050 PROD Migration Reconciliation

Stand: 2026-08-11
Status: completed and verified in PROD.

## Scope

The canonical P3-049 Agent Runtime Observability/HITL migration chain followed by the canonical P3-050 native durable HITL migration chain has been promoted into the SIS PROD control-plane database.

This was a schema and migration-history reconciliation. It did **not** activate a customer PROD workload, a PROD HITL runtime, provider writes, external financial writes, or the P3-048 authorization cutover.

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

All ten versions are present in PROD under their canonical Git migration versions. Supabase's temporary runtime migration versions were history-aligned after successful execution; the schema was not rerun during that history alignment.

## Production safety boundary

The historical P3-049/P3-050 schema remains constrained to `dev` / `test` environment keys. Promotion is therefore not equivalent to PROD runtime activation.

The canonical P3-050 schedule migration created the TEST-only cron job `sis-agent-hitl-expiry-sweeper-test`. P3-055 removed that job immediately after the canonical chain. Final verification found zero remaining TEST sweeper jobs and zero sweeper runs during the promotion window.

No Agents SDK HITL edge function was promoted by this database migration reconciliation.

## PROD verification

PASS:

- canonical reconciled migration versions: 10/10
- `sis_agent_trace_runs`: present
- `sis_agent_trace_spans`: present
- `sis_agent_hitl_runs`: present
- `sis_agent_hitl_effect_ledger`: present
- resolution-claim RPC: present
- claimed-effect commit RPC: present
- expiry-sweep RPC: present
- HITL rows after promotion: 0
- effect-ledger rows after promotion: 0
- trace rows after promotion: 0
- TEST HITL cron jobs after safety migration: 0
- TEST HITL sweeper runs during promotion: 0
- HITL environment constraint: `dev` / `test` only
- effect-ledger environment constraint: `dev` / `test` only
- anon direct HITL/effect reads: denied
- authenticated direct HITL/effect reads: denied
- anon/authenticated claim/effect RPC execution: denied
- service-role claim/effect RPC execution: allowed

P3-048 remained unchanged throughout the promotion: `in_progress`, `prod_promoted=false`, `cutover_performed=false`.

## Approval boundary

The user explicitly approved the P3-049 -> P3-050 PROD migration promotion on 2026-08-11. That approval was consumed for this migration reconciliation only.

It did not approve:

- P3-048 authorization cutover,
- removal or weakening of legacy approval gates,
- provider writes,
- customer PROD activation,
- external financial writes,
- autonomous/background controller runtime activation.

## Remaining migration hygiene

The earlier P3-049/P3-050 PROD migration gap is resolved.

Global `main` -> PROD migration history is still intentionally not fully aligned because the P3-048 migration set remains absent from PROD. Do not run a broad automatic migration sync without reconciling the P3-048 authorization/cutover boundary first.

## Final state

P3-049 and P3-050 are schema/history-promoted in PROD but their HITL runtime remains inactive. This matches the current platform priority: SIS optimization and platform hardening first, without implying any customer project is live in PROD.

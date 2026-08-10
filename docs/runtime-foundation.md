# SIS Runtime Foundation

Status: DEV/repository preparation only. No Supabase migration in this branch may be applied to PROD without explicit approval.

## Purpose

The runtime foundation separates the central SIS control plane from customer runtime access. A runtime environment is scoped to one customer and one environment. Runtime access starts in READ/CHECK mode after fresh step-up authentication. WRITE requires a separate short-lived approval whose fingerprint must match the intended action.

The repository currently contains:

- `20260810012500_customer_runtime_foundation.sql`: runtime environments, access sessions, write approvals, gateway RPCs, RLS/grants and start-menu integration.
- `20260810091000_runtime_write_approval_consume.sql`: atomic single-use consumption for write approvals.
- `supabase/tests/runtime_write_approval_contract.sql`: disposable DEV/TEST contract test; creates only synthetic rows inside a transaction and rolls them back.

## Safety invariants

1. Customer/environment switches never inherit an existing runtime session; a new session requires fresh step-up authentication.
2. Runtime sessions authorize only READ/CHECK.
3. WRITE requires a separately authenticated approval bound to a concrete action fingerprint.
4. A write approval is single-use: `sis_consume_runtime_write_approval_v1` atomically changes `approved` to `consumed`. A second consume of the same approval fails.
5. Runtime tables are RLS-enabled and direct access for `public`, `anon`, and `authenticated` is revoked; gateway RPC execution is limited to `service_role`.
6. No passwords, access tokens, API secrets, bank credentials, or full customer documents belong in runtime metadata or audit payloads.
7. External customer rollout targets dedicated Make organization and dedicated Supabase project per customer/environment. Existing shared/internal states must be represented honestly as legacy/shared until migrated.
8. PROD mutations, external writes and real customer provisioning always remain behind explicit approval gates.

## Validation sequence

Before any database application, compare the migration assumptions with the live schema read-only. In particular confirm:

- `sis_customers(id, customer_key, display_name, status)` and its allowed status values.
- `sis_deployments(customer_id, environment, updated_at)` and the customer/environment constraints.
- `sis_events` accepts the runtime event taxonomy and severity values (`info`, `notice`, `warning`).
- the existing event append-only protection permits inserts from SECURITY DEFINER RPCs.

For an approved disposable DEV/TEST database:

1. Apply the base runtime migration.
2. Apply the single-use approval migration.
3. Run `supabase/tests/runtime_write_approval_contract.sql`.
4. Verify the first consume succeeds, the second consume fails, status is `consumed`, `consumed_at` is set, and `runtime.write_approval_consumed` exists.
5. Run Supabase Security and Performance Advisors after DDL.
6. Do not promote to PROD until the test and advisor findings are reviewed and explicitly approved.

## Current live-state note (2026-08-10)

The connected Supabase project was inspected read-only before this documentation update. The runtime environment, runtime session and runtime write-approval tables from the feature migration were not present at that time. Therefore the feature is repository-prepared but not live-applied, and no Supabase write was performed as part of this iteration.

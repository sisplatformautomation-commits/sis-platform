# SIS Runtime Foundation

Status: Runtime-specific DEV/TEST validation completed on the existing Supabase preview branch `sis-platform-test`. No runtime migration from this feature branch has been applied to PROD, and no real customer runtime resource was created or changed.

A separate platform-level empty-project replay blocker remains: the current main migration `email_assistant_profiles` is data-dependent and fails on a data-less preview branch when its expected legacy Business Case rows are absent. This blocker is not caused by the Runtime Foundation migrations and is documented below.

## Purpose

The runtime foundation separates the central SIS control plane from customer runtime access. A runtime environment is scoped to one customer and one environment. Runtime access starts in READ/CHECK mode after fresh step-up authentication. WRITE requires a separate short-lived approval whose fingerprint must match the intended action.

The repository currently contains:

- `20260810012500_customer_runtime_foundation.sql`: runtime environments, access sessions, write approvals, gateway RPCs, RLS/grants and start-menu integration.
- `20260810091000_runtime_write_approval_consume.sql`: atomic single-use consumption for write approvals.
- `20260810094000_runtime_service_role_table_lockdown.sql`: removes direct runtime table mutation rights from `service_role` and keeps SELECT plus gateway RPC execution.
- `20260810100000_runtime_fk_covering_indexes.sql`: covering indexes for the composite runtime foreign keys reported by the Supabase performance advisor.
- `supabase/tests/runtime_write_approval_contract.sql`: single-use approval contract test using synthetic rows inside a rollback transaction.
- `supabase/tests/runtime_gateway_security_contract.sql`: least-privilege gateway contract test under `service_role`, also fully rolled back.

## Safety invariants

1. Customer/environment switches never inherit an existing runtime session; a new session requires fresh step-up authentication.
2. Runtime sessions authorize only READ/CHECK.
3. WRITE requires a separately authenticated approval bound to a concrete action fingerprint.
4. A write approval is single-use: `sis_consume_runtime_write_approval_v1` atomically changes `approved` to `consumed`. A second consume of the same approval fails.
5. Runtime tables are RLS-enabled. `public`, `anon`, and `authenticated` have no direct access. `service_role` is limited to direct SELECT and must use the SECURITY DEFINER runtime RPCs for mutations.
6. Runtime RPC execution is granted to `service_role` and revoked from `public`, `anon`, and `authenticated`.
7. No passwords, access tokens, API secrets, bank credentials, or full customer documents belong in runtime metadata or audit payloads.
8. External customer rollout targets dedicated Make organization and dedicated Supabase project per customer/environment. Existing shared/internal states must be represented honestly as legacy/shared until migrated.
9. PROD mutations, external writes and real customer provisioning always remain behind explicit approval gates.

## Write authorization sequence

1. Perform fresh step-up authentication.
2. Open a READ/CHECK runtime session with `sis_open_runtime_session_v1`.
3. Use `sis_check_runtime_action_v1` for READ/CHECK or optional WRITE preflight.
4. Perform a separate fresh step-up for the exact WRITE.
5. Create the short-lived fingerprint-bound approval with `sis_approve_runtime_write_v1`.
6. Immediately before the external mutation, call `sis_consume_runtime_write_approval_v1`.
7. Perform the external mutation only when the consume result is `consumed=true`.
8. Never treat `sis_check_runtime_action_v1` alone as the definitive WRITE authorization gate.

## Runtime validation evidence — 2026-08-10

The connected production/main Supabase project was inspected read-only first. The runtime environment, session and write-approval tables were not present there, so the feature remained unapplied to PROD.

An already existing data-less preview branch, `sis-platform-test`, was used instead of creating another billable branch. Before applying the runtime feature, the branch contained the required Runtime Foundation base objects (`sis_customers`, `sis_deployments`, `sis_events`) and was brought forward through the SIS chat bootstrap/start-menu migration level used by the runtime migration. The following runtime-specific validation completed successfully on TEST only:

1. Applied the base runtime migration, single-use consume migration, service-role lockdown migration and runtime FK index migration.
2. Ran `runtime_write_approval_contract.sql`: first consume succeeded, second consume failed, consumed state was persisted inside the transaction, and the consume audit event existed; the transaction rolled back.
3. Verified all three runtime tables have RLS enabled.
4. Found and fixed a Supabase default-ACL issue where `service_role` initially inherited direct INSERT/UPDATE/DELETE/TRUNCATE privileges on newly created runtime tables.
5. After the lockdown migration, verified `service_role` has direct SELECT but no direct INSERT, UPDATE, DELETE or TRUNCATE on all three runtime tables.
6. Verified runtime RPC EXECUTE is present for `service_role` and absent for `anon` and `authenticated`.
7. Ran `runtime_gateway_security_contract.sql` under `service_role`: direct table UPDATE was denied, stale step-up authentication was denied, READ was allowed for a fresh active session, a wrong WRITE fingerprint was denied, the correct approval was consumed once, and replay was denied; the transaction rolled back.
8. Verified the SIS start menu remains navigation-only: `execution_allowed=false`, `approval_granted=false`, `task_start_allowed=false`, runtime state `locked`, and separate WRITE approval required.
9. Ran Supabase Security and Performance Advisors after DDL. The two runtime-specific unindexed composite-FK findings disappeared after the covering-index migration. Newly created indexes are reported as unused on the empty TEST branch, which is expected before workload exists.
10. Security Advisor reports `RLS Enabled No Policy` as INFO for the runtime tables. This is intentional deny-by-default because direct grants are removed except `service_role` SELECT; runtime mutations must pass through the SECURITY DEFINER RPCs. No runtime RPC was reported by the advisor as anonymously or authenticated-user executable.
11. Existing advisor WARN findings for unrelated pre-existing functions remain outside this feature scope, including mutable `search_path` and older SECURITY DEFINER functions executable by `anon`/`authenticated`.
12. After both contract tests, zero synthetic runtime test customers, runtime environments, sessions and approvals remained.

## Current-main empty-project replay blocker — 2026-08-10

After the runtime contracts passed, the branch was checked against the then-current main migration history. Main had advanced with `20260810004840 email_assistant_profiles`, while the data-less preview branch did not contain that migration. Rebase was attempted twice and the Supabase branch controller ended in `MIGRATIONS_FAILED`; the preview database itself remained `ACTIVE_HEALTHY`.

Read-only inspection of the authoritative main migration record showed that `email_assistant_profiles` explicitly requires existing Business Cases with keys `GMBH_MAIL_ASSISTANT` and `PERSONAL_MAIL_ASSISTANT` and raises an exception if either is absent. The data-less TEST branch contains neither key. Therefore the current-main replay failure is reproducible from the migration contract itself and is not a Runtime Foundation schema or test failure.

This distinction matters:

- Runtime Foundation migrations and contracts are validated on the isolated TEST database against their required base schema.
- A complete replay of every current main migration into a data-less branch is not currently valid because of the pre-existing data-dependent `email_assistant_profiles` migration.
- Creating another data-less branch would exercise the same migration prerequisite and does not remove this blocker by itself.
- The blocker must be resolved at platform migration/bootstrap design level (for example by defining a supported seed/bootstrap prerequisite or making the consolidation migration empty-project-safe) before a full empty-project acceptance can be claimed.
- No synthetic legacy Business Cases were inserted merely to force the rebase green; the failure is kept visible as evidence.

Relevant Supabase advisor references:

- RLS without policy: https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- Unindexed foreign keys: https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys
- Mutable function search path: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable
- Anonymous SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable
- Authenticated SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable

## Remaining boundary

This migration set models and guards runtime access; it does not provision Make organizations, Supabase customer projects, secrets, customer data, or external operations. Runtime-specific TEST validation does not authorize a merge to main or application to PROD. Promotion remains a separate explicit decision. Full current-main empty-project validation additionally remains blocked by the data-dependent `email_assistant_profiles` migration described above.

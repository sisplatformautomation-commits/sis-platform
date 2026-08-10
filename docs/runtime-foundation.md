# SIS Runtime Foundation

Status: promoted to GitHub `main` and Supabase production on 2026-08-10 after successful TEST validation and explicit user approval. GitHub PR #5 merged successfully. Supabase production completed the deployment workflow and returned to `FUNCTIONS_DEPLOYED` / `ACTIVE_HEALTHY`.

## Purpose

The Runtime Foundation separates the central SIS control plane from customer runtime access. A runtime environment is scoped to one customer and one environment. Runtime access starts in READ/CHECK mode after fresh step-up authentication. WRITE requires a separate, short-lived approval whose fingerprint must match the intended action and which is consumed atomically before the external mutation.

## Promoted repository contents

- `supabase/migrations/20260810071558_customer_runtime_foundation.sql`: runtime environments, access sessions, write approvals, gateway RPCs, RLS/grants and start-menu integration.
- `supabase/migrations/20260810071613_runtime_write_approval_consume.sql`: atomic single-use consumption for write approvals.
- `supabase/migrations/20260810072608_runtime_service_role_table_lockdown.sql`: removes direct runtime table mutation rights from `service_role` and keeps SELECT plus gateway RPC execution.
- `supabase/migrations/20260810100113_runtime_fk_covering_indexes.sql`: covering indexes for the composite runtime foreign keys reported by the Supabase Performance Advisor.
- `supabase/migrations/20260810104330_email_assistant_empty_project_normalize.sql`: marker-gated normalization for synthetic empty-project Email Assistant state.
- `supabase/migrations/20260810104458_email_assistant_profile_table_lockdown.sql`: direct `service_role` access to Email Assistant profile/alias tables becomes SELECT-only.
- `supabase/bootstrap/email_assistant_empty_project_prerequisites.sql`: explicit non-PROD prerequisite seed for the historical data-dependent Email Assistant migration on data-less environments.
- `supabase/tests/runtime_write_approval_contract.sql`: single-use approval contract test using synthetic rows inside a rollback transaction.
- `supabase/tests/runtime_gateway_security_contract.sql`: least-privilege gateway contract test under `service_role`, also fully rolled back.
- `supabase/tests/email_assistant_empty_project_contract.sql`: read-only contract for aliases, state truth, start-menu safety, RLS and table privileges.
- `docs/empty-project-bootstrap.md`: supported non-PROD empty-project recovery procedure and historical-lineage limitation.

The migration filenames were aligned with the exact versions recorded on the validated `sis-platform-test` branch before promotion so repository history and deployed migration history remain consistent.

## Safety invariants

1. Customer/environment switches never inherit an existing runtime session; a new session requires fresh step-up authentication.
2. Runtime sessions authorize only READ/CHECK.
3. WRITE requires a separately authenticated approval bound to a concrete action fingerprint.
4. A write approval is single-use: `sis_consume_runtime_write_approval_v1` atomically changes `approved` to `consumed`; replay fails.
5. Runtime tables are RLS-enabled. `public`, `anon`, and `authenticated` have no direct access. `service_role` has direct SELECT only and must use the SECURITY DEFINER runtime RPCs for mutations.
6. Runtime RPC execution is granted to `service_role` and revoked from `anon` and `authenticated`.
7. No passwords, access tokens, API secrets, bank credentials, or full customer documents belong in runtime metadata or audit payloads.
8. External customer rollout targets dedicated Make organization and dedicated Supabase project per customer/environment. Existing shared/internal states are represented honestly as legacy/shared until migrated.
9. External mutations remain behind the explicit runtime WRITE approval gate; promotion of the schema does not itself authorize customer or provider writes.
10. Empty-project bootstrap rows are synthetic control-plane prerequisites only and never imply a verified mailbox, connection or external-write authorization.

## Write authorization sequence

1. Perform fresh step-up authentication.
2. Open a READ/CHECK runtime session with `sis_open_runtime_session_v1`.
3. Use `sis_check_runtime_action_v1` for READ/CHECK or optional WRITE preflight.
4. Perform a separate fresh step-up for the exact WRITE.
5. Create the short-lived fingerprint-bound approval with `sis_approve_runtime_write_v1`.
6. Immediately before the external mutation, call `sis_consume_runtime_write_approval_v1`.
7. Perform the external mutation only when the consume result is `consumed=true`.
8. Never treat `sis_check_runtime_action_v1` alone as the definitive WRITE authorization gate.

## TEST validation evidence — 2026-08-10

The existing data-less preview branch `sis-platform-test` was used. It ended at `FUNCTIONS_DEPLOYED` / `ACTIVE_HEALTHY` after the historical Email Assistant blocker was handled through the explicit synthetic prerequisite procedure.

Validation completed successfully:

- `runtime_write_approval_contract.sql`: first consume succeeded, replay failed, consumed state and audit event were present inside the transaction, then rolled back.
- `runtime_gateway_security_contract.sql`: direct `service_role` table UPDATE denied; stale step-up denied; fresh READ allowed; wrong fingerprint denied; matching approval consumed once; replay denied; transaction rolled back.
- `email_assistant_empty_project_contract.sql`: aliases, blocked synthetic state, start-menu safety, RLS and table privileges all passed.
- After Runtime tests, synthetic customers, runtimes, sessions and approvals were zero.
- Runtime composite-FK advisor findings disappeared after the covering indexes were added.
- `service_role` direct DML on Runtime and Email Assistant profile/alias tables was removed after Supabase default ACL behavior was discovered during TEST.

## Production promotion evidence — 2026-08-10

Before promotion, production had none of the six feature migrations and no Runtime tables/RPC. After explicit approval, GitHub PR #5 was merged to `main`, then the validated Supabase branch was merged to production.

Production verification after deployment:

- Production branch status: `FUNCTIONS_DEPLOYED`; project database: `ACTIVE_HEALTHY`.
- Migration history contains exactly:
  - `20260810071558 customer_runtime_foundation`
  - `20260810071613 runtime_write_approval_consume`
  - `20260810072608 runtime_service_role_table_lockdown`
  - `20260810100113 runtime_fk_covering_indexes`
  - `20260810104330 email_assistant_empty_project_normalize`
  - `20260810104458 email_assistant_profile_table_lockdown`
- `sis_runtime_environments`, `sis_runtime_access_sessions` and `sis_runtime_write_approvals` exist.
- `sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)` exists.
- `service_role` has SELECT but no INSERT/UPDATE/DELETE/TRUNCATE on all three Runtime tables.
- Runtime open/consume RPCs are executable by `service_role` and not by `anon` or `authenticated`.
- SIS start menu remains navigation-only: `execution_allowed=false`, `approval_granted=false`, `task_start_allowed=false`.
- The existing real `EMAIL_ASSISTANT` remained unchanged at `active / high / 70`; it received no synthetic bootstrap or normalization marker, proving the marker-gated normalization was a PROD no-op for real historical state.
- `service_role` is SELECT-only on `sis_business_case_profiles` and `sis_business_case_aliases` after the promoted lockdown.
- The existing internal hospitality PROD runtime was registered only as metadata with `ownership_model=legacy_shared`, `make_isolation_mode=shared`, `database_isolation_mode=shared`; no external resource was provisioned by the migration.

## Advisors after production DDL

Security Advisor reports `RLS Enabled No Policy` as INFO for Runtime and Email Assistant profile/alias tables. This is intentional for the deny-by-default direct-access model. No Runtime RPC was reported as anonymously or authenticated-user executable. Existing unrelated legacy WARN findings remain, including mutable `search_path` and older SECURITY DEFINER functions exposed to `anon`/`authenticated`.

Performance Advisor reports no Runtime composite-FK finding after promotion. Runtime indexes can appear as unused until production workload exercises them. Existing unrelated legacy performance findings remain outside this promotion.

Advisor references:

- RLS without policy: https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- Unindexed foreign keys: https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys
- Unused indexes: https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index
- Mutable function search path: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable
- Anonymous SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable
- Authenticated SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable

## Remaining boundary

The Runtime Foundation is now promoted, but it does not provision new Make organizations, new Supabase customer projects, mailboxes, secrets, customer documents or provider writes. Real customer provisioning and external mutations still require their own explicit runtime approvals and execution steps.

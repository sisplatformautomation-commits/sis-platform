# SIS Empty-Project Bootstrap: Email Assistant

Status: DEV/TEST recovery path validated on 2026-08-10. No PROD mutation was performed.

## Problem

The historical production migration `20260810004840 email_assistant_profiles` is not data-independent. Its consolidation block requires existing `GMBH_MAIL_ASSISTANT` and `PERSONAL_MAIL_ASSISTANT` Business Case rows and raises an exception when either row is absent.

A Supabase preview branch created with `with_data=false` contains the schema/migration history but not those production control-plane rows. Native replay can therefore stop at `email_assistant_profiles` even though the preview database itself remains healthy.

## Supported DEV/TEST recovery path

1. Confirm the target is a disposable/non-PROD data-less environment and that the preview database is healthy enough to accept SQL.
2. Confirm the base SIS tables `public.sis_programs` and `public.sis_business_cases` exist and that `email_assistant_profiles` has not completed.
3. Run `supabase/bootstrap/email_assistant_empty_project_prerequisites.sql`.
4. Rebase/retry the Supabase branch migration replay.
5. Confirm `email_assistant_profiles` completed and the legacy aliases resolve to `EMAIL_ASSISTANT` profiles `gmbh` and `personal`.
6. Apply `20260810105500_email_assistant_empty_project_normalize.sql` so a synthetic empty-project bootstrap is represented truthfully as blocked/progress 0 rather than inheriting production-derived active/progress 70 state from the historical migration.
7. Apply `20260810111500_email_assistant_profile_table_lockdown.sql` so direct `service_role` access to the profile/alias tables is SELECT-only.
8. Run `supabase/tests/email_assistant_empty_project_contract.sql`, then Supabase Security and Performance Advisors.

## Bootstrap seed safety

The prerequisite seed is deliberately narrow:

- It creates only synthetic SIS control-plane prerequisite rows needed by the historical migration.
- It does not copy production/customer rows.
- It does not configure mailboxes, connections, deployments, credentials, tokens, secrets or runtime resources.
- Seeded Business Cases are `blocked`, priority `normal`, progress `0` with `mail_write_allowed=false`, `external_writes_enabled=false` and `prod_changes=false`.
- Rows are marked with `bootstrap_empty_project_seed_v1=true`, `bootstrap_scope=control_plane_only` and `synthetic=true`.
- If `EMAIL_ASSISTANT` or `sis_business_case_profiles` already exists, the seed is a no-op. Re-running it after consolidation does not recreate `GMBH_MAIL_ASSISTANT`.

## Normalization safety

The normalization migration is marker-gated. It changes state only when the consolidated `EMAIL_ASSISTANT` can be traced to the synthetic empty-project bootstrap marker. Environments containing real historical Email Assistant rows without that marker are unaffected.

For a marker-gated empty project, the resulting state is:

- `EMAIL_ASSISTANT`: `blocked`, priority `normal`, progress `0`.
- Profiles `gmbh` and `personal`: both `blocked`, priority `normal`, progress `0`.
- `GMBH_MAIL_ASSISTANT`: consolidated/renamed away by the historical migration.
- `PERSONAL_MAIL_ASSISTANT`: retained only as the archived legacy shell created by the historical migration.
- Legacy aliases resolve to the correct `EMAIL_ASSISTANT` profile.
- Mail/external/PROD write flags remain false.

## TEST evidence — 2026-08-10

The existing preview branch `sis-platform-test` (`with_data=false`) was initially `MIGRATIONS_FAILED` because the two required legacy Business Cases were absent. The prerequisite seed was applied on TEST only, then the branch was rebased. The branch controller reached `FUNCTIONS_DEPLOYED` and the preview database remained `ACTIVE_HEALTHY`.

After replay, normalization and privilege lockdown:

- Migration history contains the historical `email_assistant_profiles` migration and the Runtime Foundation migrations.
- `EMAIL_ASSISTANT` and both profiles are blocked/progress 0 with synthetic bootstrap markers and all write flags false.
- Both legacy aliases resolve correctly through `sis_chat_bootstrap_context_v1`.
- `sis_chat_start_menu_v1` still returns `execution_allowed=false`, `approval_granted=false`, `task_start_allowed=false`.
- `service_role` has SELECT but no INSERT/UPDATE/DELETE/TRUNCATE on `sis_business_case_profiles` and `sis_business_case_aliases`; `anon` and `authenticated` have no direct access.
- `email_assistant_empty_project_contract.sql` passed.
- Re-running the prerequisite seed after consolidation was a no-op and did not recreate `GMBH_MAIL_ASSISTANT`.
- Runtime Foundation write-approval and gateway security contract tests were rerun after the successful current-main rebase and both passed; all synthetic Runtime test rows rolled back to zero.
- Security Advisor reports the two Email Assistant tables as `RLS Enabled No Policy` INFO. This is consistent with the deny-by-default direct-access model. No new Email Assistant-specific WARN finding was introduced.
- Performance Advisor reports no new unindexed foreign-key issue for the Email Assistant profile/alias tables. The alias index is unused on the empty TEST branch, which is expected before workload.

## Historical-lineage limitation

This recovery path fixes the operational empty-project blocker without changing PROD. It does not rewrite the already-recorded production migration history.

Therefore, a brand-new native `with_data=false` branch replaying the same historical lineage from scratch can still stop at `email_assistant_profiles` before later migrations are reached. The supported no-PROD procedure is to inject the explicit prerequisite seed into the failed/paused non-PROD preview database and retry/rebase.

Removing that recovery step entirely would require a separate platform decision and explicit PROD authorization for a migration-lineage/baseline strategy, such as a supported baseline/squash or another mechanism that makes fresh installs independent of historical production rows. No such PROD change was made here.

## Advisor references

- RLS without policy: https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- Unindexed foreign keys: https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys
- Unused indexes: https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index
- Mutable function search path: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable
- Anonymous SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable
- Authenticated SECURITY DEFINER execution: https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable

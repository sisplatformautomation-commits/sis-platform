# P3-054 Stage 2 TEST Branch Deploy and Smoke

Status: implementation PR preparation. No PROD deploy. No P3-048 cutover.

## Purpose

This runbook restores a supported deployment path for P3-054 Stage 2 when the ChatGPT Supabase connector can enumerate the persistent TEST branch but cannot run preview-project SQL or Edge Function management actions against its branch project ref.

Target boundary:

- parent / control-plane project: `uwgkwyxjuikqxsezkezj`
- persistent TEST branch: `sis-platform-test`
- TEST branch project ref: `ohoqdlufghlhmceokgpv`
- Stage 2 model: `gpt-5.6-terra`
- reasoner route: `POST /functions/v1/sis-agent-runtime-test/orchestration/reason`
- reasoner mode: `read_only_autonomous`

The workflow must never substitute the parent project when the TEST branch is unavailable.

## SIS execution boundary

The deployment remains part of P3-054 and the SIS execution model. The main chat remains owner/coordinator. Controller and supervisor responsibilities remain unchanged:

`SIS Execution Controller -> sis.supervisor -> Jobs -> specialized Workers -> Independent Reviewer -> Supervisor Completion Gate`

The Stage 2 reasoner may plan exactly one job and only with:

- `database.read`
- `runtime.read`
- `finance.read`
- `integration.provider_read`

No provider write, repository write, database migration, destructive action, external financial write, PROD autonomy, approval bypass, or P3-048 cutover is introduced.

## GitHub Actions contract

Workflow: `.github/workflows/p3-054-test-branch-stage2.yml`

Helper: `scripts/p3_054_stage2_test_branch.sh`

The workflow has two modes.

### 1. Preflight

The pull-request path is read-only. It must:

1. require a repository secret named `SUPABASE_ACCESS_TOKEN`;
2. resolve `sis-platform-test` through the Supabase CLI;
3. fail unless the returned branch project ref is exactly `ohoqdlufghlhmceokgpv`;
4. retrieve branch credentials without printing secret values;
5. verify `POSTGRES_URL_NON_POOLING` is available;
6. verify the canonical P3-054 Stage 1 tables and RPCs exist on TEST;
7. verify migration version `20260811072300` is recorded on TEST;
8. verify the runtime-binding contract supports a temporary TEST-only supervisor subject without guessing required columns;
9. verify the TEST branch has `OPENAI_API_KEY` configured, without reading or printing the secret value;
10. report current controller heartbeat/lease state and active TEST supervisor-binding count as non-secret evidence.

Any mismatch is fail-closed before deployment.

### 2. Deploy and smoke

Deployment is manual only through `workflow_dispatch`. The caller must enter the exact TEST branch ref `ohoqdlufghlhmceokgpv`.

Only after preflight PASS the workflow may:

1. set the branch-local non-secret configuration `SIS_SUPERVISOR_MODEL=gpt-5.6-terra`;
2. deploy only `sis-agent-runtime-dev` and `sis-agent-runtime-test` to the TEST branch ref;
3. verify an unauthenticated reasoner request returns HTTP 401;
4. create an ephemeral TEST Auth user;
5. add an ephemeral TEST `sis.supervisor` runtime binding without replacing an existing binding;
6. obtain a normal authenticated user JWT;
7. create a synthetic P3-054 TEST work item and activation with `reasoner_mode=read_only_autonomous`;
8. run the existing P3-054 controller tick to create the durable supervisor dispatch;
9. invoke the real Stage 2 reasoner once;
10. require a real OpenAI response, `status=observing`, the configured model, and exactly one created SIS job;
11. verify the job contains only the Stage 2 read-only allowlist and no risky capability flags;
12. stop the synthetic activation before any worker executes the generated job;
13. remove the ephemeral runtime binding and Auth user and mark the synthetic work item cancelled.

The smoke does not authorize or execute a customer workload.

## Continuous scheduler gate

Continuous reasoning is deliberately not activated by the deploy-smoke workflow.

Supabase supports scheduled Edge Function calls using `pg_cron`, `pg_net`, and credentials stored in Vault. The standard publishable-key scheduling example is insufficient for P3-054 because the reasoner RPC requires an authenticated `auth.uid()` that is actively bound to `sis.supervisor`.

Therefore a publishable/anon key must never be treated as the supervisor machine identity.

The accepted P3-054 scheduler design gate is:

- keep the existing reasoner route JWT-only;
- introduce a dedicated, rotatable TEST supervisor machine identity;
- use a service-role-protected scheduler bootstrap/invoker, or an equivalent independently reviewed mechanism, to obtain a normal user JWT for that machine identity;
- store scheduler auth material only in an approved secret store such as Supabase Vault / Edge Function secrets;
- do not expose the scheduler credential to the model, logs, repository, or user-visible output;
- independently security-review the bootstrap before scheduling it;
- activate cron only after the real Stage 2 deploy-smoke is PASS.

Until those prerequisites are implemented and reviewed, `continuous_scheduler_active` must remain `false`.

## Required repository configuration

The workflow requires the GitHub repository secret:

- `SUPABASE_ACCESS_TOKEN`

The workflow cannot create or reveal this secret. If it is absent, preflight stops before any Supabase mutation.

The TEST Supabase branch must already contain:

- `OPENAI_API_KEY`

The workflow checks only for the secret name/presence. It never reads or prints its value.

## Merge and activation boundary

Opening this implementation PR is not authorization to merge it. Merging the PR is a separate repository mutation and must follow the current SIS gate and an explicit merge instruction.

Even after merge, deployment does not happen automatically. The deploy-smoke path remains manual and requires the exact TEST-ref confirmation. Continuous scheduler activation remains a later gate after smoke PASS and independent scheduler-identity review.

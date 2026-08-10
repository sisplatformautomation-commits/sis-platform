# P3-043 – Guarded Make Inventory DEV/TEST

Status: DEV/TEST implementation verified end-to-end. PROD not promoted.

## Architecture

The runtime and provider credential are intentionally separated.

1. `sis.worker.integration` authenticates in the TEST execution plane using its role-specific Supabase Auth subject.
2. `sis-provider-make-read-dev` or `sis-provider-make-read-test` fixes the environment and validates the active runtime binding plus resource/operation allowlist through `sis_gpt_action_authorize_v1`.
3. The worker JWT is forwarded to the central `sis-make-inventory-broker`.
4. The broker independently validates that JWT against the source Supabase Auth `/auth/v1/user` endpoint.
5. The central subject allowlist requires the exact integration-worker subject for the requested environment.
6. `sis_make_inventory_broker_v1` executes only registered Make GET operations using the Make credential held exclusively in the central Vault.
7. Sanitized provider output is returned; credentials, raw blueprint content and webhook URLs are not returned.
8. Every central broker invocation is written to `sis_make_inventory_broker_audit`.

## Resources

- `make.inventory.dev.sis_platform`
- `make.inventory.test.sis_platform`

Allowed operations:

- `list_organization`
- `list_teams`
- `list_scenarios`
- `read_scenario_metadata`
- `read_scenario_blueprints`
- `read_connections_metadata`
- `read_webhook_and_schedule_metadata`

No scenario run/start/stop/update, connection write, webhook write, provider write, external financial write or PROD change is allowed.

## Credential boundary

`make_eu1_api_token` remains only in the central control-plane Vault. It is not copied to the execution-plane Vault and is never returned to the model or worker. The central broker uses it only after both source-JWT verification and subject/environment/resource guards have passed.

## Environment scope

The Make team is shared historically, so environment safety is based on explicit scenario naming markers rather than team membership.

DEV accepts only scenario names beginning `DEV |` or containing `| DEV |`.
TEST accepts only scenario names beginning `TEST |` or containing `| TEST |`.
PROD scenarios and incidental words such as `Testbeleg` do not match.

## End-to-end verification

Verified chain:

`worker credential in Vault -> Auth login -> JWT Edge Gateway -> execution-plane resource guard -> cross-project broker -> source JWT validation -> central subject allowlist -> central Vault Make credential -> Make GET -> sanitized response`

Results:

- DEV authentication HTTP 200, provider gateway HTTP 200, 13 DEV scenarios returned.
- TEST authentication HTTP 200, provider gateway HTTP 200, exactly 1 TEST scenario returned.
- PROD scenario leak count: 0.
- `TEMP - Testbeleg...` leak count: 0 after scope hardening.
- Organization inventory: passed (1 organization).
- Team inventory: passed (1 team).
- Connection metadata inventory: passed (11 sanitized connections).
- Hook metadata inventory: passed (3 hooks, URLs omitted).
- Scenario metadata read: passed.
- Blueprint read: passed; raw blueprint is not returned, only content hash and module count.
- Cross-environment subject access: denied.
- Non-allowlisted operation: denied.
- Provider writes performed: none.
- External financial writes performed: none.

The temporary E2E regression RPC used to validate credential/JWT flow was removed after verification.

## Promotion

This implementation is authorized for DEV/TEST only. PR review/merge may canonicalize the contract, but PROD provider activation or promotion requires a separate explicit user approval.

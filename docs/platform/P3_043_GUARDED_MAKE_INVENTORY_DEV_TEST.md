# P3-043 – Guarded Make Inventory DEV/TEST

Status: implemented in TEST execution plane, DEV/TEST contract active, PROD not promoted.

## Purpose

Provide a guarded Make provider-read path for SIS workers without exposing arbitrary provider URLs, provider credentials, provider writes, or production promotion.

## Runtime flow

1. A role-specific `sis.worker.integration` runtime authenticates with its bound Supabase Auth subject.
2. The environment-specific Edge Function fixes the environment (`dev` or `test`) and forwards only `resource_key`, `operation`, and structured params.
3. `public.sis_gpt_action_dispatch_v1` resolves the active runtime binding and requires `sis.worker.integration`.
4. The dispatcher resolves an active resource in `public.sis_gpt_action_resources` for the same environment.
5. The requested operation must be explicitly included in the resource's `allowed_operations`.
6. Only the `make_inventory_read_v1` guard profile is accepted for inventory resources.
7. Provider operations use GET only. Provider write, financial write, PROD access, arbitrary URLs, and cross-environment access are rejected.
8. Every provider attempt is recorded in `public.sis_gpt_action_invocations`. Provider failures are audited and fail closed.

## Registered resources

- `make.inventory.dev.sis_platform`
- `make.inventory.test.sis_platform`

Both resources allow only:

- `list_organization`
- `list_teams`
- `list_scenarios`
- `read_scenario_metadata`
- `read_scenario_blueprints`
- `read_connections_metadata`
- `read_webhook_and_schedule_metadata`

## Edge gateways

- `sis-provider-make-read-dev`
- `sis-provider-make-read-test`

Both require JWT verification. Environment selection is fixed in the function and cannot be supplied by the caller.

## Safety properties

- Worker identity comes from `auth.uid()` and active runtime binding.
- Only `sis.worker.integration` can dispatch provider reads.
- Runtime environment must equal requested resource environment.
- No free-form Make URL can be supplied.
- No Make token is returned to workers or model context.
- Connection and webhook inventory output omits secret material.
- Blueprint inventory is sanitized before return.
- PROD scenarios are excluded from DEV/TEST inventory scope.
- Provider writes and external financial writes are prohibited.
- PROD promotion requires a separate explicit approval.

## Verification completed

- Active DEV integration subject resolves only to DEV resource.
- Cross-environment dispatch is rejected.
- Non-allowlisted operations are rejected.
- Missing Make credential in TEST fails closed as `MAKE_TOKEN_MISSING`.
- The missing-credential case creates an audited failed invocation with `provider_write_allowed=false` and `external_financial_writes=false`.
- The existing Make credential in the central control plane was used only to verify the Make `/organizations` GET endpoint; no provider mutation was performed.

## Current deployment note

The TEST execution plane intentionally does not currently hold `make_eu1_api_token`. Therefore the guarded provider code is installed and security-verified, but a real Make inventory call from the TEST runtime remains blocked until an approved secret-placement/runtime-bridge design makes the provider credential available without exposing it to the model.

This is a DEV/TEST implementation only. Do not merge or promote this contract to PROD without separate explicit approval.

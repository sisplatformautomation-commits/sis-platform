# P3-049 Phase 2 — Agents SDK Human-in-the-Loop

Status: TEST-only verified, no authorization cutover, no provider write, no PROD promotion.

## Goal

Map the existing P3-048 unified shadow decision `APPROVAL_REQUIRED` to the OpenAI Agents SDK manual HITL flow:

`P3-048 decision -> tool interruption -> approve/reject -> serialize RunState -> restore RunState -> resume same run`.

Phase 2 does not replace P3-048 or any legacy enforcement gate. The GMA Gmail trash resources remain disabled and shadow-only.

## Runtime separation

- Start identity: `sis.worker.integration`, TEST runtime binding only.
- Resolve identity: `sis.supervisor`, TEST runtime binding only.
- The worker that creates the approval interruption cannot resolve it through the `/resolve` endpoint.
- Edge function: `sis-agent-hitl-test`, JWT verification enabled.
- Agents SDK: `@openai/agents@0.14.0`.

## Authorization input

The runtime does not trust a caller-supplied approval flag. `/start` calls `sis_authorization_shadow_evaluate_v2` with:

- actor `sis.worker.integration`
- environment `test`
- capability `integration.provider_write`
- action `gmail.trash`
- resource `make.gmail_trash.test.sis_internal_hospitality`
- provider write risk = true
- approval required risk = true

The pilot continues only when the returned policy is `p3_048_shadow_v2`, the decision is `APPROVAL_REQUIRED`, and the resource is `shadow_only`.

## Safe pilot tool

The Agents SDK tool is named `gma_gmail_trash_shadow_action`. It is intentionally not connected to Gmail or Make write execution.

On approved execution it only changes `sis_agent_hitl_runs.tool_execution_count` from 0 to 1 for the same pending HITL record. Database constraints permanently force these pilot flags to remain false:

- `provider_write_performed=false`
- `mail_write_performed=false`
- `execution_gate_changed=false`
- `approval_gate_changed=false`

The tool is idempotent and can execute at most once per pilot run.

## Durable RunState

Pending SDK state is serialized with `RunState.toString({ includeTracingApiKey: false })`, stored server-side, and protected with SHA-256. The public/service-facing read projection never returns the raw serialized state.

On resolution:

1. verify stored SHA-256,
2. rebuild the identical agent/tool graph,
3. restore with `RunState.fromString(agent, serializedState)`,
4. read the pending interruption,
5. call `state.approve(...)` or `state.reject(...)`,
6. resume with `run(agent, state)`,
7. verify no interruption remains,
8. verify the serialized trace ID is unchanged,
9. clear the raw serialized state after completion.

The serialized RunState trace is treated as authoritative. Direct reads of internal RunState fields are intentionally avoided.

## Verification evidence

### Approve path

- HITL ID: `76d6c2c4-e645-4f11-a5c4-cdbb0a52f7fe`
- P3-048 decision: `APPROVAL_REQUIRED`
- trace: `trace_ae425df60f404a14b2dfa21346c26d8d`
- interruption count before decision: 1
- resolution: approve
- final status: `approved_resumed`
- same trace resumed: true
- tool execution count: 1
- provider write: false
- Gmail write: false

### Reject path

- HITL ID: `429e2971-e642-426d-9da2-e1c42cc58b85`
- P3-048 decision: `APPROVAL_REQUIRED`
- trace: `trace_9fdd81e4a0db4061aa59ae61271bdba7`
- interruption count before decision: 1
- resolution: reject
- final status: `rejected_resumed`
- same trace resumed: true
- tool execution count: 0
- provider write: false
- Gmail write: false

Both completed states have separate pre-resume and post-resume SHA-256 values; raw serialized RunState is cleared after resolution.

## Security posture

`public.sis_agent_hitl_runs` has RLS enabled and no policies, and direct access is restricted to `service_role`. `sis_agent_hitl_read_v1` is service-role-only with `search_path=pg_catalog, public` and does not expose `sdk_state`.

The TEST Security Advisor introduced no new P3-049 WARN. The new state table produces the expected `rls_enabled_no_policy` INFO because the intentional posture is RLS + zero policies / deny by default.

Temporary E2E credential and one-shot helpers used during verification are not canonical runtime components and are not included in this repository. They were disabled/removed after the test.

## Non-goals / remaining gates

- no executable Gmail trash resource activation
- no Gmail or Make write
- no P3-048 enforcement cutover
- no legacy approval-gate removal
- no PROD change
- no Temporal/Restate selection in P3-049 Phase 2

# P3-049 — Agent Runtime Observability & HITL

## Phase 1: Agents SDK trace observability

Status: TEST-verified, non-enforcing.

P3-049 Phase 1 introduces OpenAI Agents SDK tracing as an observability layer only. It does not replace, bypass, weaken, or mutate the existing SIS execution or approval gates.

## Scope

- Environments: DEV/TEST only.
- Pilot flow: GMA-002 classification and policy path up to the authorization boundary.
- No Gmail write.
- No provider write.
- No PROD change.
- No external financial write.
- P3-048 remains the authorization decision layer in shadow mode.
- HITL interruptions are explicitly deferred to a later P3-049 phase.

## Trace model

The pilot trace uses:

- Trace workflow: `SIS GMA-002 Phase 1 Observability`
- Group ID: `P3-049:GMA-002`
- Root worker span: `sis.worker.integration`
- Child spans:
  - `gma.fixture_runner`
  - `gma.classification`
  - `gma.policy`
  - `p3_048.authorization_boundary`

The target architecture will later correlate SIS Work Item, Job, Attempt, Worker, Tool/Provider action, authorization decision, and review spans through common trace/group metadata.

## Data policy

Phase 1 stores sanitized metadata only. The observer filters fields whose names indicate tokens, secrets, passwords, authorization headers, message bodies, content, or prompts. No mail body, model prompt, credential, JWT, service-role secret, or provider token belongs in trace metadata.

The Agents SDK default trace exporter is replaced by a SIS custom processor through `setTraceProcessors(...)`. Phase 1 therefore persists the pilot trace into the SIS TEST trace projection rather than exporting it through the default processor.

## TEST persistence

Migration: `20260810212558_p3_049_agents_sdk_trace_projection_v1.sql`

Tables:

- `sis_agent_trace_runs`
- `sis_agent_trace_spans`

Read projection:

- `sis_agent_trace_read_v1(trace_id)`

Security posture:

- RLS enabled on both tables.
- No RLS policies: deny-by-default for exposed roles.
- `anon` and `authenticated` have no table read rights.
- `sis_agent_trace_read_v1` is service-role-only with pinned `search_path=pg_catalog, public`.

## Pilot evidence

Real safe GMA-002 DEV fixture flow:

- Make scenario: `6887250`
- Make execution: `7b3d8177b0dd4d2bb0ccb9e5610c0d09`
- Make execution status: `SUCCESS`
- Classification: `marketing`
- Marketing confidence: `0.97`
- Domain policy: `TRASH_ELIGIBLE`
- Legacy authorization: `APPROVAL_REQUIRED`
- P3-048 shadow authorization: `APPROVAL_REQUIRED`
- Mail write allowed: `false`
- Provider write performed: `false`

Verified Agents SDK trace after processor ordering fix:

- Trace ID: `trace_178ddc0b61df4cf486c68e41c25ca7ce`
- SDK: `@openai/agents@0.14.0`
- Trace status: `completed`
- Spans: `5`
- Completed spans: `5`
- Running spans: `0`
- Failed spans: `0`

An initial pilot trace exposed an asynchronous span-persistence ordering issue. The observer was corrected to serialize persistence per trace/span and to flush all pending writes before returning. The repeated trace verified 5/5 completed spans.

## Phase 1 boundaries

This implementation is not a new execution engine and not an approval engine. It only observes an already completed safe flow and records its sanitized execution structure.

The TEST observer is deployed with JWT verification enabled. It is a pilot endpoint, not a PROD-ready public ingestion surface. Any later generalization must bind ingestion to the existing SIS machine identity/runtime model rather than adding a parallel authorization layer.

## Next phase

P3-049 Phase 2 should map an authoritative P3-048 `APPROVAL_REQUIRED` result into an Agents SDK human-in-the-loop interruption, preserving the exact action fingerprint and resuming the same run only after an explicit approval/rejection decision. Phase 2 requires separate execution authorization and is not part of this change.

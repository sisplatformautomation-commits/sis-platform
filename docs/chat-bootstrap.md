# SIS Chat Bootstrap v1

## Purpose

Every SIS chat or agent run must hydrate its working context from the current SIS control-plane state before making project-specific decisions or changes.

Principle: **No execution without context hydration.**

## Source precedence

1. Supabase live machine state (`sis_business_cases`, `sis_work_items`, `sis_events`)
2. Registered canonical knowledge documents (`sis_knowledge_documents`)
3. Relevant provider/runtime evidence and regression state
4. Existing chat history as secondary context only

If a business-case summary conflicts with a newer active work item, prefer the work-item state and surface a warning instead of guessing.

## RPC

`public.sis_chat_bootstrap_context_v1(p_business_case_key text default null, p_work_item_limit integer default 8)`

The RPC is read-only and service-role only.

### Global bootstrap

```sql
select public.sis_chat_bootstrap_context_v1(null, 8);
```

Use at the start of a new SIS chat when the intended business case is not yet known.

### Scoped bootstrap

```sql
select public.sis_chat_bootstrap_context_v1('GMBH_MAIL_ASSISTANT', 8);
```

Use when the user's request already identifies a business case or after the global bootstrap has resolved one.

## Response contract

The response contains:

- `schema_version`
- `generated_at`
- `source_of_truth`
- `selection`
- `business_cases`
  - business-case summary
  - prioritized active/planned work items
  - canonical knowledge references
  - execution/safety flags
  - `summary_may_be_stale`
  - `canonical_document_missing`
- `recent_events`
- `warnings`

## Required chat behavior

1. Run the bootstrap before project-specific execution.
2. If the business case is clear, use scoped hydration; otherwise hydrate active/blocked cases and resolve the context.
3. Prefer concrete Work Item state over a stale Business Case summary.
4. Load the returned canonical documents when they are relevant to the requested work.
5. If `canonical_document_missing=true`, explicitly treat documentation as unresolved; do not invent missing policy or architecture details.
6. Respect approval and write-safety flags from the current state.
7. Only then start analysis, tool execution, or agent delegation.

## Security

- `SECURITY DEFINER` with fixed `search_path`
- execute revoked from `public`, `anon`, and `authenticated`
- execute granted only to `service_role`
- no state mutations and no bootstrap event is written merely for reading context

## Known follow-up

The knowledge registry is not yet complete for every active business case. Missing canonical documents are intentionally returned as warnings so registration can be completed without hiding the gap.

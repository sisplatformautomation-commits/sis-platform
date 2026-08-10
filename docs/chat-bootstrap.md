# SIS Chat Bootstrap v1

## Purpose

Every SIS chat or agent run must hydrate its working context from the current SIS control-plane state before making project-specific decisions or changes.

Principle: **No execution without context hydration.**

## Reserved start intent

The exact user input `SIS` is reserved for read-only navigation.

`SIS` means:

1. hydrate current SIS context,
2. show the dynamic work selection,
3. do not start, queue, claim, approve, continue, or mutate any Work Item.

`SIS` must never be interpreted as execution approval.

Selecting a Business Case or `SIS Plattform / Übergreifend` only changes working context. It also does not authorize execution.

A task start requires both:

- an explicit task/work-item reference, and
- an explicit execution verb such as `starte`, `führe aus`, or an equally unambiguous instruction.

Examples:

- `SIS` -> navigation only
- `Mail Assistant` -> context selection only
- `SIS Plattform / Übergreifend` -> cross-cutting context only
- `Starte GMA-002` -> explicit task execution request, subject to live policy/approval checks

## Source precedence

1. Supabase live machine state (`sis_business_cases`, `sis_work_items`, `sis_events`)
2. Registered canonical knowledge documents (`sis_knowledge_documents`)
3. Relevant provider/runtime evidence and regression state
4. Existing chat history as secondary context only

If a business-case summary conflicts with a newer active work item, prefer the work-item state and surface a warning instead of guessing.

## RPCs

### Start menu

`public.sis_chat_start_menu_v1(p_work_item_limit integer default 5)`

Use for the reserved `SIS` start intent. The response is explicitly non-executable and contains:

- `intent = sis_start`
- `mode = read_only_navigation`
- `execution_allowed = false`
- `approval_granted = false`
- `task_start_allowed = false`
- dynamic Business Case menu entries
- `SIS Plattform / Übergreifend`
- `Neuer Business Case`
- bootstrap warnings and source-of-truth metadata

### Bootstrap context

`public.sis_chat_bootstrap_context_v1(p_business_case_key text default null, p_work_item_limit integer default 8)`

The RPC is read-only and service-role only.

#### Global bootstrap

```sql
select public.sis_chat_bootstrap_context_v1(null, 8);
```

Use at the start of a new SIS chat when the intended business case is not yet known.

#### Scoped bootstrap

```sql
select public.sis_chat_bootstrap_context_v1('GMBH_MAIL_ASSISTANT', 8);
```

Use when the user's request already identifies a business case or after the global bootstrap has resolved one.

## Required chat behavior

1. On exact `SIS`, call `sis_chat_start_menu_v1` and show the returned selection.
2. Never treat `SIS` as task approval or execution intent.
3. Before project-specific execution, run context hydration.
4. If the business case is clear, use scoped hydration; otherwise hydrate active/blocked cases and resolve the context.
5. Prefer concrete Work Item state over a stale Business Case summary.
6. Load returned canonical documents when relevant to the requested work.
7. If `canonical_document_missing=true`, explicitly treat documentation as unresolved; do not invent missing policy or architecture details.
8. Respect approval and write-safety flags from the current state.
9. Only after explicit execution intent may analysis, tool execution, or agent delegation begin.

## Security

- both RPCs are `SECURITY DEFINER` with fixed `search_path`
- execute revoked from `public`, `anon`, and `authenticated`
- execute granted only to `service_role`
- no state mutations or bootstrap events are written merely for reading context

## Known follow-up

The knowledge registry is not yet complete for every active business case. Missing canonical documents are intentionally returned as warnings so registration can be completed without hiding the gap.

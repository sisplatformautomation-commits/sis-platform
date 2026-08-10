create or replace function public.sis_chat_bootstrap_context_v1(
  p_business_case_key text default null,
  p_work_item_limit integer default 8
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_key text := nullif(btrim(coalesce(p_business_case_key, '')), '');
  v_limit integer := greatest(1, least(coalesce(p_work_item_limit, 8), 25));
  v_result jsonb;
begin
  with business_cases as (
    select
      bc.id,
      bc.business_case_key,
      bc.name,
      bc.status,
      bc.priority,
      bc.progress,
      bc.current_step,
      bc.next_action,
      bc.blocker,
      bc.updated_at,
      bc.metadata,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'item_key', wi.item_key,
          'title', wi.title,
          'status', wi.status,
          'priority', wi.priority,
          'assigned_to', wi.assigned_to,
          'requires_approval', wi.requires_approval,
          'execution_mode', wi.execution_mode,
          'started_at', wi.started_at,
          'completed_at', wi.completed_at,
          'updated_at', wi.updated_at,
          'error_message', wi.error_message
        ) order by
          case wi.status when 'in_progress' then 1 when 'queued' then 2 when 'blocked' then 3 when 'planned' then 4 else 5 end,
          case wi.priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
          wi.execution_sequence nulls last,
          wi.updated_at desc), '[]'::jsonb)
        from (
          select w.*
          from public.sis_work_items w
          where w.business_case_id = bc.id
            and w.status in ('in_progress','queued','blocked','planned')
          order by
            case w.status when 'in_progress' then 1 when 'queued' then 2 when 'blocked' then 3 when 'planned' then 4 else 5 end,
            case w.priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
            w.execution_sequence nulls last,
            w.updated_at desc
          limit v_limit
        ) wi
      ) as work_items,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'document_type', kd.document_type,
          'title', kd.title,
          'canonical_file_id', kd.canonical_file_id,
          'status', kd.status,
          'version', kd.version,
          'verified_at', kd.verified_at,
          'updated_at', kd.updated_at
        ) order by kd.verified_at desc nulls last, kd.updated_at desc), '[]'::jsonb)
        from public.sis_knowledge_documents kd
        where kd.business_case_id = bc.id
          and kd.is_canonical = true
          and kd.status = 'published'
      ) as canonical_documents,
      not exists (
        select 1
        from public.sis_knowledge_documents kd
        where kd.business_case_id = bc.id
          and kd.is_canonical = true
          and kd.status = 'published'
      ) as canonical_document_missing,
      exists (
        select 1
        from public.sis_work_items w
        where w.business_case_id = bc.id
          and w.status in ('in_progress','queued','blocked')
          and bc.current_step is not null
          and w.item_key is not null
          and bc.current_step not ilike '%' || w.item_key || '%'
          and w.updated_at > bc.updated_at
      ) as summary_may_be_stale
    from public.sis_business_cases bc
    where bc.status in ('active','blocked')
      and (v_key is null or bc.business_case_key = v_key)
  ), recent_events as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id,
      'business_case_id', e.business_case_id,
      'work_item_id', e.work_item_id,
      'event_type', e.event_type,
      'severity', e.severity,
      'occurred_at', e.occurred_at,
      'recorded_at', e.recorded_at
    ) order by coalesce(e.occurred_at, e.created_at) desc), '[]'::jsonb) as events
    from (
      select e.*
      from public.sis_events e
      where v_key is null
         or e.business_case_id in (select id from business_cases)
      order by coalesce(e.occurred_at, e.created_at) desc
      limit 20
    ) e
  )
  select jsonb_build_object(
    'schema_version', 1,
    'generated_at', now(),
    'source_of_truth', jsonb_build_object(
      'machine_state', 'supabase',
      'human_readable_projection', 'google_drive',
      'chat_history_role', 'secondary_context'
    ),
    'selection', jsonb_build_object(
      'business_case_key', v_key,
      'mode', case when v_key is null then 'all_active' else 'single_business_case' end
    ),
    'business_cases', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id,
        'business_case_key', b.business_case_key,
        'name', b.name,
        'status', b.status,
        'priority', b.priority,
        'progress', b.progress,
        'current_step', b.current_step,
        'next_action', b.next_action,
        'blocker', b.blocker,
        'updated_at', b.updated_at,
        'work_items', b.work_items,
        'canonical_documents', b.canonical_documents,
        'canonical_document_missing', b.canonical_document_missing,
        'summary_may_be_stale', b.summary_may_be_stale,
        'context_flags', jsonb_build_object(
          'review_only', coalesce((b.metadata->>'review_only')::boolean, false),
          'mail_write_allowed', coalesce((b.metadata->>'mail_write_allowed')::boolean, false),
          'external_writes_enabled', coalesce((b.metadata->>'external_writes_enabled')::boolean, false),
          'prod_changes', coalesce((b.metadata->>'prod_changes')::boolean, false)
        )
      ) order by
        case b.priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
        b.updated_at desc)
      from business_cases b
    ), '[]'::jsonb),
    'recent_events', (select events from recent_events),
    'warnings', coalesce((
      select jsonb_agg(warning)
      from (
        select jsonb_build_object(
          'type', 'canonical_document_missing',
          'business_case_key', b.business_case_key,
          'message', 'No published canonical knowledge document is registered for this business case.'
        ) as warning
        from business_cases b
        where b.canonical_document_missing
        union all
        select jsonb_build_object(
          'type', 'business_case_summary_may_be_stale',
          'business_case_key', b.business_case_key,
          'message', 'Business-case summary may lag behind newer active work-item state; prefer work-item state.'
        ) as warning
        from business_cases b
        where b.summary_may_be_stale
      ) q
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.sis_chat_bootstrap_context_v1(text, integer) from public;
revoke all on function public.sis_chat_bootstrap_context_v1(text, integer) from anon;
revoke all on function public.sis_chat_bootstrap_context_v1(text, integer) from authenticated;
grant execute on function public.sis_chat_bootstrap_context_v1(text, integer) to service_role;

comment on function public.sis_chat_bootstrap_context_v1(text, integer) is
'Read-only SIS chat/bootstrap context hydration. Returns active business cases, prioritized work items, canonical knowledge references, recent events and consistency warnings. Service-role only.';

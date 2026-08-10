create table if not exists public.sis_business_case_profiles (
  id uuid primary key default gen_random_uuid(),
  business_case_id uuid not null references public.sis_business_cases(id) on delete cascade,
  profile_key text not null,
  name text not null,
  status text not null default 'planned' check (status = any (array['planned'::text,'active'::text,'blocked'::text,'paused'::text,'completed'::text,'archived'::text])),
  priority text not null default 'normal' check (priority = any (array['low'::text,'normal'::text,'high'::text,'critical'::text])),
  progress integer not null default 0 check (progress >= 0 and progress <= 100),
  current_step text,
  next_action text,
  blocker text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_case_id, profile_key)
);

create index if not exists sis_business_case_profiles_business_case_status_idx
  on public.sis_business_case_profiles (business_case_id, status);

create table if not exists public.sis_business_case_aliases (
  alias_key text primary key,
  business_case_id uuid not null references public.sis_business_cases(id) on delete cascade,
  profile_key text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists sis_business_case_aliases_business_case_idx
  on public.sis_business_case_aliases (business_case_id);

alter table public.sis_business_case_profiles enable row level security;
alter table public.sis_business_case_aliases enable row level security;

revoke all on public.sis_business_case_profiles from public, anon, authenticated;
revoke all on public.sis_business_case_aliases from public, anon, authenticated;
grant select on public.sis_business_case_profiles to service_role;
grant select on public.sis_business_case_aliases to service_role;

do $migration$
declare
  v_email_id uuid;
  v_personal_id uuid;
begin
  select id into v_email_id
  from public.sis_business_cases
  where business_case_key = 'GMBH_MAIL_ASSISTANT';

  select id into v_personal_id
  from public.sis_business_cases
  where business_case_key = 'PERSONAL_MAIL_ASSISTANT';

  if v_email_id is null or v_personal_id is null then
    raise exception 'Expected GMBH_MAIL_ASSISTANT and PERSONAL_MAIL_ASSISTANT business cases before consolidation';
  end if;

  insert into public.sis_business_case_profiles (
    business_case_id, profile_key, name, status, priority, progress,
    current_step, next_action, blocker, metadata
  )
  select
    v_email_id,
    'gmbh',
    'GmbH',
    status,
    priority,
    progress,
    current_step,
    next_action,
    blocker,
    jsonb_set(
      coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'profile_key', 'gmbh',
        'profile_scope', 'mailbox',
        'assistant_name', 'Email Assistant',
        'legacy_business_case_key', 'GMBH_MAIL_ASSISTANT'
      ),
      '{assistant_architecture,assistant}',
      to_jsonb('Email Assistant'::text),
      true
    )
  from public.sis_business_cases
  where id = v_email_id
  on conflict (business_case_id, profile_key) do update set
    name = excluded.name,
    status = excluded.status,
    priority = excluded.priority,
    progress = excluded.progress,
    current_step = excluded.current_step,
    next_action = excluded.next_action,
    blocker = excluded.blocker,
    metadata = excluded.metadata,
    updated_at = now();

  insert into public.sis_business_case_profiles (
    business_case_id, profile_key, name, status, priority, progress,
    current_step, next_action, blocker, metadata
  )
  select
    v_email_id,
    'personal',
    'Personal',
    status,
    priority,
    progress,
    current_step,
    next_action,
    blocker,
    jsonb_set(
      jsonb_set(
        coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'profile_key', 'personal',
          'profile_scope', 'mailbox',
          'assistant_name', 'Email Assistant',
          'legacy_business_case_key', 'PERSONAL_MAIL_ASSISTANT'
        ),
        '{assistant_architecture,assistant}',
        to_jsonb('Email Assistant'::text),
        true
      ),
      '{reusable_mail_core,source_business_case}',
      to_jsonb('EMAIL_ASSISTANT'::text),
      true
    )
  from public.sis_business_cases
  where id = v_personal_id
  on conflict (business_case_id, profile_key) do update set
    name = excluded.name,
    status = excluded.status,
    priority = excluded.priority,
    progress = excluded.progress,
    current_step = excluded.current_step,
    next_action = excluded.next_action,
    blocker = excluded.blocker,
    metadata = excluded.metadata,
    updated_at = now();

  update public.sis_work_items
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'assistant_key', 'EMAIL_ASSISTANT',
        'profile_key', 'gmbh',
        'legacy_business_case_key', 'GMBH_MAIL_ASSISTANT'
      ),
      updated_at = now()
  where business_case_id = v_email_id;

  update public.sis_work_items
  set business_case_id = v_email_id,
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'assistant_key', 'EMAIL_ASSISTANT',
        'profile_key', 'personal',
        'legacy_business_case_key', 'PERSONAL_MAIL_ASSISTANT'
      ),
      updated_at = now()
  where business_case_id = v_personal_id;

  insert into public.sis_business_case_components (
    business_case_id, component_id, usage_role, write_access_required, notes, metadata, created_at
  )
  select
    v_email_id, component_id, usage_role, write_access_required, notes, metadata, created_at
  from public.sis_business_case_components
  where business_case_id = v_personal_id
  on conflict (business_case_id, component_id) do nothing;

  delete from public.sis_business_case_components
  where business_case_id = v_personal_id;

  update public.sis_knowledge_documents
  set business_case_id = v_email_id,
      updated_at = now()
  where business_case_id = v_personal_id;

  update public.sis_deployments
  set business_case_id = v_email_id,
      updated_at = now()
  where business_case_id = v_personal_id;

  update public.sis_events
  set business_case_id = v_email_id,
      payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object(
        'profile_key', 'personal',
        'legacy_business_case_key', 'PERSONAL_MAIL_ASSISTANT'
      )
  where business_case_id = v_personal_id;

  update public.sis_business_cases
  set business_case_key = 'EMAIL_ASSISTANT',
      name = 'Email Assistant',
      description = 'Reusable Email Assistant for mailbox triage, classification, action policy, alerts and controlled downstream processing. Customer/mailbox context belongs in profiles or deployments, not in the assistant name.',
      status = 'active',
      priority = 'high',
      progress = 70,
      current_step = 'Profile GmbH active: classification and policy regression verified. Profile Personal blocked until mailbox and alert channel are verified.',
      next_action = 'Continue GmbH profile with the explicitly approved DEV write test; keep Personal profile blocked until its mailbox and alert channel are connected and verified.',
      blocker = null,
      metadata = jsonb_build_object(
        'assistant_name', 'Email Assistant',
        'canonical_role', 'assistant',
        'naming_schema_version', 'assistant-profile-agent-workflow-v2',
        'profile_model', 'sis_business_case_profiles',
        'profile_keys', jsonb_build_array('gmbh', 'personal'),
        'provider_model', 'adapter',
        'workflow_layer', 'Inbox Workflow',
        'agent_components', jsonb_build_array(
          'Mail Classification Agent',
          'Mail Action Policy Agent',
          'Mail Triage Agent',
          'Mail Processing Agent',
          'Alert Agent'
        ),
        'auto_reply', false,
        'mail_write_allowed', false,
        'external_writes_enabled', false,
        'prod_changes', false,
        'mailbox_isolation_required', true,
        'legacy_business_case_keys', jsonb_build_array('GMBH_MAIL_ASSISTANT', 'PERSONAL_MAIL_ASSISTANT')
      ),
      updated_at = now()
  where id = v_email_id;

  update public.sis_business_cases
  set name = 'Personal Mail Assistant (Legacy Profile)',
      status = 'archived',
      current_step = 'Consolidated into EMAIL_ASSISTANT profile personal.',
      next_action = null,
      blocker = null,
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'legacy_shell', true,
        'superseded_by_business_case_key', 'EMAIL_ASSISTANT',
        'superseded_profile_key', 'personal',
        'naming_schema_version', 'assistant-profile-agent-workflow-v2'
      ),
      updated_at = now()
  where id = v_personal_id;

  insert into public.sis_business_case_aliases (alias_key, business_case_id, profile_key, metadata)
  values
    ('GMBH_MAIL_ASSISTANT', v_email_id, 'gmbh', jsonb_build_object('legacy_name', 'GmbH Mail Assistant')),
    ('PERSONAL_MAIL_ASSISTANT', v_email_id, 'personal', jsonb_build_object('legacy_name', 'Personal Mail Assistant'))
  on conflict (alias_key) do update set
    business_case_id = excluded.business_case_id,
    profile_key = excluded.profile_key,
    metadata = excluded.metadata;
end
$migration$;

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
  v_requested_key text := nullif(btrim(coalesce(p_business_case_key, '')), '');
  v_key text;
  v_profile_key text;
  v_limit integer := greatest(1, least(coalesce(p_work_item_limit, 8), 25));
  v_result jsonb;
begin
  if v_requested_key is null then
    v_key := null;
  else
    select bc.business_case_key, a.profile_key
      into v_key, v_profile_key
    from public.sis_business_case_aliases a
    join public.sis_business_cases bc on bc.id = a.business_case_id
    where a.alias_key = v_requested_key;

    if not found then
      v_key := v_requested_key;
      v_profile_key := null;
    end if;
  end if;

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
          'profile_key', p.profile_key,
          'name', p.name,
          'status', p.status,
          'priority', p.priority,
          'progress', p.progress,
          'current_step', p.current_step,
          'next_action', p.next_action,
          'blocker', p.blocker,
          'updated_at', p.updated_at
        ) order by
          case p.status when 'active' then 1 when 'blocked' then 2 when 'planned' then 3 when 'paused' then 4 else 5 end,
          case p.priority when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
          p.profile_key), '[]'::jsonb)
        from public.sis_business_case_profiles p
        where p.business_case_id = bc.id
          and p.status <> 'archived'
          and (v_profile_key is null or p.profile_key = v_profile_key)
      ) as profiles,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'item_key', wi.item_key,
          'title', wi.title,
          'status', wi.status,
          'priority', wi.priority,
          'assigned_to', wi.assigned_to,
          'requires_approval', wi.requires_approval,
          'execution_mode', wi.execution_mode,
          'profile_key', wi.metadata->>'profile_key',
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
            and (v_profile_key is null or w.metadata->>'profile_key' = v_profile_key)
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
          and (v_profile_key is null or w.metadata->>'profile_key' = v_profile_key)
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
    'schema_version', 2,
    'generated_at', now(),
    'source_of_truth', jsonb_build_object(
      'machine_state', 'supabase',
      'human_readable_projection', 'google_drive',
      'chat_history_role', 'secondary_context'
    ),
    'selection', jsonb_build_object(
      'requested_business_case_key', v_requested_key,
      'business_case_key', v_key,
      'profile_key', v_profile_key,
      'mode', case when v_key is null then 'all_active' when v_profile_key is null then 'single_business_case' else 'single_profile' end
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
        'profiles', b.profiles,
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
'Read-only SIS chat/bootstrap context hydration. Resolves legacy business-case aliases, returns active business cases with profiles, prioritized work items, canonical knowledge references, recent events and consistency warnings. Service-role only.';

create or replace function public.sis_chat_start_menu_v1(
  p_work_item_limit integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_context jsonb;
  v_menu jsonb;
begin
  v_context := public.sis_chat_bootstrap_context_v1(null, greatest(1, least(coalesce(p_work_item_limit, 5), 12)));

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', 'business_case',
    'business_case_key', bc->>'business_case_key',
    'label', bc->>'name',
    'status', bc->>'status',
    'priority', bc->>'priority',
    'progress', nullif(bc->>'progress', '')::integer,
    'current_step', bc->>'current_step',
    'next_action', bc->>'next_action',
    'profiles', coalesce(bc->'profiles', '[]'::jsonb),
    'summary_may_be_stale', coalesce((bc->>'summary_may_be_stale')::boolean, false),
    'canonical_document_missing', coalesce((bc->>'canonical_document_missing')::boolean, false)
  ) order by
    case bc->>'priority' when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
    (bc->>'progress')::integer desc nulls last,
    bc->>'name'), '[]'::jsonb)
  into v_menu
  from jsonb_array_elements(coalesce(v_context->'business_cases', '[]'::jsonb)) bc;

  return jsonb_build_object(
    'schema_version', 2,
    'intent', 'sis_start',
    'mode', 'read_only_navigation',
    'execution_allowed', false,
    'approval_granted', false,
    'task_start_allowed', false,
    'generated_at', now(),
    'prompt', 'Woran möchtest du arbeiten?',
    'menu', coalesce(v_menu, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object(
        'type', 'platform',
        'key', 'SIS_PLATFORM_CROSS_CUTTING',
        'label', 'SIS Plattform / Übergreifend',
        'description', 'Architektur, Umstrukturierung, Agenten, Berechtigungen, Observability und andere programmweite Themen.'
      ),
      jsonb_build_object(
        'type', 'new',
        'key', 'NEW_BUSINESS_CASE',
        'label', 'Neuer Business Case',
        'description', 'Neuen Bedarf beschreiben; SIS ordnet ihn einem bestehenden Business Case zu oder schlägt einen neuen vor.'
      )
    ),
    'warnings', coalesce(v_context->'warnings', '[]'::jsonb),
    'source_of_truth', v_context->'source_of_truth',
    'guardrails', jsonb_build_object(
      'sis_token_is_navigation_only', true,
      'explicit_task_reference_required_for_execution', true,
      'explicit_execution_verb_required_for_execution', true,
      'business_case_selection_does_not_start_work', true,
      'platform_selection_does_not_start_work', true
    )
  );
end;
$function$;

revoke all on function public.sis_chat_start_menu_v1(integer) from public;
revoke all on function public.sis_chat_start_menu_v1(integer) from anon;
revoke all on function public.sis_chat_start_menu_v1(integer) from authenticated;
grant execute on function public.sis_chat_start_menu_v1(integer) to service_role;

comment on function public.sis_chat_start_menu_v1(integer) is
'Read-only SIS start/navigation contract. Displays canonical business cases and their profiles. The token SIS never grants approval or starts a task.';

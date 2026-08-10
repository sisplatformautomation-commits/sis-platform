-- SIS Customer Runtime Foundation v1
-- Establishes one control-plane record per customer/environment, step-up authenticated
-- runtime sessions, and separate short-lived write approvals. No secrets are stored here.

create table if not exists public.sis_runtime_environments (
  id uuid primary key default gen_random_uuid(),
  runtime_key text not null unique,
  customer_id uuid not null references public.sis_customers(id) on delete restrict,
  environment text not null,
  status text not null default 'planned',
  ownership_model text not null default 'customer_owned',
  make_organization_id text,
  make_team_id bigint,
  supabase_project_ref text,
  make_isolation_mode text not null default 'unknown',
  database_isolation_mode text not null default 'unknown',
  auth_policy jsonb not null default jsonb_build_object(
    'step_up_required', true,
    'customer_switch_reauth_required', true,
    'write_requires_separate_approval', true,
    'password_in_chat_forbidden', true,
    'session_default_minutes', 30,
    'session_max_minutes', 120
  ),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sis_runtime_environments_key_chk check (
    runtime_key = lower(btrim(runtime_key))
    and runtime_key ~ '^[a-z0-9][a-z0-9_-]*$'
  ),
  constraint sis_runtime_environments_environment_chk check (
    environment = any (array['dev'::text,'test'::text,'uat'::text,'prod'::text])
  ),
  constraint sis_runtime_environments_status_chk check (
    status = any (array['planned'::text,'provisioning'::text,'active'::text,'suspended'::text,'retired'::text])
  ),
  constraint sis_runtime_environments_ownership_chk check (
    ownership_model = any (array['customer_owned'::text,'sis_managed'::text,'legacy_shared'::text])
  ),
  constraint sis_runtime_environments_make_isolation_chk check (
    make_isolation_mode = any (array['organization_dedicated'::text,'team_dedicated'::text,'shared'::text,'unknown'::text])
  ),
  constraint sis_runtime_environments_database_isolation_chk check (
    database_isolation_mode = any (array['project_dedicated'::text,'schema_dedicated'::text,'shared'::text,'unknown'::text])
  ),
  constraint sis_runtime_environments_customer_environment_uq unique (customer_id, environment),
  constraint sis_runtime_environments_scope_uq unique (id, customer_id, environment),
  constraint sis_runtime_environments_auth_policy_chk check (
    coalesce((auth_policy->>'step_up_required')::boolean, false) = true
    and coalesce((auth_policy->>'customer_switch_reauth_required')::boolean, false) = true
    and coalesce((auth_policy->>'write_requires_separate_approval')::boolean, false) = true
    and coalesce((auth_policy->>'password_in_chat_forbidden')::boolean, false) = true
  )
);

create index if not exists sis_runtime_environments_customer_status_idx
  on public.sis_runtime_environments(customer_id, status, environment);

alter table public.sis_deployments
  add column if not exists runtime_environment_id uuid;

alter table public.sis_deployments
  drop constraint if exists sis_deployments_runtime_environment_scope_fk;

alter table public.sis_deployments
  add constraint sis_deployments_runtime_environment_scope_fk
  foreign key (runtime_environment_id, customer_id, environment)
  references public.sis_runtime_environments(id, customer_id, environment)
  on delete restrict;

create index if not exists sis_deployments_runtime_environment_idx
  on public.sis_deployments(runtime_environment_id)
  where runtime_environment_id is not null;

create table if not exists public.sis_runtime_access_sessions (
  id uuid primary key default gen_random_uuid(),
  runtime_environment_id uuid not null,
  customer_id uuid not null,
  environment text not null,
  actor_type text not null,
  actor_ref text not null,
  auth_assertion_ref text not null,
  auth_method text not null,
  auth_verified_at timestamptz not null,
  access_mode text not null default 'read_check',
  status text not null default 'active',
  opened_at timestamptz not null default now(),
  expires_at timestamptz not null,
  closed_at timestamptz,
  correlation_id uuid not null default gen_random_uuid(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sis_runtime_access_sessions_runtime_scope_fk
    foreign key (runtime_environment_id, customer_id, environment)
    references public.sis_runtime_environments(id, customer_id, environment)
    on delete restrict,
  constraint sis_runtime_access_sessions_actor_type_chk check (
    actor_type = any (array['sis_operator'::text,'customer_user'::text])
  ),
  constraint sis_runtime_access_sessions_actor_ref_chk check (btrim(actor_ref) <> ''),
  constraint sis_runtime_access_sessions_auth_ref_chk check (btrim(auth_assertion_ref) <> ''),
  constraint sis_runtime_access_sessions_auth_method_chk check (btrim(auth_method) <> ''),
  constraint sis_runtime_access_sessions_mode_chk check (access_mode = 'read_check'),
  constraint sis_runtime_access_sessions_status_chk check (
    status = any (array['active'::text,'closed'::text,'revoked'::text,'expired'::text])
  ),
  constraint sis_runtime_access_sessions_time_chk check (
    expires_at > opened_at
    and expires_at <= opened_at + interval '120 minutes'
    and auth_verified_at <= opened_at + interval '1 minute'
    and auth_verified_at >= opened_at - interval '5 minutes'
  ),
  constraint sis_runtime_access_sessions_closed_chk check (
    closed_at is null or closed_at >= opened_at
  )
);

create index if not exists sis_runtime_access_sessions_active_idx
  on public.sis_runtime_access_sessions(customer_id, environment, status, expires_at);

create table if not exists public.sis_runtime_write_approvals (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sis_runtime_access_sessions(id) on delete restrict,
  action_key text not null,
  target_ref text not null,
  action_fingerprint text not null,
  change_summary text not null,
  approved_by text not null,
  auth_assertion_ref text not null,
  auth_method text not null,
  auth_verified_at timestamptz not null,
  status text not null default 'approved',
  approved_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  constraint sis_runtime_write_approvals_action_chk check (btrim(action_key) <> ''),
  constraint sis_runtime_write_approvals_target_chk check (btrim(target_ref) <> ''),
  constraint sis_runtime_write_approvals_fingerprint_chk check (btrim(action_fingerprint) <> ''),
  constraint sis_runtime_write_approvals_summary_chk check (btrim(change_summary) <> ''),
  constraint sis_runtime_write_approvals_approved_by_chk check (btrim(approved_by) <> ''),
  constraint sis_runtime_write_approvals_auth_ref_chk check (btrim(auth_assertion_ref) <> ''),
  constraint sis_runtime_write_approvals_auth_method_chk check (btrim(auth_method) <> ''),
  constraint sis_runtime_write_approvals_status_chk check (
    status = any (array['approved'::text,'consumed'::text,'revoked'::text,'expired'::text])
  ),
  constraint sis_runtime_write_approvals_time_chk check (
    expires_at > approved_at
    and expires_at <= approved_at + interval '10 minutes'
    and auth_verified_at <= approved_at + interval '1 minute'
    and auth_verified_at >= approved_at - interval '5 minutes'
  ),
  constraint sis_runtime_write_approvals_consumed_chk check (
    consumed_at is null or consumed_at >= approved_at
  )
);

create index if not exists sis_runtime_write_approvals_session_idx
  on public.sis_runtime_write_approvals(session_id, status, expires_at);

alter table public.sis_runtime_environments enable row level security;
alter table public.sis_runtime_access_sessions enable row level security;
alter table public.sis_runtime_write_approvals enable row level security;

revoke all on public.sis_runtime_environments from public, anon, authenticated;
revoke all on public.sis_runtime_access_sessions from public, anon, authenticated;
revoke all on public.sis_runtime_write_approvals from public, anon, authenticated;

grant select on public.sis_runtime_environments to service_role;
grant select on public.sis_runtime_access_sessions to service_role;
grant select on public.sis_runtime_write_approvals to service_role;

create or replace function public.sis_open_runtime_session_v1(
  p_runtime_environment_id uuid,
  p_actor_type text,
  p_actor_ref text,
  p_auth_assertion_ref text,
  p_auth_method text,
  p_auth_verified_at timestamptz,
  p_duration_minutes integer default 30
)
returns public.sis_runtime_access_sessions
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_runtime public.sis_runtime_environments%rowtype;
  v_session public.sis_runtime_access_sessions%rowtype;
  v_actor_type text := lower(btrim(coalesce(p_actor_type,'')));
  v_duration integer := greatest(5, least(coalesce(p_duration_minutes,30),120));
begin
  if p_runtime_environment_id is null then raise exception 'runtime_environment_id_required'; end if;
  if v_actor_type not in ('sis_operator','customer_user') then raise exception 'runtime_actor_type_invalid'; end if;
  if coalesce(btrim(p_actor_ref),'')='' then raise exception 'runtime_actor_ref_required'; end if;
  if coalesce(btrim(p_auth_assertion_ref),'')='' then raise exception 'step_up_auth_assertion_required'; end if;
  if coalesce(btrim(p_auth_method),'')='' then raise exception 'step_up_auth_method_required'; end if;
  if p_auth_verified_at is null or p_auth_verified_at > now() + interval '1 minute' or p_auth_verified_at < now() - interval '5 minutes' then
    raise exception 'fresh_step_up_auth_required';
  end if;

  select * into v_runtime
  from public.sis_runtime_environments r
  where r.id = p_runtime_environment_id
  for share;

  if v_runtime.id is null then raise exception 'runtime_environment_not_found'; end if;
  if v_runtime.status <> 'active' then raise exception 'runtime_environment_not_active'; end if;
  if coalesce((v_runtime.auth_policy->>'step_up_required')::boolean,false) <> true then
    raise exception 'runtime_auth_policy_invalid';
  end if;

  -- Customer/environment switches never inherit a previous session. The caller must
  -- present a fresh authentication assertion for every new session.
  insert into public.sis_runtime_access_sessions(
    runtime_environment_id, customer_id, environment, actor_type, actor_ref,
    auth_assertion_ref, auth_method, auth_verified_at, access_mode, status, expires_at
  ) values (
    v_runtime.id, v_runtime.customer_id, v_runtime.environment, v_actor_type, btrim(p_actor_ref),
    btrim(p_auth_assertion_ref), btrim(p_auth_method), p_auth_verified_at,
    'read_check','active', now() + make_interval(mins => v_duration)
  ) returning * into v_session;

  insert into public.sis_events(
    event_type, source, payload, scope, aggregate, correlation_id, severity,
    schema_version, occurred_at, recorded_at, created_at
  ) values (
    'runtime.session_opened','sis-runtime-gateway',
    jsonb_build_object(
      'runtime_session_id',v_session.id,
      'runtime_environment_id',v_runtime.id,
      'customer_id',v_runtime.customer_id,
      'environment',v_runtime.environment,
      'actor_type',v_actor_type,
      'actor_ref',btrim(p_actor_ref),
      'auth_method',btrim(p_auth_method),
      'access_mode','read_check',
      'expires_at',v_session.expires_at
    ),
    'runtime_session','runtime_session:'||v_session.id::text,v_session.correlation_id,
    'notice',1,now(),now(),now()
  );

  return v_session;
end;
$$;

create or replace function public.sis_close_runtime_session_v1(
  p_session_id uuid,
  p_closed_by text,
  p_revoke boolean default false
)
returns public.sis_runtime_access_sessions
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_session public.sis_runtime_access_sessions%rowtype;
  v_status text;
begin
  if p_session_id is null then raise exception 'runtime_session_id_required'; end if;
  if coalesce(btrim(p_closed_by),'')='' then raise exception 'closed_by_required'; end if;

  select * into v_session
  from public.sis_runtime_access_sessions s
  where s.id=p_session_id for update;

  if v_session.id is null then raise exception 'runtime_session_not_found'; end if;
  if v_session.status <> 'active' then return v_session; end if;

  v_status := case when coalesce(p_revoke,false) then 'revoked' else 'closed' end;
  update public.sis_runtime_access_sessions
  set status=v_status, closed_at=now(), updated_at=now()
  where id=v_session.id
  returning * into v_session;

  update public.sis_runtime_write_approvals
  set status='revoked'
  where session_id=v_session.id and status='approved';

  insert into public.sis_events(
    event_type, source, payload, scope, aggregate, correlation_id, severity,
    schema_version, occurred_at, recorded_at, created_at
  ) values (
    case when v_status='revoked' then 'runtime.session_revoked' else 'runtime.session_closed' end,
    'sis-runtime-gateway',
    jsonb_build_object('runtime_session_id',v_session.id,'closed_by',btrim(p_closed_by),'status',v_status),
    'runtime_session','runtime_session:'||v_session.id::text,v_session.correlation_id,
    case when v_status='revoked' then 'warning' else 'info' end,1,now(),now(),now()
  );

  return v_session;
end;
$$;

create or replace function public.sis_approve_runtime_write_v1(
  p_session_id uuid,
  p_action_key text,
  p_target_ref text,
  p_action_fingerprint text,
  p_change_summary text,
  p_approved_by text,
  p_auth_assertion_ref text,
  p_auth_method text,
  p_auth_verified_at timestamptz,
  p_idempotency_key text,
  p_duration_minutes integer default 5
)
returns public.sis_runtime_write_approvals
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_session public.sis_runtime_access_sessions%rowtype;
  v_approval public.sis_runtime_write_approvals%rowtype;
  v_duration integer := greatest(1, least(coalesce(p_duration_minutes,5),10));
begin
  if p_session_id is null then raise exception 'runtime_session_id_required'; end if;
  if coalesce(btrim(p_action_key),'')='' then raise exception 'action_key_required'; end if;
  if coalesce(btrim(p_target_ref),'')='' then raise exception 'target_ref_required'; end if;
  if coalesce(btrim(p_action_fingerprint),'')='' then raise exception 'action_fingerprint_required'; end if;
  if coalesce(btrim(p_change_summary),'')='' then raise exception 'change_summary_required'; end if;
  if coalesce(btrim(p_approved_by),'')='' then raise exception 'approved_by_required'; end if;
  if coalesce(btrim(p_auth_assertion_ref),'')='' then raise exception 'write_step_up_auth_assertion_required'; end if;
  if coalesce(btrim(p_auth_method),'')='' then raise exception 'write_step_up_auth_method_required'; end if;
  if coalesce(btrim(p_idempotency_key),'')='' then raise exception 'idempotency_key_required'; end if;
  if p_auth_verified_at is null or p_auth_verified_at > now() + interval '1 minute' or p_auth_verified_at < now() - interval '5 minutes' then
    raise exception 'fresh_write_step_up_auth_required';
  end if;

  select * into v_session
  from public.sis_runtime_access_sessions s
  where s.id=p_session_id for update;

  if v_session.id is null then raise exception 'runtime_session_not_found'; end if;
  if v_session.status <> 'active' or v_session.expires_at <= now() then raise exception 'active_runtime_session_required'; end if;

  insert into public.sis_runtime_write_approvals(
    session_id,action_key,target_ref,action_fingerprint,change_summary,
    approved_by,auth_assertion_ref,auth_method,auth_verified_at,status,
    expires_at,idempotency_key
  ) values (
    v_session.id,btrim(p_action_key),btrim(p_target_ref),btrim(p_action_fingerprint),btrim(p_change_summary),
    btrim(p_approved_by),btrim(p_auth_assertion_ref),btrim(p_auth_method),p_auth_verified_at,'approved',
    now()+make_interval(mins=>v_duration),btrim(p_idempotency_key)
  ) returning * into v_approval;

  insert into public.sis_events(
    event_type, source, payload, scope, aggregate, correlation_id, severity,
    schema_version, occurred_at, recorded_at, created_at
  ) values (
    'runtime.write_approved','sis-runtime-gateway',
    jsonb_build_object(
      'runtime_session_id',v_session.id,
      'write_approval_id',v_approval.id,
      'customer_id',v_session.customer_id,
      'environment',v_session.environment,
      'action_key',v_approval.action_key,
      'target_ref',v_approval.target_ref,
      'action_fingerprint',v_approval.action_fingerprint,
      'approved_by',v_approval.approved_by,
      'expires_at',v_approval.expires_at
    ),
    'runtime_session','runtime_session:'||v_session.id::text,v_session.correlation_id,
    'warning',1,now(),now(),now()
  );

  return v_approval;
end;
$$;

create or replace function public.sis_check_runtime_action_v1(
  p_session_id uuid,
  p_action_mode text,
  p_action_fingerprint text default null,
  p_write_approval_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_session public.sis_runtime_access_sessions%rowtype;
  v_approval public.sis_runtime_write_approvals%rowtype;
  v_mode text := lower(btrim(coalesce(p_action_mode,'')));
  v_allowed boolean := false;
  v_reason text;
begin
  if p_session_id is null then return jsonb_build_object('allowed',false,'reason','runtime_session_required'); end if;
  if v_mode not in ('read','check','write') then return jsonb_build_object('allowed',false,'reason','action_mode_invalid'); end if;

  select * into v_session from public.sis_runtime_access_sessions s where s.id=p_session_id;
  if v_session.id is null then
    v_reason := 'runtime_session_not_found';
  elsif v_session.status <> 'active' then
    v_reason := 'runtime_session_not_active';
  elsif v_session.expires_at <= now() then
    v_reason := 'runtime_session_expired';
  elsif v_mode in ('read','check') then
    v_allowed := true; v_reason := 'active_read_check_session';
  else
    if p_write_approval_id is null or coalesce(btrim(p_action_fingerprint),'')='' then
      v_reason := 'write_approval_required';
    else
      select * into v_approval
      from public.sis_runtime_write_approvals a
      where a.id=p_write_approval_id
        and a.session_id=v_session.id
        and a.status='approved'
        and a.expires_at>now()
        and a.action_fingerprint=btrim(p_action_fingerprint);
      if v_approval.id is null then
        v_reason := 'valid_matching_write_approval_required';
      else
        v_allowed := true; v_reason := 'matching_write_approval';
      end if;
    end if;
  end if;

  insert into public.sis_events(
    event_type,source,payload,scope,aggregate,correlation_id,severity,
    schema_version,occurred_at,recorded_at,created_at
  ) values (
    'runtime.action_checked','sis-runtime-gateway',
    jsonb_build_object(
      'runtime_session_id',p_session_id,
      'action_mode',v_mode,
      'allowed',v_allowed,
      'reason',v_reason,
      'write_approval_id',p_write_approval_id
    ),
    'runtime_session','runtime_session:'||p_session_id::text,
    coalesce(v_session.correlation_id,gen_random_uuid()),
    case when v_allowed then 'info' else 'warning' end,1,now(),now(),now()
  );

  return jsonb_build_object(
    'allowed',v_allowed,
    'reason',v_reason,
    'runtime_session_id',p_session_id,
    'customer_id',v_session.customer_id,
    'environment',v_session.environment,
    'action_mode',v_mode,
    'write_approval_id',case when v_allowed and v_mode='write' then v_approval.id else null end
  );
end;
$$;

-- Register the existing internal hospitality PROD deployment honestly as legacy shared.
-- This makes the current state explicit without pretending it already has dedicated customer isolation.
insert into public.sis_runtime_environments(
  runtime_key,customer_id,environment,status,ownership_model,
  make_isolation_mode,database_isolation_mode,metadata
)
select
  'sis_internal_hospitality_prod',c.id,'prod','active','legacy_shared',
  'shared','shared',jsonb_build_object(
    'migration_note','Existing internal pilot; migrate to dedicated Make organization and dedicated Supabase project before external customer rollout.',
    'customer_runtime_standard','dedicated_make_org_and_supabase_project_v1'
  )
from public.sis_customers c
where c.customer_key='sis_internal_hospitality'
on conflict (customer_id,environment) do nothing;

update public.sis_deployments d
set runtime_environment_id=r.id,
    updated_at=now()
from public.sis_runtime_environments r
where d.customer_id=r.customer_id
  and d.environment=r.environment
  and d.runtime_environment_id is null
  and r.runtime_key='sis_internal_hospitality_prod';

create or replace function public.sis_chat_start_menu_v1(p_work_item_limit integer default 5)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_context jsonb;
  v_menu jsonb;
  v_runtime_count integer;
  v_customer_count integer;
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

  select count(*)::int, count(distinct customer_id)::int
    into v_runtime_count, v_customer_count
  from public.sis_runtime_environments
  where status in ('active','provisioning');

  return jsonb_build_object(
    'schema_version', 3,
    'intent', 'sis_start',
    'mode', 'read_only_navigation',
    'execution_allowed', false,
    'approval_granted', false,
    'task_start_allowed', false,
    'runtime_access', jsonb_build_object(
      'state','locked',
      'customer_runtime_open',false,
      'step_up_required',true,
      'password_in_chat_forbidden',true,
      'write_requires_separate_approval',true
    ),
    'generated_at', now(),
    'prompt', 'Woran möchtest du arbeiten?',
    'menu', coalesce(v_menu, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object(
        'type','customer_runtime',
        'key','OPEN_CUSTOMER_RUNTIME',
        'label','Kundenumgebung öffnen 🔒',
        'description','Kunde und Umgebung auswählen; anschließend Step-up-Authentifizierung. Start immer READ/CHECK, WRITE separat freigeben.',
        'runtime_count',v_runtime_count,
        'customer_count',v_customer_count,
        'execution_allowed',false
      ),
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
      'platform_selection_does_not_start_work', true,
      'customer_runtime_selection_does_not_open_session', true,
      'customer_switch_requires_fresh_step_up', true,
      'runtime_write_requires_matching_short_lived_approval', true
    )
  );
end;
$$;

revoke all on function public.sis_open_runtime_session_v1(uuid,text,text,text,text,timestamptz,integer) from public, anon, authenticated;
revoke all on function public.sis_close_runtime_session_v1(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.sis_approve_runtime_write_v1(uuid,text,text,text,text,text,text,text,timestamptz,text,integer) from public, anon, authenticated;
revoke all on function public.sis_check_runtime_action_v1(uuid,text,text,uuid) from public, anon, authenticated;
revoke all on function public.sis_chat_start_menu_v1(integer) from public, anon, authenticated;

grant execute on function public.sis_open_runtime_session_v1(uuid,text,text,text,text,timestamptz,integer) to service_role;
grant execute on function public.sis_close_runtime_session_v1(uuid,text,boolean) to service_role;
grant execute on function public.sis_approve_runtime_write_v1(uuid,text,text,text,text,text,text,text,timestamptz,text,integer) to service_role;
grant execute on function public.sis_check_runtime_action_v1(uuid,text,text,uuid) to service_role;
grant execute on function public.sis_chat_start_menu_v1(integer) to service_role;

insert into public.sis_events(
  event_type,source,payload,scope,aggregate,correlation_id,severity,
  schema_version,occurred_at,recorded_at,created_at
) values (
  'architecture.customer_runtime_foundation_adopted','sis-platform-migration',
  jsonb_build_object(
    'runtime_standard','one_customer_per_runtime_tenant',
    'uat_prod_physical_isolation_target',true,
    'make_target','dedicated_organization_per_customer_environment',
    'database_target','dedicated_supabase_project_per_customer_environment',
    'chat_runtime_default','locked',
    'step_up_required',true,
    'write_approval_separate',true,
    'password_in_chat_forbidden',true
  ),
  'architecture','architecture:customer_runtime',gen_random_uuid(),'notice',1,now(),now(),now()
);

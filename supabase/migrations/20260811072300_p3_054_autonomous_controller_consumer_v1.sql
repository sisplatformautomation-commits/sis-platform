create table if not exists public.sis_controller_runtime_state (
  environment_key text primary key check (environment_key in ('dev','test')),
  consumer_key text not null default 'sis.controller.orchestration' check (consumer_key='sis.controller.orchestration'),
  status text not null default 'active' check (status in ('active','stopped','error')),
  lease_owner text,
  heartbeat_at timestamptz,
  lease_expires_at timestamptz,
  recovery_count integer not null default 0 check (recovery_count >= 0),
  last_tick_at timestamptz,
  last_error text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=32768),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sis_controller_dispatches (
  id uuid primary key default gen_random_uuid(),
  activation_id uuid not null unique references public.sis_supervisor_activations(id) on delete cascade,
  work_item_id uuid not null references public.sis_work_items(id) on delete cascade,
  work_item_key text not null,
  environment_key text not null check (environment_key in ('dev','test')),
  status text not null default 'awaiting_supervisor' check (status in ('awaiting_supervisor','supervisor_leased','observing','completed','cancelled','failed')),
  supervisor_lease_token uuid,
  supervisor_claimed_at timestamptz,
  supervisor_heartbeat_at timestamptz,
  supervisor_lease_expires_at timestamptz,
  plan_submitted_at timestamptz,
  planned_job_ids uuid[] not null default '{}'::uuid[],
  recovery_count integer not null default 0 check (recovery_count >= 0),
  last_observed_at timestamptz,
  stop_reason text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=32768),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists sis_controller_dispatches_queue_idx
  on public.sis_controller_dispatches(environment_key,status,created_at);
create index if not exists sis_controller_dispatches_lease_idx
  on public.sis_controller_dispatches(environment_key,supervisor_lease_expires_at)
  where status='supervisor_leased';

alter table public.sis_controller_runtime_state enable row level security;
alter table public.sis_controller_dispatches enable row level security;
revoke all on public.sis_controller_runtime_state from public, anon, authenticated;
revoke all on public.sis_controller_dispatches from public, anon, authenticated;
grant select,insert,update on public.sis_controller_runtime_state to service_role;
grant select,insert,update on public.sis_controller_dispatches to service_role;

create or replace function public.sis_controller_consumer_tick_v1(
  p_environment_key text,
  p_now timestamptz default now(),
  p_limit integer default 50,
  p_lease_seconds integer default 120
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_env text := lower(btrim(coalesce(p_environment_key,'')));
  v_owner text;
  v_state public.sis_controller_runtime_state%rowtype;
  v_activation public.sis_supervisor_activations%rowtype;
  v_dispatch public.sis_controller_dispatches%rowtype;
  v_gate record;
  v_claimed integer := 0;
  v_recovered integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_pending integer := 0;
begin
  if v_env not in ('dev','test') then raise exception 'P3_054_ENVIRONMENT_NOT_ALLOWED'; end if;
  if p_limit < 1 or p_limit > 100 then raise exception 'P3_054_LIMIT_INVALID'; end if;
  if p_lease_seconds < 30 or p_lease_seconds > 600 then raise exception 'P3_054_LEASE_INVALID'; end if;

  if not exists(select 1 from public.sis_agent_worker_capabilities where worker_key='sis.controller.orchestration' and environment_key=v_env and active and capability_key='orchestration.start')
     or not exists(select 1 from public.sis_agent_worker_capabilities where worker_key='sis.controller.orchestration' and environment_key=v_env and active and capability_key='orchestration.observe') then
    raise exception 'P3_054_CONTROLLER_CAPABILITY_MISSING';
  end if;
  if not exists(
    select 1 from public.sis_agent_workers w
    where w.worker_key='sis.supervisor' and w.status='active'
      and exists(select 1 from public.sis_agent_worker_capabilities c where c.worker_key=w.worker_key and c.environment_key=v_env and c.capability_key='orchestration.plan' and c.active)
      and exists(select 1 from public.sis_agent_worker_capabilities c where c.worker_key=w.worker_key and c.environment_key=v_env and c.capability_key='orchestration.delegate' and c.active)
  ) then raise exception 'P3_054_SUPERVISOR_NOT_AUTHORIZED'; end if;

  v_owner := 'pg_cron:p3-054:'||v_env;
  select * into v_state from public.sis_controller_runtime_state where environment_key=v_env for update;
  if not found then
    insert into public.sis_controller_runtime_state(environment_key,status,lease_owner,heartbeat_at,lease_expires_at,last_tick_at,metadata)
    values(v_env,'active',v_owner,p_now,p_now+make_interval(secs=>p_lease_seconds),p_now,jsonb_build_object('consumer_version','p3-054-v1','scheduler','pg_cron'))
    returning * into v_state;
  else
    if v_state.status='stopped' then
      return jsonb_build_object('ok',true,'environment_key',v_env,'status','stopped','claimed',0,'recovered',0,'completed',0,'failed',0);
    end if;
    if v_state.lease_expires_at is not null and v_state.lease_expires_at < p_now and v_state.heartbeat_at is not null then
      v_recovered := v_recovered + 1;
      v_state.recovery_count := v_state.recovery_count + 1;
    end if;
    update public.sis_controller_runtime_state
    set status='active',lease_owner=v_owner,heartbeat_at=p_now,lease_expires_at=p_now+make_interval(secs=>p_lease_seconds),
        recovery_count=v_state.recovery_count,last_tick_at=p_now,last_error=null,updated_at=p_now
    where environment_key=v_env;
  end if;

  with expired as (
    update public.sis_controller_dispatches
    set status='awaiting_supervisor',supervisor_lease_token=null,supervisor_lease_expires_at=null,
        supervisor_heartbeat_at=null,recovery_count=recovery_count+1,updated_at=p_now,
        metadata=metadata||jsonb_build_object('last_recovered_at',p_now,'recovery_reason','supervisor_lease_expired')
    where environment_key=v_env and status='supervisor_leased'
      and supervisor_lease_expires_at is not null and supervisor_lease_expires_at<=p_now
    returning id
  ) select count(*) into v_pending from expired;
  v_recovered := v_recovered + v_pending;

  for v_activation in
    select a.* from public.sis_supervisor_activations a
    where a.environment_key=v_env and a.status='requested'
    order by a.requested_at,a.id
    limit p_limit
    for update skip locked
  loop
    perform public.sis_execution_controller_supervisor_claim_v1(v_activation.id);
    insert into public.sis_controller_dispatches(activation_id,work_item_id,work_item_key,environment_key,status,metadata)
    values(v_activation.id,v_activation.work_item_id,v_activation.work_item_key,v_env,'awaiting_supervisor',
      jsonb_build_object('controller_worker_key','sis.controller.orchestration','supervisor_worker_key','sis.supervisor','consumer_version','p3-054-v1','activation_correlation_id',v_activation.correlation_id))
    on conflict (activation_id) do nothing;
    v_claimed := v_claimed + 1;
  end loop;

  for v_dispatch in
    select d.* from public.sis_controller_dispatches d
    where d.environment_key=v_env and d.status='observing'
    order by d.updated_at,d.id
    limit p_limit
    for update skip locked
  loop
    select
      count(*) as total_jobs,
      count(*) filter(where j.status='succeeded' and a.assignment_state='accepted') as accepted_jobs,
      count(*) filter(where j.status in ('failed','cancelled') or a.assignment_state='failed') as failed_jobs,
      count(*) filter(where j.status in ('queued','running','retry_wait','blocked') or a.assignment_state in ('queued','blocked','running','review_required','rework')) as pending_jobs
    into v_gate
    from public.sis_jobs j
    join public.sis_agent_job_assignments a on a.job_id=j.id
    where j.id=any(v_dispatch.planned_job_ids);

    if v_gate.total_jobs>0 and v_gate.failed_jobs>0 then
      update public.sis_controller_dispatches set status='failed',last_observed_at=p_now,updated_at=p_now,
        metadata=metadata||jsonb_build_object('failed_jobs',v_gate.failed_jobs,'observed_at',p_now) where id=v_dispatch.id;
      update public.sis_supervisor_activations set status='failed',completed_at=p_now,updated_at=p_now,
        metadata=metadata||jsonb_build_object('controller_completion','failed','controller_dispatch_id',v_dispatch.id)
      where id=v_dispatch.activation_id and status='claimed';
      v_failed := v_failed + 1;
    elsif v_gate.total_jobs>0 and v_gate.pending_jobs=0 and v_gate.accepted_jobs=v_gate.total_jobs then
      update public.sis_controller_dispatches set status='completed',last_observed_at=p_now,updated_at=p_now,
        metadata=metadata||jsonb_build_object('accepted_jobs',v_gate.accepted_jobs,'completed_at',p_now) where id=v_dispatch.id;
      update public.sis_supervisor_activations set status='completed',completed_at=p_now,updated_at=p_now,
        metadata=metadata||jsonb_build_object('controller_completion','completed','controller_dispatch_id',v_dispatch.id)
      where id=v_dispatch.activation_id and status='claimed';
      v_completed := v_completed + 1;
    else
      update public.sis_controller_dispatches set last_observed_at=p_now,updated_at=p_now where id=v_dispatch.id;
    end if;
  end loop;

  select count(*) into v_pending from public.sis_controller_dispatches
  where environment_key=v_env and status in ('awaiting_supervisor','supervisor_leased','observing');

  return jsonb_build_object('ok',true,'environment_key',v_env,'status','active','claimed',v_claimed,'recovered',v_recovered,
    'completed',v_completed,'failed',v_failed,'pending_dispatches',v_pending,'heartbeat_at',p_now,
    'lease_expires_at',p_now+make_interval(secs=>p_lease_seconds));
exception when others then
  update public.sis_controller_runtime_state
  set status='error',last_error=left(sqlerrm,300),last_tick_at=p_now,updated_at=p_now
  where environment_key=v_env;
  raise;
end;
$$;

create or replace function public.sis_supervisor_dispatch_claim_v1(p_lease_seconds integer default 300)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_env text;
  v_dispatch public.sis_controller_dispatches%rowtype;
  v_token uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_work_item public.sis_work_items%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_lease_seconds < 60 or p_lease_seconds > 1800 then raise exception 'P3_054_SUPERVISOR_LEASE_INVALID'; end if;
  select environment_key into v_env from public.sis_agent_runtime_bindings
  where worker_key='sis.supervisor' and status='active' and auth_subject=v_uid and environment_key in ('dev','test')
  order by environment_key limit 1;
  if v_env is null then raise exception 'WORKER_BINDING_REQUIRED'; end if;

  update public.sis_controller_dispatches
  set status='awaiting_supervisor',supervisor_lease_token=null,supervisor_lease_expires_at=null,supervisor_heartbeat_at=null,
      recovery_count=recovery_count+1,updated_at=v_now,
      metadata=metadata||jsonb_build_object('last_recovered_at',v_now,'recovery_reason','supervisor_lease_expired')
  where environment_key=v_env and status='supervisor_leased'
    and supervisor_lease_expires_at is not null and supervisor_lease_expires_at<=v_now;

  select * into v_dispatch from public.sis_controller_dispatches
  where environment_key=v_env and status='awaiting_supervisor'
  order by created_at,id limit 1 for update skip locked;
  if not found then return jsonb_build_object('ok',true,'environment_key',v_env,'dispatch',null); end if;

  update public.sis_controller_dispatches
  set status='supervisor_leased',supervisor_lease_token=v_token,supervisor_claimed_at=coalesce(supervisor_claimed_at,v_now),
      supervisor_heartbeat_at=v_now,supervisor_lease_expires_at=v_now+make_interval(secs=>p_lease_seconds),updated_at=v_now
  where id=v_dispatch.id returning * into v_dispatch;
  select * into v_work_item from public.sis_work_items where id=v_dispatch.work_item_id;

  return jsonb_build_object('ok',true,'environment_key',v_env,'dispatch',jsonb_build_object(
    'dispatch_id',v_dispatch.id,'activation_id',v_dispatch.activation_id,'work_item_key',v_dispatch.work_item_key,
    'lease_token',v_token,'lease_expires_at',v_dispatch.supervisor_lease_expires_at,
    'work_item',jsonb_build_object('title',v_work_item.title,'description',v_work_item.description,'status',v_work_item.status,
      'priority',v_work_item.priority,'current_stage',v_work_item.metadata->>'current_stage','next_action',v_work_item.metadata->>'next_action'),
    'activation_metadata',(select metadata from public.sis_supervisor_activations where id=v_dispatch.activation_id),
    'autonomy_allowlist',jsonb_build_array('database.read','runtime.read','finance.read','integration.provider_read')));
end;
$$;

create or replace function public.sis_supervisor_dispatch_heartbeat_v1(
  p_dispatch_id uuid,
  p_lease_token uuid,
  p_extend_seconds integer default 300
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid:=auth.uid();
  v_env text;
  v_now timestamptz:=clock_timestamp();
  v_exp timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_extend_seconds < 60 or p_extend_seconds > 1800 then raise exception 'P3_054_SUPERVISOR_LEASE_INVALID'; end if;
  select environment_key into v_env from public.sis_agent_runtime_bindings
  where worker_key='sis.supervisor' and status='active' and auth_subject=v_uid and environment_key in ('dev','test')
  order by environment_key limit 1;
  if v_env is null then raise exception 'WORKER_BINDING_REQUIRED'; end if;

  update public.sis_controller_dispatches
  set supervisor_heartbeat_at=v_now,supervisor_lease_expires_at=v_now+make_interval(secs=>p_extend_seconds),updated_at=v_now
  where id=p_dispatch_id and environment_key=v_env and status='supervisor_leased'
    and supervisor_lease_token=p_lease_token and supervisor_lease_expires_at>v_now
  returning supervisor_lease_expires_at into v_exp;
  if v_exp is null then raise exception 'P3_054_SUPERVISOR_LEASE_NOT_VALID'; end if;
  return jsonb_build_object('ok',true,'dispatch_id',p_dispatch_id,'lease_expires_at',v_exp);
end;
$$;

create or replace function public.sis_supervisor_dispatch_submit_plan_v1(
  p_dispatch_id uuid,
  p_lease_token uuid,
  p_plan jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_uid uuid:=auth.uid();
  v_env text;
  v_now timestamptz:=clock_timestamp();
  v_dispatch public.sis_controller_dispatches%rowtype;
  v_job jsonb;
  v_caps text[];
  v_resources text[];
  v_job_ids uuid[]:='{}'::uuid[];
  v_result jsonb;
  v_job_type text;
  v_dedupe text;
  v_review text;
  v_priority smallint;
  v_meta jsonb;
  v_idx integer:=0;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_plan is null or jsonb_typeof(p_plan)<>'object' or pg_column_size(p_plan)>65536 then raise exception 'P3_054_PLAN_INVALID'; end if;
  if jsonb_typeof(p_plan->'jobs')<>'array' or jsonb_array_length(p_plan->'jobs')<1 or jsonb_array_length(p_plan->'jobs')>12 then raise exception 'P3_054_PLAN_JOBS_INVALID'; end if;

  select environment_key into v_env from public.sis_agent_runtime_bindings
  where worker_key='sis.supervisor' and status='active' and auth_subject=v_uid and environment_key in ('dev','test')
  order by environment_key limit 1;
  if v_env is null then raise exception 'WORKER_BINDING_REQUIRED'; end if;

  select * into v_dispatch from public.sis_controller_dispatches where id=p_dispatch_id for update;
  if not found then raise exception 'P3_054_DISPATCH_NOT_FOUND'; end if;
  if v_dispatch.environment_key<>v_env or v_dispatch.status<>'supervisor_leased'
     or v_dispatch.supervisor_lease_token is distinct from p_lease_token
     or v_dispatch.supervisor_lease_expires_at<=v_now then
    raise exception 'P3_054_SUPERVISOR_LEASE_NOT_VALID';
  end if;

  for v_job in select value from jsonb_array_elements(p_plan->'jobs') loop
    v_idx:=v_idx+1;
    if jsonb_typeof(v_job)<>'object' then raise exception 'P3_054_JOB_SPEC_INVALID'; end if;
    v_job_type:=btrim(coalesce(v_job->>'job_type',''));
    if v_job_type='' or length(v_job_type)>160 then raise exception 'P3_054_JOB_TYPE_INVALID'; end if;
    if jsonb_typeof(v_job->'required_capabilities')<>'array' then raise exception 'P3_054_CAPABILITIES_INVALID'; end if;
    select coalesce(array_agg(value),'{}'::text[]) into v_caps from jsonb_array_elements_text(v_job->'required_capabilities');
    if cardinality(v_caps)<1 or cardinality(v_caps)>8 then raise exception 'P3_054_CAPABILITIES_INVALID'; end if;
    if exists(select 1 from unnest(v_caps) c where c not in ('database.read','runtime.read','finance.read','integration.provider_read')) then
      raise exception 'P3_054_CAPABILITY_NOT_IN_DEV_TEST_AUTONOMY_ALLOWLIST';
    end if;
    if exists(select 1 from public.sis_agent_capabilities c where c.capability_key=any(v_caps)
      and (c.provider_write or c.external_financial_write or c.destructive)) then
      raise exception 'P3_054_RISKY_CAPABILITY_BLOCKED';
    end if;

    if v_job ? 'required_resource_keys' then
      if jsonb_typeof(v_job->'required_resource_keys')<>'array' then raise exception 'P3_054_RESOURCES_INVALID'; end if;
      select coalesce(array_agg(value),'{}'::text[]) into v_resources from jsonb_array_elements_text(v_job->'required_resource_keys');
    else
      v_resources:='{}'::text[];
    end if;

    v_priority:=coalesce((v_job->>'priority')::smallint,100::smallint);
    v_review:=coalesce(nullif(btrim(v_job->>'review_profile'),''),'qa_security');
    v_dedupe:=coalesce(nullif(btrim(v_job->>'dedupe_key'),''),'p3-054:'||p_dispatch_id::text||':'||v_idx::text||':'||v_job_type);
    v_meta:=coalesce(v_job->'metadata','{}'::jsonb);
    if jsonb_typeof(v_meta)<>'object' or pg_column_size(v_meta)>16384 then raise exception 'P3_054_JOB_METADATA_INVALID'; end if;

    select public.sis_agent_supervisor_queue_job_v1(
      v_dispatch.work_item_key,v_job_type,v_env,v_caps,v_resources,v_dedupe,v_priority,v_review,
      v_meta||jsonb_build_object('controller_dispatch_id',p_dispatch_id,'activation_id',v_dispatch.activation_id,
        'planned_by','sis.supervisor','p3_054_autonomous',true)
    ) into v_result;
    v_job_ids:=array_append(v_job_ids,(v_result->>'job_id')::uuid);
  end loop;

  update public.sis_controller_dispatches
  set status='observing',plan_submitted_at=v_now,planned_job_ids=v_job_ids,supervisor_heartbeat_at=v_now,
      supervisor_lease_token=null,supervisor_lease_expires_at=null,updated_at=v_now,
      metadata=metadata||jsonb_build_object('plan_job_count',cardinality(v_job_ids),'plan_submitted_at',v_now,
        'plan_summary',coalesce(p_plan->'summary','null'::jsonb))
  where id=p_dispatch_id;

  return jsonb_build_object('ok',true,'dispatch_id',p_dispatch_id,'status','observing',
    'job_ids',to_jsonb(v_job_ids),'job_count',cardinality(v_job_ids));
end;
$$;

create or replace function public.sis_controller_consumer_stop_v1(
  p_activation_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_activation public.sis_supervisor_activations%rowtype;
  v_dispatch public.sis_controller_dispatches%rowtype;
  v_job_id uuid;
  v_cancelled integer:=0;
  v_now timestamptz:=clock_timestamp();
begin
  select * into v_activation from public.sis_supervisor_activations where id=p_activation_id for update;
  if not found then raise exception 'ACTIVATION_NOT_FOUND'; end if;
  if v_activation.environment_key not in ('dev','test') then raise exception 'P3_054_ENVIRONMENT_NOT_ALLOWED'; end if;
  if not exists(select 1 from public.sis_agent_worker_capabilities where worker_key='sis.controller.orchestration'
    and capability_key='orchestration.stop' and environment_key=v_activation.environment_key and active) then
    raise exception 'P3_054_CONTROLLER_STOP_NOT_AUTHORIZED';
  end if;
  if v_activation.status='cancelled' then
    return jsonb_build_object('ok',true,'idempotent',true,'activation_id',p_activation_id,'status','cancelled','cancelled_jobs',0);
  end if;
  if v_activation.status='requested' then return public.sis_execution_controller_cancel_v1(p_activation_id,p_reason); end if;
  if v_activation.status in ('completed','failed') then raise exception 'P3_054_TERMINAL_ACTIVATION_CANNOT_STOP'; end if;

  select * into v_dispatch from public.sis_controller_dispatches where activation_id=p_activation_id for update;
  if found then
    foreach v_job_id in array v_dispatch.planned_job_ids loop
      if exists(select 1 from public.sis_jobs where id=v_job_id and status not in ('succeeded','failed','cancelled')) then
        perform public.sis_cancel_job(v_job_id,'sis.controller.orchestration',left(coalesce(p_reason,'P3-054 controller stop'),300));
        v_cancelled:=v_cancelled+1;
      end if;
    end loop;
    update public.sis_controller_dispatches
    set status='cancelled',stop_reason=left(coalesce(p_reason,''),300),updated_at=v_now
    where id=v_dispatch.id;
  end if;

  update public.sis_supervisor_activations
  set status='cancelled',completed_at=v_now,updated_at=v_now,
      metadata=metadata||jsonb_build_object('cancel_reason',left(coalesce(p_reason,''),300),'cancelled_by','sis.controller.orchestration')
  where id=p_activation_id;
  return jsonb_build_object('ok',true,'idempotent',false,'activation_id',p_activation_id,'status','cancelled','cancelled_jobs',v_cancelled);
end;
$$;

create or replace function public.sis_controller_consumer_status_v1(p_environment_key text)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'environment_key',lower(btrim(p_environment_key)),
    'runtime',(select to_jsonb(s) from public.sis_controller_runtime_state s where s.environment_key=lower(btrim(p_environment_key))),
    'dispatch_counts',(select jsonb_object_agg(status,cnt) from (
      select status,count(*) cnt from public.sis_controller_dispatches
      where environment_key=lower(btrim(p_environment_key)) group by status
    ) x),
    'recent_dispatches',coalesce((select jsonb_agg(jsonb_build_object(
      'id',d.id,'activation_id',d.activation_id,'work_item_key',d.work_item_key,'status',d.status,
      'planned_job_ids',to_jsonb(d.planned_job_ids),'recovery_count',d.recovery_count,'updated_at',d.updated_at
    ) order by d.updated_at desc) from (
      select * from public.sis_controller_dispatches where environment_key=lower(btrim(p_environment_key))
      order by updated_at desc limit 10
    ) d),'[]'::jsonb)
  );
$$;

create or replace function public.sis_controller_runtime_set_enabled_v1(
  p_environment_key text,
  p_enabled boolean
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_env text:=lower(btrim(coalesce(p_environment_key,'')));
  v_status text;
begin
  if v_env not in ('dev','test') then raise exception 'P3_054_ENVIRONMENT_NOT_ALLOWED'; end if;
  v_status:=case when p_enabled then 'active' else 'stopped' end;
  insert into public.sis_controller_runtime_state(environment_key,status,metadata)
  values(v_env,v_status,jsonb_build_object('consumer_version','p3-054-v1'))
  on conflict(environment_key) do update
  set status=excluded.status,updated_at=now(),
      metadata=public.sis_controller_runtime_state.metadata||jsonb_build_object('enabled_changed_at',now());
  return jsonb_build_object('ok',true,'environment_key',v_env,'status',v_status);
end;
$$;

revoke all on function public.sis_controller_consumer_tick_v1(text,timestamptz,integer,integer) from public,anon,authenticated;
revoke all on function public.sis_controller_consumer_stop_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.sis_controller_consumer_status_v1(text) from public,anon,authenticated;
revoke all on function public.sis_controller_runtime_set_enabled_v1(text,boolean) from public,anon,authenticated;
grant execute on function public.sis_controller_consumer_tick_v1(text,timestamptz,integer,integer) to service_role;
grant execute on function public.sis_controller_consumer_stop_v1(uuid,text) to service_role;
grant execute on function public.sis_controller_consumer_status_v1(text) to service_role;
grant execute on function public.sis_controller_runtime_set_enabled_v1(text,boolean) to service_role;

revoke all on function public.sis_supervisor_dispatch_claim_v1(integer) from public,anon;
revoke all on function public.sis_supervisor_dispatch_heartbeat_v1(uuid,uuid,integer) from public,anon;
revoke all on function public.sis_supervisor_dispatch_submit_plan_v1(uuid,uuid,jsonb) from public,anon;
grant execute on function public.sis_supervisor_dispatch_claim_v1(integer) to authenticated;
grant execute on function public.sis_supervisor_dispatch_heartbeat_v1(uuid,uuid,integer) to authenticated;
grant execute on function public.sis_supervisor_dispatch_submit_plan_v1(uuid,uuid,jsonb) to authenticated;

alter table public.sis_agent_hitl_runs
  add column if not exists action_fingerprint text,
  add column if not exists approval_expires_at timestamptz,
  add column if not exists approval_last_checked_at timestamptz,
  add column if not exists approval_recovery_state text not null default 'none',
  add column if not exists approval_recovery_count integer not null default 0;

alter table public.sis_agent_hitl_runs
  drop constraint if exists sis_agent_hitl_runs_approval_recovery_state_check,
  add constraint sis_agent_hitl_runs_approval_recovery_state_check
    check (approval_recovery_state in ('none','active','expired_recoverable','recovered')),
  drop constraint if exists sis_agent_hitl_runs_approval_recovery_count_check,
  add constraint sis_agent_hitl_runs_approval_recovery_count_check
    check (approval_recovery_count >= 0),
  drop constraint if exists sis_agent_hitl_runs_action_fingerprint_check,
  add constraint sis_agent_hitl_runs_action_fingerprint_check
    check (action_fingerprint is null or action_fingerprint ~ '^[0-9a-f]{64}$');

create index if not exists sis_agent_hitl_pending_lease_idx
  on public.sis_agent_hitl_runs (approval_expires_at, id)
  where status='pending_approval' and approval_recovery_state='active';

create table if not exists public.sis_agent_hitl_effect_ledger (
  action_fingerprint text primary key,
  hitl_id uuid not null references public.sis_agent_hitl_runs(id) on delete cascade,
  environment_key text not null check (environment_key in ('dev','test')),
  resource_key text not null,
  action_key text not null,
  tool_name text not null,
  effect_kind text not null default 'evidence_only' check (effect_kind='evidence_only'),
  status text not null default 'committed' check (status='committed'),
  result_code text not null,
  result jsonb not null default '{}'::jsonb check (jsonb_typeof(result)='object'),
  replay_count integer not null default 0 check (replay_count >= 0),
  committed_at timestamptz not null default now(),
  last_replayed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  provider_write_performed boolean not null default false check (provider_write_performed=false),
  mail_write_performed boolean not null default false check (mail_write_performed=false),
  constraint sis_agent_hitl_effect_ledger_fingerprint_check check (action_fingerprint ~ '^[0-9a-f]{64}$')
);

create index if not exists sis_agent_hitl_effect_ledger_hitl_idx
  on public.sis_agent_hitl_effect_ledger(hitl_id);

alter table public.sis_agent_hitl_effect_ledger enable row level security;
revoke all on public.sis_agent_hitl_effect_ledger from public, anon, authenticated;
grant select, insert, update on public.sis_agent_hitl_effect_ledger to service_role;

create or replace function public.sis_agent_hitl_effect_commit_v1(
  p_hitl_id uuid,
  p_action_fingerprint text,
  p_result_code text default 'EVIDENCE_ONLY_EXECUTED_NO_PROVIDER_WRITE'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_run public.sis_agent_hitl_runs%rowtype;
  v_effect public.sis_agent_hitl_effect_ledger%rowtype;
  v_inserted text;
  v_now timestamptz := clock_timestamp();
begin
  if p_action_fingerprint is null or p_action_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'HITL_ACTION_FINGERPRINT_INVALID';
  end if;
  if p_result_code is null or length(p_result_code) < 1 or length(p_result_code) > 160 then
    raise exception 'HITL_RESULT_CODE_INVALID';
  end if;

  select * into v_run
  from public.sis_agent_hitl_runs
  where id=p_hitl_id
  for update;

  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;
  if v_run.status <> 'pending_approval' then raise exception 'HITL_RUN_NOT_PENDING'; end if;
  if v_run.authorization_decision <> 'APPROVAL_REQUIRED' then raise exception 'HITL_AUTHORIZATION_STATE_INVALID'; end if;
  if v_run.approval_recovery_state = 'expired_recoverable'
     or (v_run.approval_expires_at is not null and v_run.approval_expires_at <= v_now) then
    raise exception 'HITL_APPROVAL_LEASE_EXPIRED';
  end if;

  insert into public.sis_agent_hitl_effect_ledger(
    action_fingerprint,hitl_id,environment_key,resource_key,action_key,tool_name,result_code,result,
    provider_write_performed,mail_write_performed,committed_at,created_at,updated_at
  ) values (
    p_action_fingerprint,v_run.id,v_run.environment_key,v_run.resource_key,v_run.action_key,
    coalesce(v_run.tool_name,'unknown'),p_result_code,
    jsonb_build_object('result_code',p_result_code,'evidence_only',true),
    false,false,v_now,v_now,v_now
  ) on conflict (action_fingerprint) do nothing
  returning action_fingerprint into v_inserted;

  if v_inserted is not null then
    update public.sis_agent_hitl_runs
      set tool_execution_count=greatest(tool_execution_count,1),
          action_fingerprint=p_action_fingerprint,
          updated_at=v_now
      where id=p_hitl_id;
    return jsonb_build_object('ok',true,'committed',true,'replay',false,'action_fingerprint',p_action_fingerprint,'result_code',p_result_code);
  end if;

  select * into v_effect
  from public.sis_agent_hitl_effect_ledger
  where action_fingerprint=p_action_fingerprint
  for update;

  if v_effect.hitl_id <> v_run.id
     or v_effect.environment_key <> v_run.environment_key
     or v_effect.resource_key <> v_run.resource_key
     or v_effect.action_key <> v_run.action_key
     or v_effect.tool_name <> coalesce(v_run.tool_name,'unknown') then
    raise exception 'HITL_ACTION_FINGERPRINT_COLLISION';
  end if;

  update public.sis_agent_hitl_effect_ledger
    set replay_count=replay_count+1,last_replayed_at=v_now,updated_at=v_now
    where action_fingerprint=p_action_fingerprint;

  update public.sis_agent_hitl_runs
    set tool_execution_count=greatest(tool_execution_count,1),
        action_fingerprint=coalesce(action_fingerprint,p_action_fingerprint),
        updated_at=v_now
    where id=p_hitl_id;

  return jsonb_build_object('ok',true,'committed',true,'replay',true,'action_fingerprint',p_action_fingerprint,'result_code',v_effect.result_code);
end;
$$;

revoke all on function public.sis_agent_hitl_effect_commit_v1(uuid,text,text) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_effect_commit_v1(uuid,text,text) to service_role;

create or replace function public.sis_agent_hitl_sweep_expired_v1(
  p_now timestamptz default now(),
  p_limit integer default 100
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ids uuid[];
begin
  if p_limit < 1 or p_limit > 500 then raise exception 'HITL_SWEEP_LIMIT_INVALID'; end if;

  with candidates as (
    select id
    from public.sis_agent_hitl_runs
    where status='pending_approval'
      and approval_recovery_state='active'
      and approval_expires_at is not null
      and approval_expires_at <= p_now
    order by approval_expires_at,id
    limit p_limit
    for update skip locked
  ), changed as (
    update public.sis_agent_hitl_runs r
      set approval_recovery_state='expired_recoverable',
          approval_last_checked_at=p_now,
          metadata=coalesce(r.metadata,'{}'::jsonb) || jsonb_build_object('recovery_reason','approval_lease_expired','recovery_marked_at',p_now),
          updated_at=p_now
    from candidates c
    where r.id=c.id
    returning r.id
  ) select array_agg(id) into v_ids from changed;

  return jsonb_build_object('ok',true,'expired_count',coalesce(cardinality(v_ids),0),'hitl_ids',coalesce(to_jsonb(v_ids),'[]'::jsonb));
end;
$$;

revoke all on function public.sis_agent_hitl_sweep_expired_v1(timestamptz,integer) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_sweep_expired_v1(timestamptz,integer) to service_role;

create or replace function public.sis_agent_hitl_recover_expired_v1(
  p_hitl_id uuid,
  p_extend_seconds integer default 3600
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_row public.sis_agent_hitl_runs%rowtype;
begin
  if p_extend_seconds < 60 or p_extend_seconds > 86400 then raise exception 'HITL_RECOVERY_EXTENSION_INVALID'; end if;
  select * into v_row from public.sis_agent_hitl_runs where id=p_hitl_id for update;
  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;
  if v_row.status <> 'pending_approval' or v_row.approval_recovery_state <> 'expired_recoverable' then
    raise exception 'HITL_RUN_NOT_EXPIRED_RECOVERABLE';
  end if;
  if v_row.sdk_state is null or v_row.state_sha256 is null then raise exception 'HITL_DURABLE_STATE_MISSING'; end if;

  update public.sis_agent_hitl_runs
    set approval_recovery_state='recovered',
        approval_recovery_count=approval_recovery_count+1,
        approval_last_checked_at=v_now,
        approval_expires_at=v_now + make_interval(secs => p_extend_seconds),
        metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object('recovered_at',v_now,'recovery_extension_seconds',p_extend_seconds),
        updated_at=v_now
    where id=p_hitl_id;

  update public.sis_agent_hitl_runs
    set approval_recovery_state='active',updated_at=v_now
    where id=p_hitl_id;

  return jsonb_build_object('ok',true,'hitl_id',p_hitl_id,'status','pending_approval','approval_recovery_state','active','approval_expires_at',v_now + make_interval(secs => p_extend_seconds));
end;
$$;

revoke all on function public.sis_agent_hitl_recover_expired_v1(uuid,integer) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_recover_expired_v1(uuid,integer) to service_role;

create or replace function public.sis_agent_hitl_read_v1(p_hitl_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select case when r.id is null then null else jsonb_build_object(
    'id',r.id,'work_item_key',r.work_item_key,'observed_work_item_key',r.observed_work_item_key,
    'environment_key',r.environment_key,'actor_key',r.actor_key,'resolver_worker_key',r.resolver_worker_key,
    'capability_key',r.capability_key,'resource_key',r.resource_key,'action_key',r.action_key,
    'authorization_policy_version',r.authorization_policy_version,'authorization_decision',r.authorization_decision,
    'authorization_evaluation_id',r.authorization_evaluation_id,'status',r.status,'resolution',r.resolution,
    'sdk_name',r.sdk_name,'sdk_version',r.sdk_version,'trace_id',r.trace_id,'tool_name',r.tool_name,
    'tool_call_id',r.tool_call_id,'action_fingerprint',r.action_fingerprint,
    'state_sha256',r.state_sha256,'resumed_state_sha256',r.resumed_state_sha256,
    'interruption_count',r.interruption_count,'tool_execution_count',r.tool_execution_count,
    'approval_expires_at',r.approval_expires_at,'approval_last_checked_at',r.approval_last_checked_at,
    'approval_recovery_state',r.approval_recovery_state,'approval_recovery_count',r.approval_recovery_count,
    'provider_write_performed',r.provider_write_performed,'mail_write_performed',r.mail_write_performed,
    'execution_gate_changed',r.execution_gate_changed,'approval_gate_changed',r.approval_gate_changed,
    'final_output',r.final_output,'error_summary',r.error_summary,'metadata',r.metadata,
    'created_at',r.created_at,'updated_at',r.updated_at,'resolved_at',r.resolved_at,
    'serialized_state_persisted',r.sdk_state is not null
  ) end
  from public.sis_agent_hitl_runs r where r.id=p_hitl_id;
$$;

revoke all on function public.sis_agent_hitl_read_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_read_v1(uuid) to service_role;

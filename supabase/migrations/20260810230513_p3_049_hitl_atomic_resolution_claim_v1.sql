create extension if not exists pgcrypto with schema extensions;

alter table public.sis_agent_hitl_runs
  add column if not exists resolution_claim_id uuid,
  add column if not exists resolution_claim_decision text,
  add column if not exists resolution_claimed_at timestamptz,
  add column if not exists resolution_claimed_by text,
  add column if not exists resolution_claim_completed_at timestamptz;

alter table public.sis_agent_hitl_runs
  drop constraint if exists sis_agent_hitl_runs_resolution_claim_decision_check;
alter table public.sis_agent_hitl_runs
  add constraint sis_agent_hitl_runs_resolution_claim_decision_check
  check (resolution_claim_decision is null or resolution_claim_decision in ('approve','reject'));

alter table public.sis_agent_hitl_runs
  drop constraint if exists sis_agent_hitl_runs_resolution_claim_consistency_check;
alter table public.sis_agent_hitl_runs
  add constraint sis_agent_hitl_runs_resolution_claim_consistency_check
  check (
    resolution_claim_id is null
    or (
      resolution_claim_decision is not null
      and resolution_claimed_at is not null
      and resolution_claimed_by is not null
      and length(resolution_claimed_by) between 1 and 160
    )
  );

create unique index if not exists sis_agent_hitl_runs_resolution_claim_id_uidx
  on public.sis_agent_hitl_runs(resolution_claim_id)
  where resolution_claim_id is not null;

create or replace function public.sis_agent_hitl_resolution_claim_v1(
  p_hitl_id uuid,
  p_decision text,
  p_resolver_worker_key text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_run public.sis_agent_hitl_runs%rowtype;
  v_now timestamptz := clock_timestamp();
  v_claim_id uuid;
  v_fingerprint text;
begin
  if p_decision not in ('approve','reject') then raise exception 'HITL_RESOLUTION_DECISION_INVALID'; end if;
  if p_resolver_worker_key is null or length(p_resolver_worker_key) < 1 or length(p_resolver_worker_key) > 160 then
    raise exception 'HITL_RESOLVER_WORKER_INVALID';
  end if;

  select * into v_run
  from public.sis_agent_hitl_runs
  where id=p_hitl_id
  for update;

  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;

  if v_run.status in ('approved_resumed','rejected_resumed') then
    if v_run.resolution = p_decision and v_run.resolution_claim_decision = p_decision then
      return jsonb_build_object(
        'ok',true,'claimed',true,'idempotent',true,'completed',true,
        'hitl_id',v_run.id,'decision',p_decision,'status',v_run.status,
        'claim_id',v_run.resolution_claim_id,'action_fingerprint',v_run.action_fingerprint
      );
    end if;
    raise exception 'RESOLUTION_ALREADY_CLAIMED';
  end if;

  if v_run.status <> 'pending_approval' then raise exception 'HITL_RUN_NOT_PENDING'; end if;
  if v_run.authorization_decision <> 'APPROVAL_REQUIRED' then raise exception 'HITL_AUTHORIZATION_STATE_INVALID'; end if;
  if v_run.sdk_state is null or v_run.state_sha256 is null then raise exception 'HITL_DURABLE_STATE_MISSING'; end if;

  if v_run.resolution_claim_id is not null then
    if v_run.resolution_claim_decision = p_decision then
      return jsonb_build_object(
        'ok',true,'claimed',true,'idempotent',true,'completed',false,
        'hitl_id',v_run.id,'decision',p_decision,'status',v_run.status,
        'claim_id',v_run.resolution_claim_id,'claimed_at',v_run.resolution_claimed_at,
        'claimed_by',v_run.resolution_claimed_by,'action_fingerprint',v_run.action_fingerprint
      );
    end if;
    raise exception 'RESOLUTION_ALREADY_CLAIMED';
  end if;

  v_claim_id := gen_random_uuid();
  if p_decision='approve' then
    if v_run.tool_call_id is null or length(v_run.tool_call_id) < 1 then raise exception 'HITL_TOOL_CALL_ID_REQUIRED_FOR_APPROVE'; end if;
    v_fingerprint := encode(extensions.digest(convert_to(concat_ws('|',
      'sis-hitl-effect-v1',
      v_run.id::text,
      v_run.environment_key,
      v_run.resource_key,
      v_run.action_key,
      coalesce(v_run.tool_name,''),
      v_run.tool_call_id
    ),'UTF8'),'sha256'),'hex');
  end if;

  update public.sis_agent_hitl_runs
    set resolution_claim_id=v_claim_id,
        resolution_claim_decision=p_decision,
        resolution_claimed_at=v_now,
        resolution_claimed_by=p_resolver_worker_key,
        action_fingerprint=case when p_decision='approve' then v_fingerprint else action_fingerprint end,
        metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'resolution_claimed_at',v_now,
          'resolution_claim_decision',p_decision
        ),
        updated_at=v_now
  where id=p_hitl_id;

  return jsonb_build_object(
    'ok',true,'claimed',true,'idempotent',false,'completed',false,
    'hitl_id',p_hitl_id,'decision',p_decision,'status','pending_approval',
    'claim_id',v_claim_id,'claimed_at',v_now,'claimed_by',p_resolver_worker_key,
    'action_fingerprint',v_fingerprint
  );
end;
$$;

create or replace function public.sis_agent_hitl_resolution_finalize_v1(
  p_hitl_id uuid,
  p_claim_id uuid,
  p_resumed_state_sha256 text,
  p_final_output text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_run public.sis_agent_hitl_runs%rowtype;
  v_now timestamptz := clock_timestamp();
  v_status text;
begin
  if p_claim_id is null then raise exception 'HITL_RESOLUTION_CLAIM_REQUIRED'; end if;
  if p_resumed_state_sha256 is null or p_resumed_state_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'HITL_RESUMED_STATE_HASH_INVALID';
  end if;

  select * into v_run
  from public.sis_agent_hitl_runs
  where id=p_hitl_id
  for update;

  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;

  if v_run.status in ('approved_resumed','rejected_resumed') then
    if v_run.resolution_claim_id=p_claim_id then
      return jsonb_build_object(
        'ok',true,'idempotent',true,'completed',true,'hitl_id',v_run.id,
        'decision',v_run.resolution,'status',v_run.status,'claim_id',p_claim_id,
        'tool_execution_count',v_run.tool_execution_count
      );
    end if;
    raise exception 'RESOLUTION_ALREADY_FINALIZED';
  end if;

  if v_run.status <> 'pending_approval' then raise exception 'HITL_RUN_NOT_PENDING'; end if;
  if v_run.resolution_claim_id is distinct from p_claim_id then raise exception 'HITL_RESOLUTION_CLAIM_MISMATCH'; end if;
  if v_run.resolution_claim_decision not in ('approve','reject') then raise exception 'HITL_RESOLUTION_CLAIM_STATE_INVALID'; end if;

  if v_run.resolution_claim_decision='approve' and v_run.tool_execution_count <> 1 then
    raise exception 'APPROVED_TOOL_DID_NOT_EXECUTE_EXACTLY_ONCE';
  end if;
  if v_run.resolution_claim_decision='reject' and v_run.tool_execution_count <> 0 then
    raise exception 'REJECTED_TOOL_EXECUTED';
  end if;

  v_status := case when v_run.resolution_claim_decision='approve' then 'approved_resumed' else 'rejected_resumed' end;

  update public.sis_agent_hitl_runs
    set status=v_status,
        resolution=v_run.resolution_claim_decision,
        resolver_worker_key=v_run.resolution_claimed_by,
        resumed_state_sha256=p_resumed_state_sha256,
        sdk_state=null,
        final_output=left(coalesce(p_final_output,''),300),
        resolved_at=v_now,
        resolution_claim_completed_at=v_now,
        updated_at=v_now
  where id=p_hitl_id;

  return jsonb_build_object(
    'ok',true,'idempotent',false,'completed',true,'hitl_id',p_hitl_id,
    'decision',v_run.resolution_claim_decision,'status',v_status,'claim_id',p_claim_id,
    'tool_execution_count',v_run.tool_execution_count
  );
end;
$$;

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
    'resolution_claim_id',r.resolution_claim_id,'resolution_claim_decision',r.resolution_claim_decision,
    'resolution_claimed_at',r.resolution_claimed_at,'resolution_claimed_by',r.resolution_claimed_by,
    'resolution_claim_completed_at',r.resolution_claim_completed_at,
    'sdk_name',r.sdk_name,'sdk_version',r.sdk_version,'trace_id',r.trace_id,'tool_name',r.tool_name,
    'tool_call_id',r.tool_call_id,'action_fingerprint',r.action_fingerprint,
    'state_sha256',r.state_sha256,'resumed_state_sha256',r.resumed_state_sha256,
    'interruption_count',r.interruption_count,'tool_execution_count',r.tool_execution_count,
    'provider_write_performed',r.provider_write_performed,'mail_write_performed',r.mail_write_performed,
    'execution_gate_changed',r.execution_gate_changed,'approval_gate_changed',r.approval_gate_changed,
    'final_output',r.final_output,'error_summary',r.error_summary,'metadata',r.metadata,
    'created_at',r.created_at,'updated_at',r.updated_at,'resolved_at',r.resolved_at,
    'serialized_state_persisted',r.sdk_state is not null
  ) end
  from public.sis_agent_hitl_runs r where r.id=p_hitl_id;
$$;

revoke all on function public.sis_agent_hitl_resolution_claim_v1(uuid,text,text) from public, anon, authenticated;
revoke all on function public.sis_agent_hitl_resolution_finalize_v1(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_resolution_claim_v1(uuid,text,text) to service_role;
grant execute on function public.sis_agent_hitl_resolution_finalize_v1(uuid,uuid,text,text) to service_role;

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

  select * into v_run from public.sis_agent_hitl_runs where id=p_hitl_id for update;
  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;

  if v_run.status in ('approved_resumed','rejected_resumed') then
    if v_run.resolution = p_decision and v_run.resolution_claim_decision = p_decision then
      return jsonb_build_object('ok',true,'claimed',true,'idempotent',true,'completed',true,'hitl_id',v_run.id,'decision',p_decision,'status',v_run.status,'claim_id',v_run.resolution_claim_id,'action_fingerprint',v_run.action_fingerprint);
    end if;
    raise exception 'RESOLUTION_ALREADY_CLAIMED';
  end if;

  if v_run.status <> 'pending_approval' then raise exception 'HITL_RUN_NOT_PENDING'; end if;
  if v_run.authorization_decision <> 'APPROVAL_REQUIRED' then raise exception 'HITL_AUTHORIZATION_STATE_INVALID'; end if;
  if v_run.sdk_state is null or v_run.state_sha256 is null then raise exception 'HITL_DURABLE_STATE_MISSING'; end if;

  if v_run.resolution_claim_id is not null then
    if v_run.resolution_claim_decision = p_decision then
      return jsonb_build_object('ok',true,'claimed',true,'idempotent',true,'completed',false,'hitl_id',v_run.id,'decision',p_decision,'status',v_run.status,'claim_id',v_run.resolution_claim_id,'claimed_at',v_run.resolution_claimed_at,'claimed_by',v_run.resolution_claimed_by,'action_fingerprint',v_run.action_fingerprint);
    end if;
    raise exception 'RESOLUTION_ALREADY_CLAIMED';
  end if;

  if v_run.approval_recovery_state <> 'active' then raise exception 'HITL_APPROVAL_NOT_ACTIVE'; end if;
  if v_run.approval_expires_at is not null and v_run.approval_expires_at <= v_now then raise exception 'HITL_APPROVAL_LEASE_EXPIRED'; end if;

  v_claim_id := gen_random_uuid();
  if p_decision='approve' then
    if v_run.tool_call_id is null or length(v_run.tool_call_id) < 1 then raise exception 'HITL_TOOL_CALL_ID_REQUIRED_FOR_APPROVE'; end if;
    v_fingerprint := encode(extensions.digest(convert_to(concat_ws('|','sis-hitl-effect-v1',v_run.id::text,v_run.environment_key,v_run.resource_key,v_run.action_key,coalesce(v_run.tool_name,''),v_run.tool_call_id),'UTF8'),'sha256'),'hex');
  end if;

  update public.sis_agent_hitl_runs
    set resolution_claim_id=v_claim_id,
        resolution_claim_decision=p_decision,
        resolution_claimed_at=v_now,
        resolution_claimed_by=p_resolver_worker_key,
        action_fingerprint=case when p_decision='approve' then v_fingerprint else action_fingerprint end,
        approval_expires_at=null,
        approval_last_checked_at=v_now,
        approval_recovery_state='none',
        metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object('resolution_claimed_at',v_now,'resolution_claim_decision',p_decision),
        updated_at=v_now
  where id=p_hitl_id;

  return jsonb_build_object('ok',true,'claimed',true,'idempotent',false,'completed',false,'hitl_id',p_hitl_id,'decision',p_decision,'status','pending_approval','claim_id',v_claim_id,'claimed_at',v_now,'claimed_by',p_resolver_worker_key,'action_fingerprint',v_fingerprint);
end;
$$;

create or replace function public.sis_agent_hitl_effect_commit_claimed_v2(
  p_hitl_id uuid,
  p_claim_id uuid,
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
  v_fingerprint text;
begin
  if p_claim_id is null then raise exception 'HITL_RESOLUTION_CLAIM_REQUIRED'; end if;
  if p_result_code is null or length(p_result_code) < 1 or length(p_result_code) > 160 then raise exception 'HITL_RESULT_CODE_INVALID'; end if;

  select * into v_run from public.sis_agent_hitl_runs where id=p_hitl_id for update;
  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;
  if v_run.status <> 'pending_approval' then raise exception 'HITL_RUN_NOT_PENDING'; end if;
  if v_run.authorization_decision <> 'APPROVAL_REQUIRED' then raise exception 'HITL_AUTHORIZATION_STATE_INVALID'; end if;
  if v_run.resolution_claim_id is distinct from p_claim_id then raise exception 'HITL_RESOLUTION_CLAIM_MISMATCH'; end if;
  if v_run.resolution_claim_decision <> 'approve' then raise exception 'HITL_EFFECT_REQUIRES_APPROVE_CLAIM'; end if;

  v_fingerprint := v_run.action_fingerprint;
  if v_fingerprint is null or v_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'HITL_CANONICAL_ACTION_FINGERPRINT_MISSING'; end if;

  insert into public.sis_agent_hitl_effect_ledger(action_fingerprint,hitl_id,environment_key,resource_key,action_key,tool_name,result_code,result,provider_write_performed,mail_write_performed,committed_at,created_at,updated_at)
  values(v_fingerprint,v_run.id,v_run.environment_key,v_run.resource_key,v_run.action_key,coalesce(v_run.tool_name,'unknown'),p_result_code,jsonb_build_object('result_code',p_result_code,'evidence_only',true,'resolution_claim_id',p_claim_id),false,false,v_now,v_now,v_now)
  on conflict (action_fingerprint) do nothing
  returning action_fingerprint into v_inserted;

  if v_inserted is not null then
    update public.sis_agent_hitl_runs set tool_execution_count=greatest(tool_execution_count,1),updated_at=v_now where id=p_hitl_id and resolution_claim_id=p_claim_id;
    return jsonb_build_object('ok',true,'committed',true,'replay',false,'action_fingerprint',v_fingerprint,'result_code',p_result_code);
  end if;

  select * into v_effect from public.sis_agent_hitl_effect_ledger where action_fingerprint=v_fingerprint for update;
  if v_effect.hitl_id <> v_run.id or v_effect.environment_key <> v_run.environment_key or v_effect.resource_key <> v_run.resource_key or v_effect.action_key <> v_run.action_key or v_effect.tool_name <> coalesce(v_run.tool_name,'unknown') then raise exception 'HITL_ACTION_FINGERPRINT_COLLISION'; end if;

  update public.sis_agent_hitl_effect_ledger set replay_count=replay_count+1,last_replayed_at=v_now,updated_at=v_now where action_fingerprint=v_fingerprint;
  update public.sis_agent_hitl_runs set tool_execution_count=greatest(tool_execution_count,1),updated_at=v_now where id=p_hitl_id and resolution_claim_id=p_claim_id;

  return jsonb_build_object('ok',true,'committed',true,'replay',true,'action_fingerprint',v_fingerprint,'result_code',v_effect.result_code);
end;
$$;

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
begin
  select * into v_run from public.sis_agent_hitl_runs where id=p_hitl_id;
  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;
  if v_run.action_fingerprint is null or p_action_fingerprint is distinct from v_run.action_fingerprint then raise exception 'HITL_ACTION_FINGERPRINT_NOT_CANONICAL'; end if;
  if v_run.resolution_claim_id is null or v_run.resolution_claim_decision <> 'approve' then raise exception 'HITL_EFFECT_REQUIRES_APPROVE_CLAIM'; end if;
  return public.sis_agent_hitl_effect_commit_claimed_v2(p_hitl_id,v_run.resolution_claim_id,p_result_code);
end;
$$;

create or replace function public.sis_agent_hitl_sweep_expired_v1(p_now timestamptz default now(),p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_ids uuid[];
begin
  if p_limit < 1 or p_limit > 500 then raise exception 'HITL_SWEEP_LIMIT_INVALID'; end if;
  with candidates as (
    select id from public.sis_agent_hitl_runs
    where status='pending_approval' and resolution_claim_id is null and approval_recovery_state='active' and approval_expires_at is not null and approval_expires_at <= p_now
    order by approval_expires_at,id limit p_limit for update skip locked
  ), changed as (
    update public.sis_agent_hitl_runs r
    set approval_recovery_state='expired_recoverable',approval_last_checked_at=p_now,metadata=coalesce(r.metadata,'{}'::jsonb)||jsonb_build_object('recovery_reason','approval_lease_expired','recovery_marked_at',p_now),updated_at=p_now
    from candidates c where r.id=c.id returning r.id
  ) select array_agg(id) into v_ids from changed;
  return jsonb_build_object('ok',true,'expired_count',coalesce(cardinality(v_ids),0),'hitl_ids',coalesce(to_jsonb(v_ids),'[]'::jsonb));
end;
$$;

create or replace function public.sis_agent_hitl_recover_expired_v1(p_hitl_id uuid,p_extend_seconds integer default 3600)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_now timestamptz:=clock_timestamp(); v_row public.sis_agent_hitl_runs%rowtype;
begin
  if p_extend_seconds < 60 or p_extend_seconds > 86400 then raise exception 'HITL_RECOVERY_EXTENSION_INVALID'; end if;
  select * into v_row from public.sis_agent_hitl_runs where id=p_hitl_id for update;
  if not found then raise exception 'HITL_RUN_NOT_FOUND'; end if;
  if v_row.resolution_claim_id is not null then raise exception 'HITL_RESOLUTION_ALREADY_CLAIMED'; end if;
  if v_row.status <> 'pending_approval' or v_row.approval_recovery_state <> 'expired_recoverable' then raise exception 'HITL_RUN_NOT_EXPIRED_RECOVERABLE'; end if;
  if v_row.sdk_state is null or v_row.state_sha256 is null then raise exception 'HITL_DURABLE_STATE_MISSING'; end if;
  update public.sis_agent_hitl_runs
  set approval_recovery_state='active',approval_recovery_count=approval_recovery_count+1,approval_last_checked_at=v_now,approval_expires_at=v_now+make_interval(secs=>p_extend_seconds),metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('recovered_at',v_now,'recovery_extension_seconds',p_extend_seconds),updated_at=v_now
  where id=p_hitl_id;
  return jsonb_build_object('ok',true,'hitl_id',p_hitl_id,'status','pending_approval','approval_recovery_state','active','approval_expires_at',v_now+make_interval(secs=>p_extend_seconds));
end;
$$;

create or replace function public.sis_agent_hitl_read_v1(p_hitl_id uuid)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select case when r.id is null then null else jsonb_build_object(
    'id',r.id,'work_item_key',r.work_item_key,'observed_work_item_key',r.observed_work_item_key,'environment_key',r.environment_key,'actor_key',r.actor_key,'resolver_worker_key',r.resolver_worker_key,
    'capability_key',r.capability_key,'resource_key',r.resource_key,'action_key',r.action_key,'authorization_policy_version',r.authorization_policy_version,'authorization_decision',r.authorization_decision,'authorization_evaluation_id',r.authorization_evaluation_id,
    'status',r.status,'resolution',r.resolution,'resolution_claim_id',r.resolution_claim_id,'resolution_claim_decision',r.resolution_claim_decision,'resolution_claimed_at',r.resolution_claimed_at,'resolution_claimed_by',r.resolution_claimed_by,'resolution_claim_completed_at',r.resolution_claim_completed_at,
    'sdk_name',r.sdk_name,'sdk_version',r.sdk_version,'trace_id',r.trace_id,'tool_name',r.tool_name,'tool_call_id',r.tool_call_id,'action_fingerprint',r.action_fingerprint,'state_sha256',r.state_sha256,'resumed_state_sha256',r.resumed_state_sha256,
    'interruption_count',r.interruption_count,'tool_execution_count',r.tool_execution_count,'approval_expires_at',r.approval_expires_at,'approval_last_checked_at',r.approval_last_checked_at,'approval_recovery_state',r.approval_recovery_state,'approval_recovery_count',r.approval_recovery_count,
    'provider_write_performed',r.provider_write_performed,'mail_write_performed',r.mail_write_performed,'execution_gate_changed',r.execution_gate_changed,'approval_gate_changed',r.approval_gate_changed,'final_output',r.final_output,'error_summary',r.error_summary,'metadata',r.metadata,
    'created_at',r.created_at,'updated_at',r.updated_at,'resolved_at',r.resolved_at,'serialized_state_persisted',r.sdk_state is not null
  ) end from public.sis_agent_hitl_runs r where r.id=p_hitl_id;
$$;

revoke all on function public.sis_agent_hitl_effect_commit_claimed_v2(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_effect_commit_claimed_v2(uuid,uuid,text) to service_role;

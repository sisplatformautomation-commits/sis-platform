-- P3-047: Control Plane -> TEST Execution Plane bridge for P3-046.
-- Runtime subject bindings are provisioned as environment data and are intentionally not hard-coded here.

create table if not exists public.sis_control_execution_bindings (
  binding_key text primary key,
  auth_subject uuid not null,
  worker_key text not null,
  worker_role text not null check (worker_role in ('worker','reviewer')),
  environment_key text not null check (environment_key in ('dev','test')),
  source_project_ref text not null,
  status text not null default 'active' check (status in ('active','disabled')),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(auth_subject, environment_key)
);

create table if not exists public.sis_control_execution_sessions (
  session_id uuid primary key default gen_random_uuid(),
  binding_key text not null references public.sis_control_execution_bindings(binding_key) on delete restrict,
  job_id uuid not null references public.sis_jobs(id) on delete restrict,
  attempt_id uuid not null unique references public.sis_job_attempts(id) on delete restrict,
  lease_token uuid not null,
  runtime_ref text not null,
  status text not null default 'running' check (status in ('running','submitted','failed','expired')),
  heartbeat_at timestamptz not null default now(),
  lease_expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sis_control_execution_bindings enable row level security;
alter table public.sis_control_execution_sessions enable row level security;
revoke all on public.sis_control_execution_bindings from public, anon, authenticated;
revoke all on public.sis_control_execution_sessions from public, anon, authenticated;

create or replace function public.sis_control_execution_claim_v1(
  p_auth_subject uuid,
  p_environment_key text,
  p_job_id uuid,
  p_lease_seconds integer default 900
) returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_binding_key text; v_worker_key text; v_worker_role text; v_env text; v_source_project text;
  v_job_type text; v_job_status text; v_job_metadata jsonb; v_corr uuid; v_max_attempts integer; v_available_at timestamptz;
  v_assigned_worker text; v_assignment_state text; v_assignment_env text; v_approval_required boolean; v_required_resource_keys text[];
  v_attempt_id uuid; v_attempt_no integer; v_token uuid:=gen_random_uuid(); v_session_id uuid:=gen_random_uuid();
  v_expires timestamptz; v_runtime_ref text;
begin
  if p_lease_seconds < 60 or p_lease_seconds > 3600 then raise exception 'INVALID_LEASE_SECONDS'; end if;
  select binding_key,worker_key,worker_role,environment_key,source_project_ref
    into v_binding_key,v_worker_key,v_worker_role,v_env,v_source_project
  from public.sis_control_execution_bindings
  where auth_subject=p_auth_subject and environment_key=lower(btrim(p_environment_key)) and status='active';
  if v_binding_key is null or v_worker_role<>'worker' then raise exception 'CONTROL_EXECUTION_WORKER_BINDING_REQUIRED'; end if;
  if v_worker_key<>'sis.worker.integration' or v_env<>'dev' then raise exception 'P3_046_DEV_INTEGRATION_WORKER_REQUIRED'; end if;

  select j.job_type,j.status,j.metadata,j.correlation_id,j.max_attempts,j.available_at,
         a.assigned_worker_key,a.assignment_state,a.environment_key,a.approval_required,a.required_resource_keys
    into v_job_type,v_job_status,v_job_metadata,v_corr,v_max_attempts,v_available_at,
         v_assigned_worker,v_assignment_state,v_assignment_env,v_approval_required,v_required_resource_keys
  from public.sis_jobs j join public.sis_agent_job_assignments a on a.job_id=j.id
  where j.id=p_job_id for update of j,a;
  if v_job_type is null then raise exception 'JOB_NOT_FOUND'; end if;
  if v_job_type<>'make_dev_read_inventory' or coalesce(v_job_metadata->>'work_item_key','')<>'P3-046' then raise exception 'P3_046_JOB_REQUIRED'; end if;
  if v_assigned_worker<>v_worker_key or v_assignment_env<>v_env then raise exception 'JOB_BINDING_MISMATCH'; end if;
  if v_job_status<>'queued' or v_assignment_state<>'queued' or v_available_at>now() then raise exception 'JOB_NOT_CLAIMABLE'; end if;
  if v_approval_required and not public.sis_agent_job_approval_ok_v1(p_job_id) then raise exception 'APPROVAL_GATE_NOT_SATISFIED'; end if;
  if not ('make.inventory.dev.sis_platform'=any(coalesce(v_required_resource_keys,array[]::text[]))) then raise exception 'P3_043_RESOURCE_BINDING_REQUIRED'; end if;

  select coalesce(max(attempt_no),0)+1 into v_attempt_no from public.sis_job_attempts where job_id=p_job_id;
  if v_attempt_no>v_max_attempts then raise exception 'MAX_ATTEMPTS_EXCEEDED'; end if;
  v_expires:=now()+make_interval(secs=>p_lease_seconds);
  v_runtime_ref:='sis-control-execution-bridge:dev:'||v_session_id::text;
  insert into public.sis_job_attempts(job_id,attempt_no,status,worker_id,runtime_ref,correlation_id,claimed_at,heartbeat_at,lease_expires_at,started_at,metadata,metadata_schema_version)
  values(p_job_id,v_attempt_no,'running',v_worker_key,v_runtime_ref,v_corr,now(),now(),v_expires,now(),jsonb_build_object('orchestration_version','p3-047-control-execution-v1','source_project_ref',v_source_project,'auth_subject_bound',true),1)
  returning id into v_attempt_id;
  update public.sis_jobs set status='running',started_at=coalesce(started_at,now()),updated_at=now() where id=p_job_id;
  update public.sis_agent_job_assignments set assignment_state='running',active_attempt_id=v_attempt_id,lease_token=v_token,updated_at=now() where job_id=p_job_id;
  insert into public.sis_control_execution_sessions(session_id,binding_key,job_id,attempt_id,lease_token,runtime_ref,status,heartbeat_at,lease_expires_at)
  values(v_session_id,v_binding_key,p_job_id,v_attempt_id,v_token,v_runtime_ref,'running',now(),v_expires);
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(p_job_id,v_attempt_id,'agent.job.claimed',v_worker_key,'info',v_corr,jsonb_build_object('attempt_no',v_attempt_no,'lease_expires_at',v_expires,'runtime_ref',v_runtime_ref,'bridge_version','p3-047-control-execution-v1'));
  return jsonb_build_object('ok',true,'claimed',true,'session_id',v_session_id,'job_id',p_job_id,'job_type',v_job_type,'environment_key',v_env,'runtime_ref',v_runtime_ref,'lease_expires_at',v_expires,'metadata',v_job_metadata);
end; $$;

create or replace function public.sis_control_execution_heartbeat_v1(p_auth_subject uuid,p_session_id uuid,p_extend_seconds integer default 900)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_job_id uuid; v_attempt_id uuid; v_lease_token uuid; v_runtime_ref text; v_session_status text; v_worker_key text; v_r jsonb; v_expires timestamptz;
begin
  select s.job_id,s.attempt_id,s.lease_token,s.runtime_ref,s.status,b.worker_key into v_job_id,v_attempt_id,v_lease_token,v_runtime_ref,v_session_status,v_worker_key
  from public.sis_control_execution_sessions s join public.sis_control_execution_bindings b on b.binding_key=s.binding_key
  where s.session_id=p_session_id and b.auth_subject=p_auth_subject and b.status='active' for update of s;
  if v_job_id is null or v_session_status<>'running' then raise exception 'CONTROL_EXECUTION_SESSION_NOT_RUNNING'; end if;
  v_r:=public.sis_agent_worker_heartbeat_v1(v_worker_key,v_attempt_id,v_lease_token,p_extend_seconds);
  v_expires:=nullif(v_r->>'lease_expires_at','')::timestamptz;
  update public.sis_control_execution_sessions set heartbeat_at=now(),lease_expires_at=v_expires,updated_at=now() where session_id=p_session_id;
  return jsonb_build_object('ok',true,'session_id',p_session_id,'job_id',v_job_id,'runtime_ref',v_runtime_ref,'lease_expires_at',v_expires);
end; $$;

create or replace function public.sis_control_execution_step_v1(p_auth_subject uuid,p_session_id uuid,p_operation text,p_status text,p_summary jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_job_id uuid; v_attempt_id uuid; v_runtime_ref text; v_session_status text; v_worker_key text; v_step_id uuid; v_order integer; v_corr uuid;
begin
  if p_operation not in ('list_organization','list_teams','list_scenarios','read_scenario_metadata','read_scenario_blueprints','read_connections_metadata','read_webhook_and_schedule_metadata') then raise exception 'OPERATION_NOT_ALLOWED'; end if;
  if p_status not in ('succeeded','failed') then raise exception 'INVALID_STEP_STATUS'; end if;
  if p_summary is null or jsonb_typeof(p_summary)<>'object' or pg_column_size(p_summary)>16384 then raise exception 'INVALID_STEP_SUMMARY'; end if;
  select s.job_id,s.attempt_id,s.runtime_ref,s.status,b.worker_key into v_job_id,v_attempt_id,v_runtime_ref,v_session_status,v_worker_key
  from public.sis_control_execution_sessions s join public.sis_control_execution_bindings b on b.binding_key=s.binding_key
  where s.session_id=p_session_id and b.auth_subject=p_auth_subject and b.status='active';
  if v_job_id is null or v_session_status<>'running' then raise exception 'CONTROL_EXECUTION_SESSION_NOT_RUNNING'; end if;
  select correlation_id into v_corr from public.sis_jobs where id=v_job_id;
  v_order:=array_position(array['list_organization','list_teams','list_scenarios','read_scenario_metadata','read_scenario_blueprints','read_connections_metadata','read_webhook_and_schedule_metadata']::text[],p_operation);
  insert into public.sis_job_steps(job_id,attempt_id,step_key,step_order,step_type,status,correlation_id,started_at,finished_at,runtime_ref,metadata,metadata_schema_version)
  values(v_job_id,v_attempt_id,'make_inventory_'||p_operation,v_order,'provider.read',p_status,v_corr,now(),now(),v_runtime_ref,jsonb_build_object('operation',p_operation,'summary',p_summary,'bridge_version','p3-047-control-execution-v1'),1)
  on conflict (attempt_id,step_key) do update set status=excluded.status,finished_at=now(),runtime_ref=excluded.runtime_ref,metadata=excluded.metadata,updated_at=now()
  returning id into v_step_id;
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,v_attempt_id,'agent.step.completed',v_worker_key,case when p_status='failed' then 'error' else 'info' end,v_corr,jsonb_build_object('step_id',v_step_id,'operation',p_operation,'status',p_status));
  return jsonb_build_object('ok',true,'job_id',v_job_id,'step_key','make_inventory_'||p_operation,'status',p_status);
end; $$;

create or replace function public.sis_control_execution_submit_v1(p_auth_subject uuid,p_session_id uuid,p_result jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_job_id uuid; v_attempt_id uuid; v_lease_token uuid; v_runtime_ref text; v_session_status text; v_worker_key text; v_r jsonb;
begin
  if p_result is null or jsonb_typeof(p_result)<>'object' or pg_column_size(p_result)>32768 then raise exception 'INVALID_RESULT'; end if;
  select s.job_id,s.attempt_id,s.lease_token,s.runtime_ref,s.status,b.worker_key into v_job_id,v_attempt_id,v_lease_token,v_runtime_ref,v_session_status,v_worker_key
  from public.sis_control_execution_sessions s join public.sis_control_execution_bindings b on b.binding_key=s.binding_key
  where s.session_id=p_session_id and b.auth_subject=p_auth_subject and b.status='active' for update of s;
  if v_job_id is null or v_session_status<>'running' then raise exception 'CONTROL_EXECUTION_SESSION_NOT_RUNNING'; end if;
  v_r:=public.sis_agent_worker_submit_v1(v_worker_key,v_attempt_id,v_lease_token,p_result);
  update public.sis_control_execution_sessions set status='submitted',heartbeat_at=now(),updated_at=now() where session_id=p_session_id;
  return jsonb_build_object('ok',true,'session_id',p_session_id,'job_id',v_job_id,'runtime_ref',v_runtime_ref,'review_required',v_r->'review_required','reviewer_worker_key',v_r->'reviewer_worker_key','job_status',v_r->'job_status');
end; $$;

create or replace function public.sis_control_execution_fail_v1(p_auth_subject uuid,p_session_id uuid,p_error_code text,p_error_message text,p_evidence jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_job_id uuid; v_attempt_id uuid; v_lease_token uuid; v_session_status text; v_worker_key text; v_r jsonb;
begin
  select s.job_id,s.attempt_id,s.lease_token,s.status,b.worker_key into v_job_id,v_attempt_id,v_lease_token,v_session_status,v_worker_key
  from public.sis_control_execution_sessions s join public.sis_control_execution_bindings b on b.binding_key=s.binding_key
  where s.session_id=p_session_id and b.auth_subject=p_auth_subject and b.status='active' for update of s;
  if v_job_id is null or v_session_status<>'running' then raise exception 'CONTROL_EXECUTION_SESSION_NOT_RUNNING'; end if;
  v_r:=public.sis_agent_worker_fail_v1(v_worker_key,v_attempt_id,v_lease_token,p_error_code,p_error_message,p_evidence);
  update public.sis_control_execution_sessions set status='failed',updated_at=now() where session_id=p_session_id;
  return jsonb_build_object('ok',true,'session_id',p_session_id,'job_id',v_job_id,'job_status',v_r->'job_status','retry_scheduled',v_r->'retry_scheduled');
end; $$;

create or replace function public.sis_control_execution_review_context_v1(p_auth_subject uuid,p_job_id uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_binding_key text; v_worker_key text; v_worker_role text; v_attempt_id uuid; v_assigned_worker text; v_profile text; v_state text; v_result jsonb; v_steps jsonb;
begin
  select binding_key,worker_key,worker_role into v_binding_key,v_worker_key,v_worker_role from public.sis_control_execution_bindings where auth_subject=p_auth_subject and environment_key='dev' and status='active';
  if v_binding_key is null or v_worker_role<>'reviewer' or v_worker_key<>'sis.reviewer.qa_security' then raise exception 'CONTROL_EXECUTION_REVIEWER_BINDING_REQUIRED'; end if;
  select active_attempt_id,assigned_worker_key,review_profile,assignment_state into v_attempt_id,v_assigned_worker,v_profile,v_state from public.sis_agent_job_assignments where job_id=p_job_id and reviewer_worker_key=v_worker_key;
  if v_attempt_id is null or v_state<>'review_required' then raise exception 'REVIEW_NOT_READY'; end if;
  select metadata->'result' into v_result from public.sis_job_attempts where id=v_attempt_id and status='succeeded';
  select coalesce(jsonb_agg(jsonb_build_object('step_key',step_key,'status',status,'metadata',metadata) order by step_order),'[]'::jsonb) into v_steps from public.sis_job_steps where attempt_id=v_attempt_id;
  return jsonb_build_object('ok',true,'job_id',p_job_id,'assigned_worker_key',v_assigned_worker,'review_profile',v_profile,'result',coalesce(v_result,'{}'::jsonb),'steps',v_steps);
end; $$;

create or replace function public.sis_control_execution_review_submit_v1(p_auth_subject uuid,p_job_id uuid,p_decision text,p_evidence jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public' as $$
declare v_binding_key text; v_worker_key text; v_worker_role text; v_attempt_id uuid; v_r jsonb;
begin
  select binding_key,worker_key,worker_role into v_binding_key,v_worker_key,v_worker_role from public.sis_control_execution_bindings where auth_subject=p_auth_subject and environment_key='dev' and status='active';
  if v_binding_key is null or v_worker_role<>'reviewer' or v_worker_key<>'sis.reviewer.qa_security' then raise exception 'CONTROL_EXECUTION_REVIEWER_BINDING_REQUIRED'; end if;
  select active_attempt_id into v_attempt_id from public.sis_agent_job_assignments where job_id=p_job_id and reviewer_worker_key=v_worker_key and assignment_state='review_required';
  if v_attempt_id is null then raise exception 'REVIEW_NOT_READY'; end if;
  v_r:=public.sis_agent_reviewer_submit_v1(v_worker_key,v_attempt_id,p_decision,p_evidence);
  return jsonb_build_object('ok',true,'job_id',p_job_id,'decision',p_decision,'job_status',v_r->'job_status');
end; $$;

revoke all on function public.sis_control_execution_claim_v1(uuid,text,uuid,integer) from public,anon,authenticated;
revoke all on function public.sis_control_execution_heartbeat_v1(uuid,uuid,integer) from public,anon,authenticated;
revoke all on function public.sis_control_execution_step_v1(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sis_control_execution_submit_v1(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.sis_control_execution_fail_v1(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sis_control_execution_review_context_v1(uuid,uuid) from public,anon,authenticated;
revoke all on function public.sis_control_execution_review_submit_v1(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.sis_control_execution_claim_v1(uuid,text,uuid,integer) to service_role;
grant execute on function public.sis_control_execution_heartbeat_v1(uuid,uuid,integer) to service_role;
grant execute on function public.sis_control_execution_step_v1(uuid,uuid,text,text,jsonb) to service_role;
grant execute on function public.sis_control_execution_submit_v1(uuid,uuid,jsonb) to service_role;
grant execute on function public.sis_control_execution_fail_v1(uuid,uuid,text,text,jsonb) to service_role;
grant execute on function public.sis_control_execution_review_context_v1(uuid,uuid) to service_role;
grant execute on function public.sis_control_execution_review_submit_v1(uuid,uuid,text,jsonb) to service_role;

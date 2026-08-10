-- P3-045 hardening: redact lease secrets, enforce concurrency, recover expired leases.

create or replace function public.sis_agent_worker_claim_v1(p_worker_key text,p_lease_seconds integer default 900)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job_id uuid;
  v_corr uuid;
  v_attempt_id uuid;
  v_attempt_no integer;
  v_token uuid:=gen_random_uuid();
  v_expires timestamptz;
  v_max integer;
  v_max_concurrency integer;
  v_running integer;
begin
  if p_lease_seconds<60 or p_lease_seconds>3600 then raise exception 'INVALID_LEASE_SECONDS'; end if;
  select max_concurrency into v_max_concurrency from public.sis_agent_workers
  where worker_key=p_worker_key and worker_role='worker' and status='active';
  if v_max_concurrency is null then raise exception 'WORKER_NOT_ACTIVE'; end if;

  select count(*) into v_running from public.sis_agent_job_assignments a
  join public.sis_job_attempts at on at.id=a.active_attempt_id
  where a.assigned_worker_key=p_worker_key and a.assignment_state='running' and at.status='running'
    and (at.lease_expires_at is null or at.lease_expires_at>=now());
  if v_running>=v_max_concurrency then
    return jsonb_build_object('ok',true,'claimed',false,'reason','worker_at_capacity','running',v_running,'max_concurrency',v_max_concurrency);
  end if;

  select a.job_id,j.correlation_id,j.max_attempts into v_job_id,v_corr,v_max
  from public.sis_agent_job_assignments a
  join public.sis_jobs j on j.id=a.job_id
  where a.assigned_worker_key=p_worker_key and a.assignment_state='queued' and j.status='queued' and j.available_at<=now()
    and (not a.approval_required or public.sis_agent_job_approval_ok_v1(j.id))
  order by j.priority asc,j.created_at asc
  for update of a,j skip locked
  limit 1;
  if v_job_id is null then return jsonb_build_object('ok',true,'claimed',false,'reason','no_eligible_job'); end if;

  select coalesce(max(attempt_no),0)+1 into v_attempt_no from public.sis_job_attempts where job_id=v_job_id;
  if v_attempt_no>v_max then
    update public.sis_jobs set status='failed',finished_at=now(),updated_at=now() where id=v_job_id;
    update public.sis_agent_job_assignments set assignment_state='failed',updated_at=now() where job_id=v_job_id;
    raise exception 'MAX_ATTEMPTS_EXCEEDED';
  end if;
  v_expires:=now()+make_interval(secs=>p_lease_seconds);
  insert into public.sis_job_attempts(job_id,attempt_no,status,worker_id,correlation_id,claimed_at,heartbeat_at,lease_expires_at,started_at,metadata,metadata_schema_version)
  values(v_job_id,v_attempt_no,'running',p_worker_key,v_corr,now(),now(),v_expires,now(),jsonb_build_object('orchestration_version','p3-045-v1'),1)
  returning id into v_attempt_id;
  update public.sis_jobs set status='running',started_at=coalesce(started_at,now()),updated_at=now() where id=v_job_id;
  update public.sis_agent_job_assignments set assignment_state='running',active_attempt_id=v_attempt_id,lease_token=v_token,updated_at=now() where job_id=v_job_id;
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,v_attempt_id,'agent.job.claimed',p_worker_key,'info',v_corr,jsonb_build_object('lease_expires_at',v_expires,'attempt_no',v_attempt_no));
  return jsonb_build_object('ok',true,'claimed',true,'job_id',v_job_id,'attempt_id',v_attempt_id,'attempt_no',v_attempt_no,'lease_token',v_token,'lease_expires_at',v_expires);
end;
$$;
revoke all on function public.sis_agent_worker_claim_v1(text,integer) from public, anon, authenticated;
grant execute on function public.sis_agent_worker_claim_v1(text,integer) to service_role;

create or replace function public.sis_agent_worker_fail_v1(p_worker_key text,p_attempt_id uuid,p_lease_token uuid,p_error_code text,p_error_message text,p_evidence jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job_id uuid; v_corr uuid; v_attempt_no integer; v_max integer; v_retry boolean;
begin
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or pg_column_size(p_evidence)>32768 then raise exception 'INVALID_EVIDENCE'; end if;
  select a.job_id,j.correlation_id,at.attempt_no,j.max_attempts into v_job_id,v_corr,v_attempt_no,v_max
  from public.sis_agent_job_assignments a
  join public.sis_jobs j on j.id=a.job_id
  join public.sis_job_attempts at on at.id=a.active_attempt_id
  where a.active_attempt_id=p_attempt_id and a.assigned_worker_key=p_worker_key and a.lease_token=p_lease_token
    and a.assignment_state='running' and at.status='running' and (at.lease_expires_at is null or at.lease_expires_at>=now())
  for update of a,j,at;
  if v_job_id is null then raise exception 'LEASE_NOT_VALID'; end if;
  v_retry:=v_attempt_no<v_max;
  update public.sis_job_attempts set status='failed',finished_at=now(),error_code=left(coalesce(p_error_code,'WORKER_FAILED'),200),error_message=left(coalesce(p_error_message,'Worker failed'),4000),metadata=metadata||jsonb_build_object('failure_evidence',p_evidence),updated_at=now() where id=p_attempt_id;
  if v_retry then
    update public.sis_jobs set status='retry_wait',available_at=now()+interval '30 seconds',updated_at=now() where id=v_job_id;
    update public.sis_agent_job_assignments set assignment_state='rework',active_attempt_id=null,lease_token=null,updated_at=now() where job_id=v_job_id;
  else
    update public.sis_jobs set status='failed',finished_at=now(),updated_at=now() where id=v_job_id;
    update public.sis_agent_job_assignments set assignment_state='failed',lease_token=null,updated_at=now() where job_id=v_job_id;
  end if;
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,p_attempt_id,'agent.worker.failed',p_worker_key,'error',v_corr,jsonb_build_object('retry_scheduled',v_retry,'attempt_no',v_attempt_no,'max_attempts',v_max,'error_code',p_error_code));
  return jsonb_build_object('ok',true,'job_id',v_job_id,'attempt_id',p_attempt_id,'retry_scheduled',v_retry,'job_status',case when v_retry then 'retry_wait' else 'failed' end);
end;
$$;
revoke all on function public.sis_agent_worker_fail_v1(text,uuid,uuid,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.sis_agent_worker_fail_v1(text,uuid,uuid,text,text,jsonb) to service_role;

create or replace function public.sis_agent_supervisor_recover_expired_leases_v1(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  r record;
  v_count integer:=0;
  v_retry boolean;
begin
  for r in
    select a.job_id,a.active_attempt_id,j.correlation_id,at.attempt_no,j.max_attempts,a.assigned_worker_key
    from public.sis_agent_job_assignments a
    join public.sis_jobs j on j.id=a.job_id
    join public.sis_job_attempts at on at.id=a.active_attempt_id
    where a.assignment_state='running' and j.status='running' and at.status='running'
      and at.lease_expires_at is not null and at.lease_expires_at<now()
    order by at.lease_expires_at
    for update of a,j,at skip locked
    limit greatest(1,least(coalesce(p_limit,20),100))
  loop
    v_retry:=r.attempt_no<r.max_attempts;
    update public.sis_job_attempts set status='timed_out',finished_at=now(),error_code='LEASE_EXPIRED',error_message='Worker lease expired before completion',updated_at=now() where id=r.active_attempt_id;
    if v_retry then
      update public.sis_jobs set status='retry_wait',available_at=now(),updated_at=now() where id=r.job_id;
      update public.sis_agent_job_assignments set assignment_state='rework',active_attempt_id=null,lease_token=null,updated_at=now() where job_id=r.job_id;
    else
      update public.sis_jobs set status='failed',finished_at=now(),updated_at=now() where id=r.job_id;
      update public.sis_agent_job_assignments set assignment_state='failed',lease_token=null,updated_at=now() where job_id=r.job_id;
    end if;
    insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
    values(r.job_id,r.active_attempt_id,'agent.lease.expired','sis.supervisor','warning',r.correlation_id,jsonb_build_object('worker_key',r.assigned_worker_key,'retry_scheduled',v_retry));
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('ok',true,'recovered',v_count);
end;
$$;
revoke all on function public.sis_agent_supervisor_recover_expired_leases_v1(integer) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_recover_expired_leases_v1(integer) to service_role;

create or replace function public.sis_agent_supervisor_job_status_v1(p_job_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'job',jsonb_build_object(
      'id',j.id,'work_item_id',j.work_item_id,'job_type',j.job_type,'status',j.status,'priority',j.priority,
      'dedupe_key',j.dedupe_key,'max_attempts',j.max_attempts,'available_at',j.available_at,'correlation_id',j.correlation_id,
      'requested_by',j.requested_by,'started_at',j.started_at,'finished_at',j.finished_at,'metadata',j.metadata,'created_at',j.created_at,'updated_at',j.updated_at
    ),
    'assignment',jsonb_build_object(
      'job_id',a.job_id,'environment_key',a.environment_key,'assigned_worker_key',a.assigned_worker_key,'reviewer_worker_key',a.reviewer_worker_key,
      'required_capabilities',to_jsonb(a.required_capabilities),'required_resource_keys',to_jsonb(a.required_resource_keys),
      'review_required',a.review_required,'review_profile',a.review_profile,'approval_required',a.approval_required,
      'assignment_state',a.assignment_state,'active_attempt_id',a.active_attempt_id,'metadata',a.metadata,'created_at',a.created_at,'updated_at',a.updated_at
    ),
    'attempts',coalesce((select jsonb_agg(jsonb_build_object(
      'id',at.id,'attempt_no',at.attempt_no,'status',at.status,'worker_id',at.worker_id,'runtime_ref',at.runtime_ref,
      'correlation_id',at.correlation_id,'claimed_at',at.claimed_at,'heartbeat_at',at.heartbeat_at,'lease_expires_at',at.lease_expires_at,
      'started_at',at.started_at,'finished_at',at.finished_at,'error_code',at.error_code,'error_message',at.error_message,'metadata',at.metadata
    ) order by at.attempt_no) from public.sis_job_attempts at where at.job_id=j.id),'[]'::jsonb),
    'reviews',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.sis_agent_reviews r where r.job_id=j.id),'[]'::jsonb)
  )
  from public.sis_jobs j join public.sis_agent_job_assignments a on a.job_id=j.id where j.id=p_job_id;
$$;
revoke all on function public.sis_agent_supervisor_job_status_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_job_status_v1(uuid) to service_role;

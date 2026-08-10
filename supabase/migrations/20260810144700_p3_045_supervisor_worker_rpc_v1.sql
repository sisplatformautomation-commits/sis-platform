-- P3-045 controlled supervisor/worker RPCs.

create or replace function public.sis_agent_resource_guard_v1(p_environment_key text, p_resource_keys text[])
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_total integer;
  v_distinct integer;
  v_match integer;
begin
  if p_environment_key not in ('dev','test','uat','prod') then
    raise exception 'INVALID_ENVIRONMENT';
  end if;
  if p_resource_keys is null then
    raise exception 'RESOURCE_KEYS_REQUIRED';
  end if;
  select count(*),count(distinct x) into v_total,v_distinct from unnest(p_resource_keys) as t(x);
  if v_total <> v_distinct or exists(select 1 from unnest(p_resource_keys) x where x is null or btrim(x)='') then
    raise exception 'INVALID_OR_DUPLICATE_RESOURCE_KEYS';
  end if;
  if v_total=0 then return; end if;
  if to_regclass('public.sis_gpt_action_resources') is null then
    raise exception 'ACTION_RESOURCE_REGISTRY_REQUIRED';
  end if;
  execute 'select count(*) from public.sis_gpt_action_resources where resource_key = any($1) and status=''active'' and environment_key=$2'
    into v_match using p_resource_keys,p_environment_key;
  if v_match <> v_total then
    raise exception 'ACTION_RESOURCE_NOT_ALLOWED_FOR_ENVIRONMENT';
  end if;
end;
$$;
revoke all on function public.sis_agent_resource_guard_v1(text,text[]) from public, anon, authenticated, service_role;

create or replace function public.sis_agent_job_approval_ok_v1(p_job_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_required boolean;
  v_scopes text[];
  v_scope text;
  v_decision text;
begin
  select approval_required,coalesce(array(select jsonb_array_elements_text(coalesce(metadata->'required_approval_scopes','[]'::jsonb))),'{}'::text[])
    into v_required,v_scopes
  from public.sis_agent_job_assignments where job_id=p_job_id;
  if not found then return false; end if;
  if not v_required then return true; end if;
  if cardinality(v_scopes)=0 then return false; end if;
  foreach v_scope in array v_scopes loop
    select decision into v_decision
    from public.sis_agent_job_approvals
    where job_id=p_job_id
      and approval_scope=v_scope
      and (expires_at is null or expires_at>now())
    order by granted_at desc,created_at desc
    limit 1;
    if coalesce(v_decision,'denied') <> 'granted' then return false; end if;
  end loop;
  return true;
end;
$$;
revoke all on function public.sis_agent_job_approval_ok_v1(uuid) from public, anon, authenticated, service_role;

create or replace function public.sis_agent_worker_list_v1(p_environment_key text default null)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'worker_key',w.worker_key,
    'worker_role',w.worker_role,
    'domain_key',w.domain_key,
    'status',w.status,
    'max_concurrency',w.max_concurrency,
    'runtime_binding',w.runtime_binding,
    'capabilities',coalesce((
      select jsonb_agg(jsonb_build_object(
        'capability_key',wc.capability_key,
        'environment_key',wc.environment_key,
        'risk_level',c.risk_level,
        'provider_write',c.provider_write,
        'external_financial_write',c.external_financial_write,
        'prod_approval_required',c.prod_approval_required,
        'independent_review_required',c.independent_review_required
      ) order by wc.capability_key,wc.environment_key)
      from public.sis_agent_worker_capabilities wc
      join public.sis_agent_capabilities c on c.capability_key=wc.capability_key
      where wc.worker_key=w.worker_key and wc.active=true
        and (p_environment_key is null or wc.environment_key=p_environment_key)
    ),'[]'::jsonb)
  ) order by w.worker_role,w.worker_key),'[]'::jsonb)
  from public.sis_agent_workers w
  where w.status='active'
    and (p_environment_key is null or p_environment_key in ('dev','test','uat','prod'));
$$;
revoke all on function public.sis_agent_worker_list_v1(text) from public, anon, authenticated;
grant execute on function public.sis_agent_worker_list_v1(text) to service_role;

create or replace function public.sis_agent_supervisor_queue_job_v1(
  p_work_item_key text,
  p_job_type text,
  p_environment_key text,
  p_required_capabilities text[],
  p_required_resource_keys text[] default '{}'::text[],
  p_dedupe_key text default null,
  p_priority smallint default 100,
  p_review_profile text default 'qa_security',
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_work_item_id uuid;
  v_job_id uuid;
  v_corr uuid := gen_random_uuid();
  v_worker text;
  v_reviewer text;
  v_review_profile text := p_review_profile;
  v_review_required boolean;
  v_approval_required boolean := false;
  v_scopes text[] := '{}'::text[];
  v_cap_count integer;
  v_distinct_count integer;
  v_dedupe text;
begin
  if p_environment_key not in ('dev','test','uat','prod') then raise exception 'INVALID_ENVIRONMENT'; end if;
  if p_job_type is null or btrim(p_job_type)='' then raise exception 'JOB_TYPE_REQUIRED'; end if;
  if p_priority < 0 or p_priority > 1000 then raise exception 'INVALID_PRIORITY'; end if;
  if p_review_profile not in ('none','qa','security','qa_security') then raise exception 'INVALID_REVIEW_PROFILE'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then raise exception 'INVALID_JOB_METADATA'; end if;
  if p_required_capabilities is null or cardinality(p_required_capabilities)=0 then raise exception 'CAPABILITIES_REQUIRED'; end if;
  if exists(select 1 from unnest(p_required_capabilities) x where x is null or btrim(x)='') then raise exception 'INVALID_CAPABILITY'; end if;
  select count(*),count(distinct x) into v_cap_count,v_distinct_count from unnest(p_required_capabilities) t(x);
  if v_cap_count<>v_distinct_count then raise exception 'DUPLICATE_CAPABILITY'; end if;
  if (select count(*) from public.sis_agent_capabilities where capability_key=any(p_required_capabilities))<>v_cap_count then
    raise exception 'UNKNOWN_CAPABILITY';
  end if;
  if not exists(
    select 1 from public.sis_agent_workers w
    where w.worker_key='sis.supervisor' and w.worker_role='supervisor' and w.status='active'
      and exists(select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='orchestration.plan' and wc.environment_key=p_environment_key and wc.active)
      and exists(select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='orchestration.delegate' and wc.environment_key=p_environment_key and wc.active)
  ) then raise exception 'SUPERVISOR_NOT_AUTHORIZED'; end if;

  select id into v_work_item_id from public.sis_work_items where item_key=btrim(p_work_item_key);
  if v_work_item_id is null then raise exception 'WORK_ITEM_NOT_FOUND'; end if;

  perform public.sis_agent_resource_guard_v1(p_environment_key,coalesce(p_required_resource_keys,'{}'::text[]));

  select w.worker_key into v_worker
  from public.sis_agent_workers w
  where w.worker_role='worker' and w.status='active'
    and not exists(
      select 1 from unnest(p_required_capabilities) c(capability_key)
      where not exists(
        select 1 from public.sis_agent_worker_capabilities wc
        where wc.worker_key=w.worker_key and wc.capability_key=c.capability_key
          and wc.environment_key=p_environment_key and wc.active
      )
    )
    and (
      select count(*) from public.sis_agent_job_assignments a
      join public.sis_jobs j on j.id=a.job_id
      where a.assigned_worker_key=w.worker_key and a.assignment_state in ('running','review_required')
        and j.status in ('running','blocked')
    ) < w.max_concurrency
  order by (
      select count(*) from public.sis_agent_job_assignments a
      where a.assigned_worker_key=w.worker_key and a.assignment_state in ('queued','running','review_required')
    ),w.worker_key
  limit 1;
  if v_worker is null then raise exception 'NO_ELIGIBLE_WORKER'; end if;

  select (p_review_profile<>'none') or exists(
    select 1 from public.sis_agent_capabilities c
    where c.capability_key=any(p_required_capabilities) and c.independent_review_required
  ) into v_review_required;
  if v_review_required and v_review_profile='none' then v_review_profile:='qa_security'; end if;

  if v_review_required then
    select w.worker_key into v_reviewer
    from public.sis_agent_workers w
    where w.worker_role='reviewer' and w.status='active' and w.worker_key<>v_worker
      and (v_review_profile not in ('qa','qa_security') or exists(
        select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='review.qa' and wc.environment_key=p_environment_key and wc.active
      ))
      and (v_review_profile not in ('security','qa_security') or exists(
        select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='review.security' and wc.environment_key=p_environment_key and wc.active
      ))
    order by w.worker_key limit 1;
    if v_reviewer is null then raise exception 'NO_ELIGIBLE_REVIEWER'; end if;
  end if;

  if p_environment_key='prod' and exists(select 1 from public.sis_agent_capabilities where capability_key=any(p_required_capabilities) and prod_approval_required) then
    v_scopes:=array_append(v_scopes,'prod_promotion');
  end if;
  if exists(select 1 from public.sis_agent_capabilities where capability_key=any(p_required_capabilities) and provider_write) then
    v_scopes:=array_append(v_scopes,'provider_write');
  end if;
  if exists(select 1 from public.sis_agent_capabilities where capability_key=any(p_required_capabilities) and external_financial_write) then
    v_scopes:=array_append(v_scopes,'external_financial_write');
  end if;
  if exists(select 1 from public.sis_agent_capabilities where capability_key=any(p_required_capabilities) and destructive) then
    v_scopes:=array_append(v_scopes,'destructive_change');
  end if;
  v_approval_required:=cardinality(v_scopes)>0;
  if v_approval_required then v_scopes:=array_prepend('execute',v_scopes); end if;

  v_dedupe:=coalesce(nullif(btrim(coalesce(p_dedupe_key,'')),''),'agent:'||btrim(p_work_item_key)||':'||btrim(p_job_type)||':'||gen_random_uuid()::text);

  insert into public.sis_jobs(work_item_id,job_type,status,priority,dedupe_key,max_attempts,available_at,correlation_id,requested_by,metadata,metadata_schema_version)
  values(v_work_item_id,btrim(p_job_type),case when v_approval_required then 'blocked' else 'queued' end,p_priority,v_dedupe,3,now(),v_corr,'sis.supervisor',
    p_metadata || jsonb_build_object(
      'orchestration_version','p3-045-v1','environment_key',p_environment_key,
      'assigned_worker_key',v_worker,'reviewer_worker_key',v_reviewer,
      'required_capabilities',to_jsonb(p_required_capabilities),'required_resource_keys',to_jsonb(coalesce(p_required_resource_keys,'{}'::text[])),
      'review_profile',v_review_profile,'approval_required',v_approval_required,'required_approval_scopes',to_jsonb(v_scopes)
    ),1)
  returning id into v_job_id;

  insert into public.sis_agent_job_assignments(job_id,environment_key,assigned_worker_key,reviewer_worker_key,required_capabilities,required_resource_keys,review_required,review_profile,approval_required,assignment_state,metadata)
  values(v_job_id,p_environment_key,v_worker,v_reviewer,p_required_capabilities,coalesce(p_required_resource_keys,'{}'::text[]),v_review_required,v_review_profile,v_approval_required,
    case when v_approval_required then 'blocked' else 'queued' end,
    jsonb_build_object('required_approval_scopes',to_jsonb(v_scopes),'planned_by','sis.supervisor'));

  insert into public.sis_job_events(job_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,'agent.job.planned','sis.supervisor','info',v_corr,
    jsonb_build_object('worker_key',v_worker,'reviewer_key',v_reviewer,'environment_key',p_environment_key,'approval_required',v_approval_required,'review_required',v_review_required));

  return jsonb_build_object('ok',true,'job_id',v_job_id,'correlation_id',v_corr,'assigned_worker_key',v_worker,'reviewer_worker_key',v_reviewer,
    'environment_key',p_environment_key,'status',case when v_approval_required then 'blocked' else 'queued' end,
    'approval_required',v_approval_required,'required_approval_scopes',to_jsonb(v_scopes),'review_required',v_review_required,'review_profile',v_review_profile);
end;
$$;
revoke all on function public.sis_agent_supervisor_queue_job_v1(text,text,text,text[],text[],text,smallint,text,jsonb) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_queue_job_v1(text,text,text,text[],text[],text,smallint,text,jsonb) to service_role;

create or replace function public.sis_agent_supervisor_release_approved_job_v1(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_corr uuid; v_worker text;
begin
  if not public.sis_agent_job_approval_ok_v1(p_job_id) then raise exception 'APPROVAL_GATE_NOT_SATISFIED'; end if;
  update public.sis_jobs set status='queued',available_at=now(),updated_at=now()
  where id=p_job_id and status='blocked' returning correlation_id into v_corr;
  if v_corr is null then raise exception 'JOB_NOT_BLOCKED_OR_NOT_FOUND'; end if;
  update public.sis_agent_job_assignments set assignment_state='queued',updated_at=now() where job_id=p_job_id returning assigned_worker_key into v_worker;
  insert into public.sis_job_events(job_id,event_type,source,severity,correlation_id,payload)
  values(p_job_id,'agent.job.approval_released','sis.supervisor','info',v_corr,jsonb_build_object('assigned_worker_key',v_worker));
  return jsonb_build_object('ok',true,'job_id',p_job_id,'status','queued','assigned_worker_key',v_worker);
end;
$$;
revoke all on function public.sis_agent_supervisor_release_approved_job_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_release_approved_job_v1(uuid) to service_role;

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
begin
  if p_lease_seconds<60 or p_lease_seconds>3600 then raise exception 'INVALID_LEASE_SECONDS'; end if;
  if not exists(select 1 from public.sis_agent_workers where worker_key=p_worker_key and worker_role='worker' and status='active') then
    raise exception 'WORKER_NOT_ACTIVE';
  end if;

  select a.job_id,j.correlation_id,j.max_attempts into v_job_id,v_corr,v_max
  from public.sis_agent_job_assignments a
  join public.sis_jobs j on j.id=a.job_id
  where a.assigned_worker_key=p_worker_key and a.assignment_state='queued' and j.status='queued' and j.available_at<=now()
    and (not a.approval_required or public.sis_agent_job_approval_ok_v1(j.id))
  order by j.priority asc,j.created_at asc
  for update of a,j skip locked
  limit 1;
  if v_job_id is null then return jsonb_build_object('ok',true,'claimed',false); end if;

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

create or replace function public.sis_agent_worker_heartbeat_v1(p_worker_key text,p_attempt_id uuid,p_lease_token uuid,p_extend_seconds integer default 900)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job_id uuid; v_expires timestamptz;
begin
  if p_extend_seconds<60 or p_extend_seconds>3600 then raise exception 'INVALID_LEASE_SECONDS'; end if;
  select a.job_id into v_job_id
  from public.sis_agent_job_assignments a
  join public.sis_job_attempts at on at.id=a.active_attempt_id
  where a.active_attempt_id=p_attempt_id and a.assigned_worker_key=p_worker_key and a.lease_token=p_lease_token
    and a.assignment_state='running' and at.status='running' and (at.lease_expires_at is null or at.lease_expires_at>=now())
  for update of a,at;
  if v_job_id is null then raise exception 'LEASE_NOT_VALID'; end if;
  v_expires:=now()+make_interval(secs=>p_extend_seconds);
  update public.sis_job_attempts set heartbeat_at=now(),lease_expires_at=v_expires,updated_at=now() where id=p_attempt_id;
  return jsonb_build_object('ok',true,'attempt_id',p_attempt_id,'lease_expires_at',v_expires);
end;
$$;
revoke all on function public.sis_agent_worker_heartbeat_v1(text,uuid,uuid,integer) from public, anon, authenticated;
grant execute on function public.sis_agent_worker_heartbeat_v1(text,uuid,uuid,integer) to service_role;

create or replace function public.sis_agent_worker_submit_v1(p_worker_key text,p_attempt_id uuid,p_lease_token uuid,p_result jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job_id uuid; v_corr uuid; v_review boolean; v_reviewer text;
begin
  if p_result is null or jsonb_typeof(p_result)<>'object' or pg_column_size(p_result)>32768 then raise exception 'INVALID_RESULT'; end if;
  select a.job_id,j.correlation_id,a.review_required,a.reviewer_worker_key into v_job_id,v_corr,v_review,v_reviewer
  from public.sis_agent_job_assignments a
  join public.sis_jobs j on j.id=a.job_id
  join public.sis_job_attempts at on at.id=a.active_attempt_id
  where a.active_attempt_id=p_attempt_id and a.assigned_worker_key=p_worker_key and a.lease_token=p_lease_token
    and a.assignment_state='running' and at.status='running' and (at.lease_expires_at is null or at.lease_expires_at>=now())
  for update of a,j,at;
  if v_job_id is null then raise exception 'LEASE_NOT_VALID'; end if;
  update public.sis_job_attempts set status='succeeded',finished_at=now(),heartbeat_at=now(),metadata=metadata||jsonb_build_object('result',p_result),updated_at=now() where id=p_attempt_id;
  if v_review then
    update public.sis_agent_job_assignments set assignment_state='review_required',lease_token=null,updated_at=now() where job_id=v_job_id;
    update public.sis_jobs set status='blocked',updated_at=now() where id=v_job_id;
  else
    update public.sis_agent_job_assignments set assignment_state='accepted',lease_token=null,updated_at=now() where job_id=v_job_id;
    update public.sis_jobs set status='succeeded',finished_at=now(),updated_at=now() where id=v_job_id;
  end if;
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,p_attempt_id,'agent.worker.submitted',p_worker_key,'info',v_corr,jsonb_build_object('review_required',v_review,'reviewer_worker_key',v_reviewer));
  return jsonb_build_object('ok',true,'job_id',v_job_id,'attempt_id',p_attempt_id,'review_required',v_review,'reviewer_worker_key',v_reviewer,'job_status',case when v_review then 'blocked' else 'succeeded' end);
end;
$$;
revoke all on function public.sis_agent_worker_submit_v1(text,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.sis_agent_worker_submit_v1(text,uuid,uuid,jsonb) to service_role;

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
    and a.assignment_state='running' and at.status='running'
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

create or replace function public.sis_agent_supervisor_requeue_ready_v1(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_count integer;
begin
  with ready as (
    select j.id from public.sis_jobs j join public.sis_agent_job_assignments a on a.job_id=j.id
    where j.status='retry_wait' and j.available_at<=now() and a.assignment_state='rework'
    order by j.available_at,j.created_at limit greatest(1,least(coalesce(p_limit,20),100)) for update of j,a skip locked
  ), uj as (
    update public.sis_jobs j set status='queued',updated_at=now() from ready r where j.id=r.id returning j.id
  )
  update public.sis_agent_job_assignments a set assignment_state='queued',updated_at=now() where a.job_id in (select id from uj);
  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',true,'requeued',v_count);
end;
$$;
revoke all on function public.sis_agent_supervisor_requeue_ready_v1(integer) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_requeue_ready_v1(integer) to service_role;

create or replace function public.sis_agent_reviewer_submit_v1(p_reviewer_worker_key text,p_attempt_id uuid,p_decision text,p_evidence jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_job_id uuid; v_corr uuid; v_worker text; v_profile text; v_env text; v_review_type text;
begin
  if p_decision not in ('pass','changes_required','fail') then raise exception 'INVALID_REVIEW_DECISION'; end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or pg_column_size(p_evidence)>32768 then raise exception 'INVALID_REVIEW_EVIDENCE'; end if;
  select a.job_id,j.correlation_id,a.assigned_worker_key,a.review_profile,a.environment_key into v_job_id,v_corr,v_worker,v_profile,v_env
  from public.sis_agent_job_assignments a
  join public.sis_jobs j on j.id=a.job_id
  join public.sis_job_attempts at on at.id=a.active_attempt_id
  where a.active_attempt_id=p_attempt_id and a.reviewer_worker_key=p_reviewer_worker_key and a.assignment_state='review_required' and at.status='succeeded'
  for update of a,j,at;
  if v_job_id is null then raise exception 'REVIEW_NOT_ASSIGNED'; end if;
  if v_worker=p_reviewer_worker_key then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;
  if not exists(select 1 from public.sis_agent_workers where worker_key=p_reviewer_worker_key and worker_role='reviewer' and status='active') then raise exception 'REVIEWER_NOT_ACTIVE'; end if;
  if v_profile in ('qa','qa_security') and not exists(select 1 from public.sis_agent_worker_capabilities where worker_key=p_reviewer_worker_key and capability_key='review.qa' and environment_key=v_env and active) then raise exception 'QA_REVIEW_CAPABILITY_REQUIRED'; end if;
  if v_profile in ('security','qa_security') and not exists(select 1 from public.sis_agent_worker_capabilities where worker_key=p_reviewer_worker_key and capability_key='review.security' and environment_key=v_env and active) then raise exception 'SECURITY_REVIEW_CAPABILITY_REQUIRED'; end if;
  v_review_type:=v_profile;
  insert into public.sis_agent_reviews(job_id,attempt_id,reviewer_worker_key,review_type,decision,evidence)
  values(v_job_id,p_attempt_id,p_reviewer_worker_key,v_review_type,p_decision,p_evidence);
  if p_decision='pass' then
    update public.sis_agent_job_assignments set assignment_state='accepted',active_attempt_id=p_attempt_id,updated_at=now() where job_id=v_job_id;
    update public.sis_jobs set status='succeeded',finished_at=now(),updated_at=now() where id=v_job_id;
  elsif p_decision='changes_required' then
    update public.sis_agent_job_assignments set assignment_state='rework',active_attempt_id=null,lease_token=null,updated_at=now() where job_id=v_job_id;
    update public.sis_jobs set status='retry_wait',available_at=now(),updated_at=now() where id=v_job_id;
  else
    update public.sis_agent_job_assignments set assignment_state='failed',lease_token=null,updated_at=now() where job_id=v_job_id;
    update public.sis_jobs set status='failed',finished_at=now(),updated_at=now() where id=v_job_id;
  end if;
  insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
  values(v_job_id,p_attempt_id,'agent.review.completed',p_reviewer_worker_key,case when p_decision='fail' then 'error' else 'info' end,v_corr,jsonb_build_object('decision',p_decision,'review_profile',v_profile,'worker_key',v_worker));
  return jsonb_build_object('ok',true,'job_id',v_job_id,'attempt_id',p_attempt_id,'decision',p_decision,'job_status',case when p_decision='pass' then 'succeeded' when p_decision='changes_required' then 'retry_wait' else 'failed' end);
end;
$$;
revoke all on function public.sis_agent_reviewer_submit_v1(text,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.sis_agent_reviewer_submit_v1(text,uuid,text,jsonb) to service_role;

create or replace function public.sis_agent_supervisor_job_status_v1(p_job_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'job',to_jsonb(j),
    'assignment',to_jsonb(a),
    'attempts',coalesce((select jsonb_agg(to_jsonb(at) order by at.attempt_no) from public.sis_job_attempts at where at.job_id=j.id),'[]'::jsonb),
    'reviews',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.sis_agent_reviews r where r.job_id=j.id),'[]'::jsonb)
  )
  from public.sis_jobs j join public.sis_agent_job_assignments a on a.job_id=j.id where j.id=p_job_id;
$$;
revoke all on function public.sis_agent_supervisor_job_status_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_job_status_v1(uuid) to service_role;

create or replace function public.sis_agent_supervisor_work_item_gate_v1(p_work_item_key text)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  with wi as (select id,item_key,status from public.sis_work_items where item_key=btrim(p_work_item_key)),
  s as (
    select count(*) total_jobs,
      count(*) filter(where j.status='succeeded' and a.assignment_state='accepted') accepted_jobs,
      count(*) filter(where j.status='failed' or a.assignment_state='failed') failed_jobs,
      count(*) filter(where j.status in ('queued','running','retry_wait','blocked') or a.assignment_state in ('queued','blocked','running','review_required','rework')) pending_jobs,
      count(*) filter(where a.approval_required and not public.sis_agent_job_approval_ok_v1(j.id)) approval_blocked_jobs
    from wi join public.sis_jobs j on j.work_item_id=wi.id join public.sis_agent_job_assignments a on a.job_id=j.id
  )
  select jsonb_build_object(
    'work_item_key',wi.item_key,'work_item_status',wi.status,
    'ready',case when s.total_jobs>0 and s.failed_jobs=0 and s.pending_jobs=0 and s.accepted_jobs=s.total_jobs then true else false end,
    'total_jobs',s.total_jobs,'accepted_jobs',s.accepted_jobs,'failed_jobs',s.failed_jobs,'pending_jobs',s.pending_jobs,'approval_blocked_jobs',s.approval_blocked_jobs
  ) from wi cross join s;
$$;
revoke all on function public.sis_agent_supervisor_work_item_gate_v1(text) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_work_item_gate_v1(text) to service_role;

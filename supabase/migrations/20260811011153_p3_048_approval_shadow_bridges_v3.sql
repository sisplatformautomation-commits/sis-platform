-- P3-048 v3: non-enforcing approval shadow bridges for legacy job approvals and ASOG Make PROD approvals.
-- TEST/DEV shadow consolidation only. No legacy gate removal, no approval creation/consumption,
-- no provider execution, no PROD schema change, and no security weakening.

create table if not exists public.sis_authorization_shadow_approval_bridge_evaluations (
  id uuid primary key default gen_random_uuid(),
  policy_version text not null,
  source_type text not null check (source_type in ('job_approval','asog_make_prod_approval')),
  source_id uuid not null,
  environment_key text not null check (environment_key in ('dev','test','uat','prod')),
  legacy_allow boolean not null,
  shadow_decision text not null check (shadow_decision in ('ALLOW','DENY','APPROVAL_REQUIRED')),
  parity boolean not null,
  approval_required boolean not null,
  approval_valid boolean not null,
  required_scopes text[] not null default '{}'::text[],
  reason_codes text[] not null default '{}'::text[],
  source_state jsonb not null default '{}'::jsonb check (jsonb_typeof(source_state)='object'),
  risk_summary jsonb not null default '{}'::jsonb check (jsonb_typeof(risk_summary)='object'),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=32768),
  evaluated_at timestamptz not null default now()
);

create index if not exists sis_authorization_shadow_approval_bridge_source_idx
  on public.sis_authorization_shadow_approval_bridge_evaluations(source_type,source_id,evaluated_at desc);
create index if not exists sis_authorization_shadow_approval_bridge_parity_idx
  on public.sis_authorization_shadow_approval_bridge_evaluations(parity,source_type,evaluated_at desc);

alter table public.sis_authorization_shadow_approval_bridge_evaluations enable row level security;
revoke all on table public.sis_authorization_shadow_approval_bridge_evaluations from public,anon,authenticated,service_role;

create or replace function public.sis_authorization_shadow_job_approval_decide_v1(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_assignment public.sis_agent_job_assignments%rowtype;
  v_job_status text;
  v_scopes text[] := '{}'::text[];
  v_scope text;
  v_scope_decision text;
  v_reasons text[] := '{}'::text[];
  v_shadow_decision text := 'DENY';
  v_legacy_allow boolean := false;
  v_approval_valid boolean := false;
  v_missing boolean := false;
  v_denied boolean := false;
begin
  select * into v_assignment
  from public.sis_agent_job_assignments
  where job_id=p_job_id;

  if not found then
    return jsonb_build_object(
      'policy_version','p3_048_shadow_v3','enforced',false,'source_type','job_approval',
      'source_id',p_job_id,'environment_key',null,'legacy_allow',false,'decision','DENY',
      'parity',true,'approval_required',false,'approval_valid',false,
      'required_scopes','[]'::jsonb,'reason_codes',jsonb_build_array('job_assignment_not_found')
    );
  end if;

  select status into v_job_status from public.sis_jobs where id=p_job_id;
  v_legacy_allow := public.sis_agent_job_approval_ok_v1(p_job_id);
  select coalesce(array_agg(value),'{}'::text[]) into v_scopes
  from jsonb_array_elements_text(coalesce(v_assignment.metadata->'required_approval_scopes','[]'::jsonb));

  if not v_assignment.approval_required then
    v_shadow_decision := 'ALLOW';
    v_reasons := array_append(v_reasons,'approval_not_required');
  elsif cardinality(v_scopes)=0 then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'required_approval_scopes_missing');
  else
    foreach v_scope in array v_scopes loop
      v_scope_decision := null;
      select a.decision into v_scope_decision
      from public.sis_agent_job_approvals a
      where a.job_id=p_job_id
        and a.approval_scope=v_scope
        and (a.expires_at is null or a.expires_at>now())
      order by a.granted_at desc,a.created_at desc
      limit 1;

      if not found then
        v_missing := true;
        v_reasons := array_append(v_reasons,'approval_missing:'||v_scope);
      elsif v_scope_decision='denied' then
        v_denied := true;
        v_reasons := array_append(v_reasons,'approval_denied:'||v_scope);
      else
        v_reasons := array_append(v_reasons,'approval_granted:'||v_scope);
      end if;
    end loop;

    if v_denied then
      v_shadow_decision := 'DENY';
    elsif v_missing then
      v_shadow_decision := 'APPROVAL_REQUIRED';
    else
      v_shadow_decision := 'ALLOW';
      v_approval_valid := true;
    end if;
  end if;

  return jsonb_build_object(
    'policy_version','p3_048_shadow_v3','enforced',false,'source_type','job_approval',
    'source_id',p_job_id,'environment_key',v_assignment.environment_key,
    'legacy_allow',v_legacy_allow,'decision',v_shadow_decision,
    'parity',(v_legacy_allow=(v_shadow_decision='ALLOW')),
    'approval_required',v_assignment.approval_required,'approval_valid',v_approval_valid,
    'required_scopes',to_jsonb(v_scopes),'reason_codes',to_jsonb(v_reasons),
    'source_state',jsonb_build_object(
      'assignment_state',v_assignment.assignment_state,'job_status',v_job_status,
      'assigned_worker_key',v_assignment.assigned_worker_key,
      'required_capabilities',to_jsonb(v_assignment.required_capabilities),
      'required_resource_keys',to_jsonb(v_assignment.required_resource_keys)
    ),
    'risk',jsonb_build_object('approval_backend','sis_agent_job_approvals','legacy_helper','sis_agent_job_approval_ok_v1')
  );
end;
$$;

create or replace function public.sis_authorization_shadow_job_approval_evaluate_v1(
  p_job_id uuid,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_result jsonb;
  v_id uuid;
begin
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then
    raise exception 'SHADOW_METADATA_MUST_BE_OBJECT';
  end if;
  v_result := public.sis_authorization_shadow_job_approval_decide_v1(p_job_id);
  insert into public.sis_authorization_shadow_approval_bridge_evaluations(
    policy_version,source_type,source_id,environment_key,legacy_allow,shadow_decision,parity,
    approval_required,approval_valid,required_scopes,reason_codes,source_state,risk_summary,metadata
  ) values (
    v_result->>'policy_version','job_approval',p_job_id,coalesce(v_result->>'environment_key','test'),
    coalesce((v_result->>'legacy_allow')::boolean,false),v_result->>'decision',coalesce((v_result->>'parity')::boolean,false),
    coalesce((v_result->>'approval_required')::boolean,false),coalesce((v_result->>'approval_valid')::boolean,false),
    coalesce(array(select jsonb_array_elements_text(coalesce(v_result->'required_scopes','[]'::jsonb))),'{}'::text[]),
    coalesce(array(select jsonb_array_elements_text(coalesce(v_result->'reason_codes','[]'::jsonb))),'{}'::text[]),
    coalesce(v_result->'source_state','{}'::jsonb),coalesce(v_result->'risk','{}'::jsonb),p_metadata
  ) returning id into v_id;
  return v_result || jsonb_build_object('evaluation_id',v_id,'shadow_logged',true);
end;
$$;

create or replace function public.sis_authorization_shadow_asog_approval_decide_v1(
  p_approval_id uuid,
  p_actual_state_hash text default null
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_row public.asog_make_approval_requests%rowtype;
  v_reasons text[] := '{}'::text[];
  v_shadow_decision text := 'DENY';
  v_legacy_allow boolean := false;
  v_approval_valid boolean := false;
  v_required boolean := true;
  v_state_hash_match boolean := true;
  v_scopes text[] := array['execute','prod_promotion','provider_write']::text[];
begin
  select * into v_row from public.asog_make_approval_requests where id=p_approval_id;
  if not found then
    return jsonb_build_object(
      'policy_version','p3_048_shadow_v3','enforced',false,'source_type','asog_make_prod_approval',
      'source_id',p_approval_id,'environment_key','prod','legacy_allow',false,'decision','DENY','parity',true,
      'approval_required',false,'approval_valid',false,'required_scopes',to_jsonb(v_scopes),
      'reason_codes',jsonb_build_array('asog_approval_not_found')
    );
  end if;

  if v_row.expected_state_hash is not null then
    v_state_hash_match := p_actual_state_hash is not distinct from v_row.expected_state_hash;
  end if;

  v_legacy_allow := v_row.environment_key='prod'
    and v_row.status='approved'
    and v_row.expires_at is not null and v_row.expires_at>now()
    and v_state_hash_match;

  if v_row.environment_key<>'prod' then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_prod_environment_required');
  elsif v_row.status='pending' then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'asog_approval_pending');
  elsif v_row.status='expired' or (v_row.status='approved' and (v_row.expires_at is null or v_row.expires_at<=now())) then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'asog_approval_expired');
  elsif v_row.status='approved' and not v_state_hash_match then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_state_hash_mismatch');
  elsif v_row.status='approved' then
    v_shadow_decision := 'ALLOW';
    v_approval_valid := true;
    v_reasons := array_append(v_reasons,'asog_approval_valid');
  elsif v_row.status='rejected' then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_approval_rejected');
  elsif v_row.status='consumed' then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_approval_already_consumed');
  elsif v_row.status='cancelled' then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_approval_cancelled');
  else
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'asog_approval_state_invalid');
  end if;

  return jsonb_build_object(
    'policy_version','p3_048_shadow_v3','enforced',false,'source_type','asog_make_prod_approval',
    'source_id',v_row.id,'environment_key',v_row.environment_key,'legacy_allow',v_legacy_allow,
    'decision',v_shadow_decision,'parity',(v_legacy_allow=(v_shadow_decision='ALLOW')),
    'approval_required',v_required,'approval_valid',v_approval_valid,'required_scopes',to_jsonb(v_scopes),
    'reason_codes',to_jsonb(v_reasons),
    'source_state',jsonb_build_object(
      'resource_type',v_row.resource_type,'resource_id',v_row.resource_id,'operation',v_row.operation,
      'status',v_row.status,'expected_state_hash_present',v_row.expected_state_hash is not null,
      'state_hash_match',v_state_hash_match,'expires_at',v_row.expires_at,'consumed_at',v_row.consumed_at
    ),
    'risk',jsonb_build_object(
      'approval_backend','asog_make_approval_requests','provider_write',true,
      'prod_promotion',true,'external_financial_write',false,'destructive',false
    )
  );
end;
$$;

create or replace function public.sis_authorization_shadow_asog_approval_evaluate_v1(
  p_approval_id uuid,
  p_actual_state_hash text default null,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_result jsonb;
  v_id uuid;
begin
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then
    raise exception 'SHADOW_METADATA_MUST_BE_OBJECT';
  end if;
  v_result := public.sis_authorization_shadow_asog_approval_decide_v1(p_approval_id,p_actual_state_hash);
  insert into public.sis_authorization_shadow_approval_bridge_evaluations(
    policy_version,source_type,source_id,environment_key,legacy_allow,shadow_decision,parity,
    approval_required,approval_valid,required_scopes,reason_codes,source_state,risk_summary,metadata
  ) values (
    v_result->>'policy_version','asog_make_prod_approval',p_approval_id,coalesce(v_result->>'environment_key','prod'),
    coalesce((v_result->>'legacy_allow')::boolean,false),v_result->>'decision',coalesce((v_result->>'parity')::boolean,false),
    coalesce((v_result->>'approval_required')::boolean,false),coalesce((v_result->>'approval_valid')::boolean,false),
    coalesce(array(select jsonb_array_elements_text(coalesce(v_result->'required_scopes','[]'::jsonb))),'{}'::text[]),
    coalesce(array(select jsonb_array_elements_text(coalesce(v_result->'reason_codes','[]'::jsonb))),'{}'::text[]),
    coalesce(v_result->'source_state','{}'::jsonb),coalesce(v_result->'risk','{}'::jsonb),p_metadata
  ) returning id into v_id;
  return v_result || jsonb_build_object('evaluation_id',v_id,'shadow_logged',true);
end;
$$;

revoke all on function public.sis_authorization_shadow_job_approval_decide_v1(uuid) from public,anon,authenticated;
revoke all on function public.sis_authorization_shadow_job_approval_evaluate_v1(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.sis_authorization_shadow_asog_approval_decide_v1(uuid,text) from public,anon,authenticated;
revoke all on function public.sis_authorization_shadow_asog_approval_evaluate_v1(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.sis_authorization_shadow_job_approval_decide_v1(uuid) to service_role;
grant execute on function public.sis_authorization_shadow_job_approval_evaluate_v1(uuid,jsonb) to service_role;
grant execute on function public.sis_authorization_shadow_asog_approval_decide_v1(uuid,text) to service_role;
grant execute on function public.sis_authorization_shadow_asog_approval_evaluate_v1(uuid,text,jsonb) to service_role;

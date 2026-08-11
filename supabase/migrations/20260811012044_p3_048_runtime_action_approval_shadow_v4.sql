-- P3-048 v4: normalize runtime-action approval semantics into the non-enforcing shadow contract.
-- DEV/TEST observation only. No approval creation/consumption, provider call, PROD cutover,
-- legacy gate removal, or security weakening.

do $$
begin
  if to_regclass('public.sis_authorization_shadow_approval_bridge_evaluations') is null then
    raise exception 'P3_048_V3_BASELINE_REQUIRED';
  end if;
  if to_regprocedure('public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)') is null then
    raise exception 'RUNTIME_WRITE_APPROVAL_BASELINE_REQUIRED';
  end if;
end;
$$;

alter table public.sis_authorization_shadow_approval_bridge_evaluations
  drop constraint if exists sis_authorization_shadow_approval_bridge_eval_source_type_check;

alter table public.sis_authorization_shadow_approval_bridge_evaluations
  add constraint sis_authorization_shadow_approval_bridge_eval_source_type_check
  check (source_type in ('job_approval','asog_make_prod_approval','runtime_action_approval'));

create or replace function public.sis_authorization_shadow_runtime_action_decide_v1(
  p_session_id uuid,
  p_write_approval_id uuid,
  p_action_fingerprint text
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_session public.sis_runtime_access_sessions%rowtype;
  v_approval public.sis_runtime_write_approvals%rowtype;
  v_fingerprint text := nullif(btrim(coalesce(p_action_fingerprint,'')),'');
  v_reasons text[] := '{}'::text[];
  v_shadow_decision text := 'APPROVAL_REQUIRED';
  v_legacy_allow boolean := false;
  v_approval_valid boolean := false;
  v_session_valid boolean := false;
  v_approval_present boolean := false;
  v_fingerprint_match boolean := false;
begin
  if p_session_id is not null then
    select * into v_session
    from public.sis_runtime_access_sessions s
    where s.id=p_session_id;
  end if;

  if p_write_approval_id is not null then
    select * into v_approval
    from public.sis_runtime_write_approvals a
    where a.id=p_write_approval_id;
    v_approval_present := found;
  end if;

  v_session_valid := v_session.id is not null
    and v_session.status='active'
    and v_session.expires_at>now();

  v_fingerprint_match := v_approval.id is not null
    and v_fingerprint is not null
    and v_approval.action_fingerprint=v_fingerprint;

  v_legacy_allow := v_session_valid
    and v_approval.id is not null
    and v_approval.session_id=v_session.id
    and v_approval.status='approved'
    and v_approval.expires_at>now()
    and v_fingerprint_match;

  if v_fingerprint is null then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'action_fingerprint_required');
  elsif p_session_id is null then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'runtime_session_required');
  elsif v_session.id is null then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'runtime_session_not_found');
  elsif v_session.status<>'active' then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'runtime_session_not_active');
  elsif v_session.expires_at<=now() then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'runtime_session_expired');
  elsif p_write_approval_id is null then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'write_approval_required');
  elsif v_approval.id is null then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'write_approval_not_found');
  elsif v_approval.session_id<>v_session.id then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'write_approval_session_mismatch');
  elsif v_approval.status<>'approved' then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'write_approval_not_active:'||v_approval.status);
  elsif v_approval.expires_at<=now() then
    v_shadow_decision := 'APPROVAL_REQUIRED';
    v_reasons := array_append(v_reasons,'write_approval_expired');
  elsif not v_fingerprint_match then
    v_shadow_decision := 'DENY';
    v_reasons := array_append(v_reasons,'write_approval_fingerprint_mismatch');
  else
    v_shadow_decision := 'ALLOW';
    v_approval_valid := true;
    v_reasons := array_append(v_reasons,'matching_runtime_write_approval');
  end if;

  return jsonb_build_object(
    'policy_version','p3_048_shadow_v4',
    'enforced',false,
    'source_type','runtime_action_approval',
    'source_id',coalesce(p_write_approval_id,p_session_id),
    'environment_key',v_session.environment,
    'legacy_allow',v_legacy_allow,
    'decision',v_shadow_decision,
    'parity',(v_legacy_allow=(v_shadow_decision='ALLOW')),
    'approval_required',true,
    'approval_valid',v_approval_valid,
    'required_scopes',jsonb_build_array('runtime_write'),
    'reason_codes',to_jsonb(v_reasons),
    'source_state',jsonb_build_object(
      'session_status',v_session.status,
      'session_valid',v_session_valid,
      'session_expires_at',v_session.expires_at,
      'approval_present',v_approval_present,
      'approval_status',v_approval.status,
      'approval_expires_at',v_approval.expires_at,
      'action_key',v_approval.action_key,
      'fingerprint_match',v_fingerprint_match
    ),
    'risk',jsonb_build_object(
      'approval_backend','sis_runtime_write_approvals',
      'legacy_helper','sis_consume_runtime_write_approval_v1',
      'runtime_write',true,
      'approval_consumed',false
    )
  );
end;
$$;

create or replace function public.sis_authorization_shadow_runtime_action_evaluate_v1(
  p_session_id uuid,
  p_write_approval_id uuid,
  p_action_fingerprint text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_result jsonb;
  v_id uuid;
  v_source_id uuid;
  v_environment text;
begin
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then
    raise exception 'SHADOW_METADATA_MUST_BE_OBJECT';
  end if;

  v_result := public.sis_authorization_shadow_runtime_action_decide_v1(
    p_session_id,p_write_approval_id,p_action_fingerprint
  );
  v_source_id := coalesce(p_write_approval_id,p_session_id);
  v_environment := nullif(v_result->>'environment_key','');

  if v_source_id is null then
    raise exception 'RUNTIME_APPROVAL_SOURCE_ID_REQUIRED';
  end if;
  if v_environment not in ('dev','test') then
    raise exception 'RUNTIME_APPROVAL_SHADOW_DEV_TEST_ONLY';
  end if;

  insert into public.sis_authorization_shadow_approval_bridge_evaluations(
    policy_version,source_type,source_id,environment_key,legacy_allow,shadow_decision,parity,
    approval_required,approval_valid,required_scopes,reason_codes,source_state,risk_summary,metadata
  ) values (
    v_result->>'policy_version','runtime_action_approval',v_source_id,v_environment,
    coalesce((v_result->>'legacy_allow')::boolean,false),v_result->>'decision',coalesce((v_result->>'parity')::boolean,false),
    true,coalesce((v_result->>'approval_valid')::boolean,false),
    array['runtime_write']::text[],
    coalesce(array(select jsonb_array_elements_text(coalesce(v_result->'reason_codes','[]'::jsonb))),'{}'::text[]),
    coalesce(v_result->'source_state','{}'::jsonb),coalesce(v_result->'risk','{}'::jsonb),
    p_metadata || jsonb_build_object('p3','P3-048','shadow_version','v4','non_enforcing',true)
  ) returning id into v_id;

  return v_result || jsonb_build_object('evaluation_id',v_id,'shadow_logged',true);
end;
$$;

revoke all on function public.sis_authorization_shadow_runtime_action_decide_v1(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.sis_authorization_shadow_runtime_action_evaluate_v1(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.sis_authorization_shadow_runtime_action_decide_v1(uuid,uuid,text) to service_role;
grant execute on function public.sis_authorization_shadow_runtime_action_evaluate_v1(uuid,uuid,text,jsonb) to service_role;

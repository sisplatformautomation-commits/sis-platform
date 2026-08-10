-- SIS Runtime Foundation v1.1
-- Makes runtime write approvals single-use. This migration is repository-only until
-- explicitly approved for application to a non-production Supabase environment.

create or replace function public.sis_consume_runtime_write_approval_v1(
  p_session_id uuid,
  p_write_approval_id uuid,
  p_action_fingerprint text,
  p_consumed_by text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $$
declare
  v_session public.sis_runtime_access_sessions%rowtype;
  v_approval public.sis_runtime_write_approvals%rowtype;
begin
  if p_session_id is null then
    return jsonb_build_object('consumed',false,'reason','runtime_session_required');
  end if;
  if p_write_approval_id is null then
    return jsonb_build_object('consumed',false,'reason','write_approval_required');
  end if;
  if coalesce(btrim(p_action_fingerprint),'')='' then
    return jsonb_build_object('consumed',false,'reason','action_fingerprint_required');
  end if;
  if coalesce(btrim(p_consumed_by),'')='' then
    return jsonb_build_object('consumed',false,'reason','consumed_by_required');
  end if;

  select * into v_session
  from public.sis_runtime_access_sessions s
  where s.id=p_session_id
  for update;

  if v_session.id is null then
    return jsonb_build_object('consumed',false,'reason','runtime_session_not_found');
  end if;
  if v_session.status <> 'active' then
    return jsonb_build_object('consumed',false,'reason','runtime_session_not_active');
  end if;
  if v_session.expires_at <= now() then
    return jsonb_build_object('consumed',false,'reason','runtime_session_expired');
  end if;

  update public.sis_runtime_write_approvals a
  set status='consumed', consumed_at=now()
  where a.id=p_write_approval_id
    and a.session_id=v_session.id
    and a.status='approved'
    and a.expires_at>now()
    and a.action_fingerprint=btrim(p_action_fingerprint)
  returning * into v_approval;

  if v_approval.id is null then
    return jsonb_build_object('consumed',false,'reason','valid_matching_write_approval_required');
  end if;

  insert into public.sis_events(
    event_type,source,payload,scope,aggregate,correlation_id,severity,
    schema_version,occurred_at,recorded_at,created_at
  ) values (
    'runtime.write_approval_consumed','sis-runtime-gateway',
    jsonb_build_object(
      'runtime_session_id',v_session.id,
      'write_approval_id',v_approval.id,
      'customer_id',v_session.customer_id,
      'environment',v_session.environment,
      'action_key',v_approval.action_key,
      'target_ref',v_approval.target_ref,
      'action_fingerprint',v_approval.action_fingerprint,
      'consumed_by',btrim(p_consumed_by),
      'consumed_at',v_approval.consumed_at
    ),
    'runtime_session','runtime_session:'||v_session.id::text,v_session.correlation_id,
    'notice',1,now(),now(),now()
  );

  return jsonb_build_object(
    'consumed',true,
    'reason','write_approval_consumed',
    'runtime_session_id',v_session.id,
    'write_approval_id',v_approval.id,
    'customer_id',v_session.customer_id,
    'environment',v_session.environment,
    'action_key',v_approval.action_key,
    'target_ref',v_approval.target_ref,
    'action_fingerprint',v_approval.action_fingerprint,
    'consumed_at',v_approval.consumed_at
  );
end;
$$;

revoke all on function public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)
  to service_role;

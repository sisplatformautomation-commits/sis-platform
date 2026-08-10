-- Security contract for SIS Runtime Foundation v1.3
-- Run only on a disposable DEV/TEST database after all runtime migrations.
-- Synthetic rows are created inside one transaction and rolled back.

begin;

do $$
declare
  v_customer_id uuid := gen_random_uuid();
  v_runtime_id uuid := gen_random_uuid();
begin
  insert into public.sis_customers(id,customer_key,display_name,status)
  values (
    v_customer_id,
    'runtime_gateway_contract_'||replace(v_customer_id::text,'-',''),
    'Runtime Gateway Contract',
    'active'
  );

  insert into public.sis_runtime_environments(
    id,runtime_key,customer_id,environment,status,ownership_model,
    make_isolation_mode,database_isolation_mode
  ) values (
    v_runtime_id,
    'runtime_gateway_'||replace(v_runtime_id::text,'-',''),
    v_customer_id,'dev','active','customer_owned',
    'organization_dedicated','project_dedicated'
  );

  perform set_config('sis.runtime_contract_runtime_id',v_runtime_id::text,true);
end;
$$;

do $$
begin
  if not has_table_privilege('service_role','public.sis_runtime_environments','SELECT')
     or not has_table_privilege('service_role','public.sis_runtime_access_sessions','SELECT')
     or not has_table_privilege('service_role','public.sis_runtime_write_approvals','SELECT') then
    raise exception 'service_role must retain runtime SELECT access';
  end if;

  if has_table_privilege('service_role','public.sis_runtime_environments','INSERT,UPDATE,DELETE,TRUNCATE')
     or has_table_privilege('service_role','public.sis_runtime_access_sessions','INSERT,UPDATE,DELETE,TRUNCATE')
     or has_table_privilege('service_role','public.sis_runtime_write_approvals','INSERT,UPDATE,DELETE,TRUNCATE') then
    raise exception 'service_role direct runtime mutation privilege detected';
  end if;

  if not has_function_privilege(
       'service_role',
       'public.sis_open_runtime_session_v1(uuid,text,text,text,text,timestamptz,integer)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'service_role',
       'public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)',
       'EXECUTE'
     ) then
    raise exception 'service_role runtime RPC execute privilege missing';
  end if;

  if has_function_privilege(
       'anon',
       'public.sis_open_runtime_session_v1(uuid,text,text,text,text,timestamptz,integer)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.sis_open_runtime_session_v1(uuid,text,text,text,text,timestamptz,integer)',
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.sis_consume_runtime_write_approval_v1(uuid,uuid,text,text)',
       'EXECUTE'
     ) then
    raise exception 'anon/authenticated runtime RPC execute privilege detected';
  end if;
end;
$$;

set local role service_role;

do $$
declare
  v_runtime_id uuid := current_setting('sis.runtime_contract_runtime_id')::uuid;
  v_session public.sis_runtime_access_sessions%rowtype;
  v_approval public.sis_runtime_write_approvals%rowtype;
  v_result jsonb;
  v_direct_write_blocked boolean := false;
  v_stale_auth_blocked boolean := false;
begin
  begin
    update public.sis_runtime_environments
    set status='suspended'
    where id=v_runtime_id;
  exception when insufficient_privilege then
    v_direct_write_blocked := true;
  end;

  if not v_direct_write_blocked then
    raise exception 'service_role direct UPDATE unexpectedly succeeded';
  end if;

  begin
    perform public.sis_open_runtime_session_v1(
      v_runtime_id,'sis_operator','contract-test','stale-auth','test',
      now()-interval '6 minutes',30
    );
  exception when others then
    if sqlerrm='fresh_step_up_auth_required' then
      v_stale_auth_blocked := true;
    else
      raise;
    end if;
  end;

  if not v_stale_auth_blocked then
    raise exception 'stale step-up authentication unexpectedly accepted';
  end if;

  select * into v_session
  from public.sis_open_runtime_session_v1(
    v_runtime_id,'sis_operator','contract-test','fresh-auth','test',now(),30
  );

  v_result := public.sis_check_runtime_action_v1(v_session.id,'read',null,null);
  if coalesce((v_result->>'allowed')::boolean,false) is not true then
    raise exception 'active runtime session did not allow READ: %',v_result;
  end if;

  select * into v_approval
  from public.sis_approve_runtime_write_v1(
    v_session.id,'contract.write','dev:test-resource','sha256:gateway-fingerprint',
    'Gateway security contract only','contract-test','fresh-write-auth','test',now(),
    'gateway-contract-'||v_session.id::text,5
  );

  v_result := public.sis_check_runtime_action_v1(
    v_session.id,'write','sha256:wrong-fingerprint',v_approval.id
  );
  if coalesce((v_result->>'allowed')::boolean,false) is true
     or v_result->>'reason' <> 'valid_matching_write_approval_required' then
    raise exception 'wrong fingerprint unexpectedly passed preflight: %',v_result;
  end if;

  v_result := public.sis_consume_runtime_write_approval_v1(
    v_session.id,v_approval.id,'sha256:wrong-fingerprint','contract-test'
  );
  if coalesce((v_result->>'consumed')::boolean,false) is true then
    raise exception 'wrong fingerprint unexpectedly consumed approval: %',v_result;
  end if;

  v_result := public.sis_consume_runtime_write_approval_v1(
    v_session.id,v_approval.id,'sha256:gateway-fingerprint','contract-test'
  );
  if coalesce((v_result->>'consumed')::boolean,false) is not true then
    raise exception 'matching write approval was not consumed: %',v_result;
  end if;

  v_result := public.sis_consume_runtime_write_approval_v1(
    v_session.id,v_approval.id,'sha256:gateway-fingerprint','contract-test'
  );
  if coalesce((v_result->>'consumed')::boolean,false) is true
     or v_result->>'reason' <> 'valid_matching_write_approval_required' then
    raise exception 'consumed approval replay unexpectedly succeeded: %',v_result;
  end if;

  if not exists (
    select 1
    from public.sis_runtime_write_approvals
    where id=v_approval.id and status='consumed' and consumed_at is not null
  ) then
    raise exception 'consumed approval state missing';
  end if;
end;
$$;

reset role;
rollback;

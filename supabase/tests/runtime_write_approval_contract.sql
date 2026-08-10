-- Contract test for SIS Runtime Foundation v1.1
-- Run only against a disposable DEV/TEST database after applying the runtime migrations.
-- The test uses a transaction and rolls back all rows it creates.

begin;

do $$
declare
  v_customer_id uuid := gen_random_uuid();
  v_runtime_id uuid := gen_random_uuid();
  v_session_id uuid := gen_random_uuid();
  v_approval_id uuid := gen_random_uuid();
  v_result jsonb;
begin
  insert into public.sis_customers(id,customer_key,display_name,status)
  values (v_customer_id,'runtime_contract_test_'||replace(v_customer_id::text,'-',''),'Runtime Contract Test','active');

  insert into public.sis_runtime_environments(
    id,runtime_key,customer_id,environment,status,ownership_model,
    make_isolation_mode,database_isolation_mode
  ) values (
    v_runtime_id,'runtime_contract_'||replace(v_runtime_id::text,'-',''),v_customer_id,'dev','active','customer_owned',
    'organization_dedicated','project_dedicated'
  );

  insert into public.sis_runtime_access_sessions(
    id,runtime_environment_id,customer_id,environment,actor_type,actor_ref,
    auth_assertion_ref,auth_method,auth_verified_at,access_mode,status,opened_at,expires_at
  ) values (
    v_session_id,v_runtime_id,v_customer_id,'dev','sis_operator','contract-test',
    'test-auth-assertion','test',now(),'read_check','active',now(),now()+interval '30 minutes'
  );

  insert into public.sis_runtime_write_approvals(
    id,session_id,action_key,target_ref,action_fingerprint,change_summary,
    approved_by,auth_assertion_ref,auth_method,auth_verified_at,status,approved_at,expires_at,idempotency_key
  ) values (
    v_approval_id,v_session_id,'contract.write','dev:test-resource','sha256:test-fingerprint','Contract test only',
    'contract-test','test-write-auth','test',now(),'approved',now(),now()+interval '5 minutes','contract-'||v_approval_id::text
  );

  v_result := public.sis_consume_runtime_write_approval_v1(
    v_session_id,v_approval_id,'sha256:test-fingerprint','contract-test'
  );
  if coalesce((v_result->>'consumed')::boolean,false) is not true then
    raise exception 'expected first consume to succeed: %', v_result;
  end if;

  v_result := public.sis_consume_runtime_write_approval_v1(
    v_session_id,v_approval_id,'sha256:test-fingerprint','contract-test'
  );
  if coalesce((v_result->>'consumed')::boolean,false) is true
     or v_result->>'reason' <> 'valid_matching_write_approval_required' then
    raise exception 'expected second consume to fail as single-use: %', v_result;
  end if;

  if not exists (
    select 1 from public.sis_runtime_write_approvals
    where id=v_approval_id and status='consumed' and consumed_at is not null
  ) then
    raise exception 'approval was not persisted as consumed';
  end if;

  if not exists (
    select 1 from public.sis_events
    where event_type='runtime.write_approval_consumed'
      and payload->>'write_approval_id'=v_approval_id::text
  ) then
    raise exception 'consume audit event missing';
  end if;
end;
$$;

rollback;

-- P3-052: canonicalize the Execution Controller worker identity.
-- DEV/TEST only. No PROD capability grant, provider write, approval creation, or domain execution is added.

insert into public.sis_agent_workers(
  worker_key,worker_role,domain_key,status,max_concurrency,runtime_binding,metadata
) values (
  'sis.controller.orchestration','supervisor','orchestration','active',1,
  jsonb_build_object('binding','logical','provider_actions',false),
  jsonb_build_object(
    'p3','P3-052',
    'canonical_name','SIS Execution Controller',
    'supersedes_worker_key','sis.control_supervisor',
    'self_execution',false,
    'worker_selection',false,
    'approval_creation',false,
    'purpose','validate execution intent and activate sis.supervisor'
  )
)
on conflict (worker_key) do update
set worker_role=excluded.worker_role,
    domain_key=excluded.domain_key,
    status='active',
    max_concurrency=excluded.max_concurrency,
    runtime_binding=excluded.runtime_binding,
    metadata=excluded.metadata,
    updated_at=now();

insert into public.sis_agent_worker_capabilities(
  worker_key,capability_key,environment_key,active,metadata
)
select 'sis.controller.orchestration',c.capability_key,e.environment_key,true,
       jsonb_build_object('p3','P3-052','scope','dev_test_only','canonical_controller',true)
from (values ('orchestration.start'),('orchestration.observe'),('orchestration.stop')) c(capability_key)
cross join (values ('dev'),('test')) e(environment_key)
on conflict (worker_key,capability_key,environment_key) do update
set active=true,metadata=excluded.metadata,updated_at=now();

update public.sis_supervisor_activations
set controller_worker_key='sis.controller.orchestration',updated_at=now()
where controller_worker_key='sis.control_supervisor';

alter table public.sis_supervisor_activations
  alter column controller_worker_key set default 'sis.controller.orchestration';

create or replace function public.sis_execution_controller_start_v1(
  p_work_item_key text,
  p_environment_key text,
  p_execution_intent text,
  p_requested_by text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_work_item public.sis_work_items%rowtype;
  v_activation public.sis_supervisor_activations%rowtype;
  v_env text:=lower(btrim(coalesce(p_environment_key,'')));
  v_intent text:=lower(btrim(coalesce(p_execution_intent,'')));
begin
  if v_env not in ('dev','test') then raise exception 'EXECUTION_CONTROLLER_DEV_TEST_ONLY'; end if;
  if v_intent not in ('start','execute','implement') then raise exception 'EXPLICIT_EXECUTION_INTENT_REQUIRED'; end if;
  if p_requested_by is null or length(btrim(p_requested_by)) not between 1 and 160 then raise exception 'REQUESTED_BY_INVALID'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then raise exception 'INVALID_ACTIVATION_METADATA'; end if;

  if not exists(
    select 1 from public.sis_agent_worker_capabilities wc
    where wc.worker_key='sis.controller.orchestration' and wc.capability_key='orchestration.start'
      and wc.environment_key=v_env and wc.active
  ) then raise exception 'ORCHESTRATION_CONTROLLER_NOT_AUTHORIZED'; end if;

  if not exists(
    select 1 from public.sis_agent_workers w
    where w.worker_key='sis.supervisor' and w.worker_role='supervisor' and w.status='active'
      and exists(select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='orchestration.plan' and wc.environment_key=v_env and wc.active)
      and exists(select 1 from public.sis_agent_worker_capabilities wc where wc.worker_key=w.worker_key and wc.capability_key='orchestration.delegate' and wc.environment_key=v_env and wc.active)
  ) then raise exception 'SUPERVISOR_NOT_AUTHORIZED'; end if;

  select * into v_work_item
  from public.sis_work_items
  where item_key=btrim(p_work_item_key)
  for update;

  if not found then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
  if v_work_item.status in ('done','cancelled') then raise exception 'WORK_ITEM_NOT_EXECUTABLE'; end if;

  select * into v_activation
  from public.sis_supervisor_activations
  where work_item_id=v_work_item.id and environment_key=v_env and status in ('requested','claimed')
  order by requested_at desc limit 1;

  if found then
    return jsonb_build_object(
      'ok',true,'idempotent',true,'activation_id',v_activation.id,
      'status',v_activation.status,'work_item_key',v_activation.work_item_key,
      'environment_key',v_activation.environment_key,
      'controller_worker_key',v_activation.controller_worker_key,
      'supervisor_worker_key',v_activation.supervisor_worker_key,
      'approval_granted',false,'worker_execution_started',false
    );
  end if;

  insert into public.sis_supervisor_activations(
    work_item_id,work_item_key,environment_key,execution_intent,requested_by,metadata
  ) values (
    v_work_item.id,v_work_item.item_key,v_env,v_intent,btrim(p_requested_by),
    p_metadata || jsonb_build_object(
      'controller_version','p3-052-v2',
      'controller_worker_key','sis.controller.orchestration',
      'work_item_requires_approval',coalesce(v_work_item.requires_approval,false)
    )
  ) returning * into v_activation;

  return jsonb_build_object(
    'ok',true,'idempotent',false,'activation_id',v_activation.id,
    'status',v_activation.status,'work_item_key',v_activation.work_item_key,
    'environment_key',v_activation.environment_key,
    'controller_worker_key',v_activation.controller_worker_key,
    'supervisor_worker_key',v_activation.supervisor_worker_key,
    'approval_granted',false,'worker_execution_started',false
  );
end;
$$;

revoke all on function public.sis_execution_controller_start_v1(text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sis_execution_controller_start_v1(text,text,text,text,jsonb) to service_role;

delete from public.sis_agent_workers
where worker_key='sis.control_supervisor';

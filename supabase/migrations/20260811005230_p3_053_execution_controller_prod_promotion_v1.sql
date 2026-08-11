-- P3-053: controlled PROD promotion for the SIS Execution Controller.
-- Scope is intentionally narrow: enable only orchestration.start/observe/stop for
-- sis.controller.orchestration in PROD. No provider/domain execution capability,
-- approval creation, external financial write, or security weakening is added.

do $$
begin
  if to_regclass('public.sis_supervisor_activations') is null then
    raise exception 'P3_052_BASELINE_REQUIRED';
  end if;
  if not exists (
    select 1 from public.sis_agent_workers
    where worker_key='sis.controller.orchestration'
      and worker_role='supervisor'
      and domain_key='orchestration'
      and status='active'
  ) then
    raise exception 'P3_052_CANONICAL_CONTROLLER_REQUIRED';
  end if;
end;
$$;

alter table public.sis_supervisor_activations
  drop constraint if exists sis_supervisor_activations_environment_key_check;

alter table public.sis_supervisor_activations
  add constraint sis_supervisor_activations_environment_key_check
  check (environment_key in ('dev','test','prod'));

insert into public.sis_agent_worker_capabilities(
  worker_key,capability_key,environment_key,active,metadata
)
select 'sis.controller.orchestration',c.capability_key,'prod',true,
       jsonb_build_object(
         'p3','P3-053',
         'scope','controlled_prod_promotion',
         'promotion_source','user_explicit',
         'preserves_job_approval_gates',true
       )
from (values
  ('orchestration.start'),
  ('orchestration.observe'),
  ('orchestration.stop')
) c(capability_key)
on conflict (worker_key,capability_key,environment_key) do update
set active=true,
    metadata=excluded.metadata,
    updated_at=now();

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
  if v_env not in ('dev','test','prod') then raise exception 'EXECUTION_CONTROLLER_ENVIRONMENT_NOT_ALLOWED'; end if;
  if v_intent not in ('start','execute','implement') then raise exception 'EXPLICIT_EXECUTION_INTENT_REQUIRED'; end if;
  if p_requested_by is null or length(btrim(p_requested_by)) not between 1 and 160 then raise exception 'REQUESTED_BY_INVALID'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then raise exception 'INVALID_ACTIVATION_METADATA'; end if;

  if not exists(
    select 1 from public.sis_agent_worker_capabilities wc
    where wc.worker_key='sis.controller.orchestration'
      and wc.capability_key='orchestration.start'
      and wc.environment_key=v_env
      and wc.active
  ) then raise exception 'ORCHESTRATION_CONTROLLER_NOT_AUTHORIZED'; end if;

  if not exists(
    select 1 from public.sis_agent_workers w
    where w.worker_key='sis.supervisor'
      and w.worker_role='supervisor'
      and w.status='active'
      and exists(
        select 1 from public.sis_agent_worker_capabilities wc
        where wc.worker_key=w.worker_key
          and wc.capability_key='orchestration.plan'
          and wc.environment_key=v_env
          and wc.active
      )
      and exists(
        select 1 from public.sis_agent_worker_capabilities wc
        where wc.worker_key=w.worker_key
          and wc.capability_key='orchestration.delegate'
          and wc.environment_key=v_env
          and wc.active
      )
  ) then raise exception 'SUPERVISOR_NOT_AUTHORIZED'; end if;

  select * into v_work_item
  from public.sis_work_items
  where item_key=btrim(p_work_item_key)
  for update;

  if not found then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
  if v_work_item.status in ('done','cancelled') then raise exception 'WORK_ITEM_NOT_EXECUTABLE'; end if;

  select * into v_activation
  from public.sis_supervisor_activations
  where work_item_id=v_work_item.id
    and environment_key=v_env
    and status in ('requested','claimed')
  order by requested_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok',true,
      'idempotent',true,
      'activation_id',v_activation.id,
      'status',v_activation.status,
      'work_item_key',v_activation.work_item_key,
      'environment_key',v_activation.environment_key,
      'controller_worker_key',v_activation.controller_worker_key,
      'supervisor_worker_key',v_activation.supervisor_worker_key,
      'approval_granted',false,
      'worker_execution_started',false
    );
  end if;

  insert into public.sis_supervisor_activations(
    work_item_id,work_item_key,environment_key,execution_intent,requested_by,metadata
  ) values (
    v_work_item.id,
    v_work_item.item_key,
    v_env,
    v_intent,
    btrim(p_requested_by),
    p_metadata || jsonb_build_object(
      'controller_version','p3-053-prod-v1',
      'controller_worker_key','sis.controller.orchestration',
      'work_item_requires_approval',coalesce(v_work_item.requires_approval,false),
      'prod_environment',v_env='prod'
    )
  ) returning * into v_activation;

  return jsonb_build_object(
    'ok',true,
    'idempotent',false,
    'activation_id',v_activation.id,
    'status',v_activation.status,
    'work_item_key',v_activation.work_item_key,
    'environment_key',v_activation.environment_key,
    'controller_worker_key',v_activation.controller_worker_key,
    'supervisor_worker_key',v_activation.supervisor_worker_key,
    'approval_granted',false,
    'worker_execution_started',false
  );
end;
$$;

revoke all on function public.sis_execution_controller_start_v1(text,text,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.sis_execution_controller_start_v1(text,text,text,text,jsonb)
  to service_role;

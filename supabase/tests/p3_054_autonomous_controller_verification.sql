-- P3-054 read-only verification queries.
-- Cron activation itself is environment-specific operational configuration and is intentionally not in the migration.

select
  to_regclass('public.sis_controller_runtime_state') is not null as runtime_state_present,
  to_regclass('public.sis_controller_dispatches') is not null as dispatches_present,
  to_regprocedure('public.sis_controller_consumer_tick_v1(text,timestamptz,integer,integer)') is not null as tick_rpc_present,
  to_regprocedure('public.sis_supervisor_dispatch_claim_v1(integer)') is not null as supervisor_claim_present,
  to_regprocedure('public.sis_supervisor_dispatch_heartbeat_v1(uuid,uuid,integer)') is not null as supervisor_heartbeat_present,
  to_regprocedure('public.sis_supervisor_dispatch_submit_plan_v1(uuid,uuid,jsonb)') is not null as supervisor_submit_plan_present,
  to_regprocedure('public.sis_controller_consumer_stop_v1(uuid,text)') is not null as controller_stop_present;

select
  has_table_privilege('anon','public.sis_controller_dispatches','SELECT') as anon_dispatch_select,
  has_table_privilege('authenticated','public.sis_controller_dispatches','SELECT') as authenticated_dispatch_select,
  has_function_privilege('anon','public.sis_supervisor_dispatch_claim_v1(integer)','EXECUTE') as anon_supervisor_claim,
  has_function_privilege('authenticated','public.sis_supervisor_dispatch_claim_v1(integer)','EXECUTE') as authenticated_supervisor_claim,
  has_function_privilege('service_role','public.sis_controller_consumer_tick_v1(text,timestamptz,integer,integer)','EXECUTE') as service_controller_tick;

select worker_key,capability_key,environment_key,active
from public.sis_agent_worker_capabilities
where worker_key in ('sis.controller.orchestration','sis.supervisor')
  and environment_key in ('dev','test')
order by worker_key,environment_key,capability_key;

select jobid,jobname,schedule,active
from cron.job
where jobname in ('sis-controller-consumer-dev-v1','sis-controller-consumer-test-v1')
order by jobname;

select r.jobid,j.jobname,r.status,r.return_message,r.start_time,r.end_time
from cron.job_run_details r
join cron.job j on j.jobid=r.jobid
where j.jobname in ('sis-controller-consumer-dev-v1','sis-controller-consumer-test-v1')
order by r.start_time desc
limit 20;

select environment_key,status,lease_owner,heartbeat_at,lease_expires_at,recovery_count,last_tick_at,last_error
from public.sis_controller_runtime_state
where environment_key in ('dev','test')
order by environment_key;

select id,activation_id,work_item_key,environment_key,status,recovery_count,planned_job_ids,updated_at
from public.sis_controller_dispatches
order by created_at desc
limit 20;

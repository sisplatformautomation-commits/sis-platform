alter table public.sis_agent_hitl_runs add column resolver_worker_key text;
create index sis_agent_hitl_runs_resolver_idx on public.sis_agent_hitl_runs(resolver_worker_key) where resolver_worker_key is not null;

create or replace function public.sis_agent_hitl_read_v1(p_hitl_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select case when r.id is null then null else jsonb_build_object(
    'id',r.id,'work_item_key',r.work_item_key,'observed_work_item_key',r.observed_work_item_key,
    'environment_key',r.environment_key,'actor_key',r.actor_key,'resolver_worker_key',r.resolver_worker_key,
    'capability_key',r.capability_key,'resource_key',r.resource_key,'action_key',r.action_key,
    'authorization_policy_version',r.authorization_policy_version,'authorization_decision',r.authorization_decision,
    'authorization_evaluation_id',r.authorization_evaluation_id,'status',r.status,'resolution',r.resolution,
    'sdk_name',r.sdk_name,'sdk_version',r.sdk_version,'trace_id',r.trace_id,'tool_name',r.tool_name,
    'tool_call_id',r.tool_call_id,'state_sha256',r.state_sha256,'resumed_state_sha256',r.resumed_state_sha256,
    'interruption_count',r.interruption_count,'tool_execution_count',r.tool_execution_count,
    'provider_write_performed',r.provider_write_performed,'mail_write_performed',r.mail_write_performed,
    'execution_gate_changed',r.execution_gate_changed,'approval_gate_changed',r.approval_gate_changed,
    'final_output',r.final_output,'error_summary',r.error_summary,'metadata',r.metadata,
    'created_at',r.created_at,'updated_at',r.updated_at,'resolved_at',r.resolved_at,
    'serialized_state_persisted',r.sdk_state is not null
  ) end
  from public.sis_agent_hitl_runs r where r.id=p_hitl_id;
$$;

revoke all on function public.sis_agent_hitl_read_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_read_v1(uuid) to service_role;

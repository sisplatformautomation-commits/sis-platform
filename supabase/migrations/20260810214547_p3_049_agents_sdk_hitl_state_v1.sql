create table public.sis_agent_hitl_runs (
  id uuid primary key default gen_random_uuid(),
  work_item_key text not null default 'P3-049',
  observed_work_item_key text not null,
  environment_key text not null check (environment_key in ('dev','test')),
  actor_key text not null,
  capability_key text not null,
  resource_key text not null,
  action_key text not null,
  authorization_policy_version text not null,
  authorization_decision text not null check (authorization_decision in ('ALLOW','DENY','APPROVAL_REQUIRED')),
  authorization_evaluation_id uuid,
  status text not null check (status in ('created','pending_approval','approved_resumed','rejected_resumed','failed')),
  resolution text check (resolution is null or resolution in ('approve','reject')),
  sdk_name text not null default '@openai/agents',
  sdk_version text not null,
  trace_id text,
  tool_name text,
  tool_call_id text,
  sdk_state text,
  state_sha256 text,
  resumed_state_sha256 text,
  interruption_count integer not null default 0 check (interruption_count >= 0),
  tool_execution_count integer not null default 0 check (tool_execution_count between 0 and 1),
  provider_write_performed boolean not null default false check (provider_write_performed = false),
  mail_write_performed boolean not null default false check (mail_write_performed = false),
  execution_gate_changed boolean not null default false check (execution_gate_changed = false),
  approval_gate_changed boolean not null default false check (approval_gate_changed = false),
  final_output text,
  error_summary text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index sis_agent_hitl_runs_status_idx on public.sis_agent_hitl_runs(status, created_at desc);
create index sis_agent_hitl_runs_trace_idx on public.sis_agent_hitl_runs(trace_id) where trace_id is not null;
create index sis_agent_hitl_runs_observed_idx on public.sis_agent_hitl_runs(observed_work_item_key, created_at desc);

alter table public.sis_agent_hitl_runs enable row level security;
revoke all on public.sis_agent_hitl_runs from public, anon, authenticated;
grant select, insert, update, delete on public.sis_agent_hitl_runs to service_role;

create or replace function public.sis_agent_hitl_read_v1(p_hitl_id uuid)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select case when r.id is null then null else jsonb_build_object(
    'id',r.id,
    'work_item_key',r.work_item_key,
    'observed_work_item_key',r.observed_work_item_key,
    'environment_key',r.environment_key,
    'actor_key',r.actor_key,
    'capability_key',r.capability_key,
    'resource_key',r.resource_key,
    'action_key',r.action_key,
    'authorization_policy_version',r.authorization_policy_version,
    'authorization_decision',r.authorization_decision,
    'authorization_evaluation_id',r.authorization_evaluation_id,
    'status',r.status,
    'resolution',r.resolution,
    'sdk_name',r.sdk_name,
    'sdk_version',r.sdk_version,
    'trace_id',r.trace_id,
    'tool_name',r.tool_name,
    'tool_call_id',r.tool_call_id,
    'state_sha256',r.state_sha256,
    'resumed_state_sha256',r.resumed_state_sha256,
    'interruption_count',r.interruption_count,
    'tool_execution_count',r.tool_execution_count,
    'provider_write_performed',r.provider_write_performed,
    'mail_write_performed',r.mail_write_performed,
    'execution_gate_changed',r.execution_gate_changed,
    'approval_gate_changed',r.approval_gate_changed,
    'final_output',r.final_output,
    'error_summary',r.error_summary,
    'metadata',r.metadata,
    'created_at',r.created_at,
    'updated_at',r.updated_at,
    'resolved_at',r.resolved_at,
    'serialized_state_persisted',r.sdk_state is not null
  ) end
  from public.sis_agent_hitl_runs r
  where r.id=p_hitl_id;
$$;

revoke all on function public.sis_agent_hitl_read_v1(uuid) from public, anon, authenticated;
grant execute on function public.sis_agent_hitl_read_v1(uuid) to service_role;

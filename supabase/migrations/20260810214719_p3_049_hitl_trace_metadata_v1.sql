alter table public.sis_agent_hitl_runs add column if not exists trace_group_id text;
create index if not exists sis_agent_hitl_runs_trace_group_idx on public.sis_agent_hitl_runs(trace_group_id) where trace_group_id is not null;

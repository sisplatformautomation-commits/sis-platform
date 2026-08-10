-- SIS Runtime Foundation v1.3
-- Adds covering indexes for composite runtime foreign keys reported by the Supabase performance advisor.

create index if not exists sis_deployments_runtime_scope_idx
  on public.sis_deployments(runtime_environment_id, customer_id, environment)
  where runtime_environment_id is not null;

create index if not exists sis_runtime_access_sessions_runtime_scope_idx
  on public.sis_runtime_access_sessions(runtime_environment_id, customer_id, environment);

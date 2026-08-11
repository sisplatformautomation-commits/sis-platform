create table if not exists public.sis_agent_trace_runs (
  trace_id text primary key,
  workflow_name text not null,
  group_id text,
  work_item_key text not null,
  observed_work_item_key text,
  environment_key text not null check (environment_key in ('dev','test')),
  status text not null check (status in ('running','completed','failed')),
  sdk_name text not null default '@openai/agents',
  sdk_version text not null,
  source text not null default 'agents_sdk_custom_processor',
  started_at timestamptz not null,
  ended_at timestamptz,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sis_agent_trace_spans (
  span_id text primary key,
  trace_id text not null references public.sis_agent_trace_runs(trace_id) on delete cascade,
  parent_span_id text,
  span_name text not null,
  span_kind text not null,
  status text not null check (status in ('running','completed','failed')),
  started_at timestamptz,
  ended_at timestamptz,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data)='object'),
  error_summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists sis_agent_trace_runs_work_item_idx
  on public.sis_agent_trace_runs(work_item_key, started_at desc);
create index if not exists sis_agent_trace_runs_observed_item_idx
  on public.sis_agent_trace_runs(observed_work_item_key, started_at desc);
create index if not exists sis_agent_trace_spans_trace_idx
  on public.sis_agent_trace_spans(trace_id, started_at, span_id);

alter table public.sis_agent_trace_runs enable row level security;
alter table public.sis_agent_trace_spans enable row level security;

revoke all on public.sis_agent_trace_runs from public, anon, authenticated;
revoke all on public.sis_agent_trace_spans from public, anon, authenticated;
grant select, insert, update, delete on public.sis_agent_trace_runs to service_role;
grant select, insert, update, delete on public.sis_agent_trace_spans to service_role;

create or replace function public.sis_agent_trace_read_v1(p_trace_id text)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select case when r.trace_id is null then null else jsonb_build_object(
    'trace', jsonb_build_object(
      'trace_id',r.trace_id,
      'workflow_name',r.workflow_name,
      'group_id',r.group_id,
      'work_item_key',r.work_item_key,
      'observed_work_item_key',r.observed_work_item_key,
      'environment_key',r.environment_key,
      'status',r.status,
      'sdk_name',r.sdk_name,
      'sdk_version',r.sdk_version,
      'started_at',r.started_at,
      'ended_at',r.ended_at,
      'metadata',r.metadata
    ),
    'spans', coalesce((
      select jsonb_agg(jsonb_build_object(
        'span_id',s.span_id,
        'parent_span_id',s.parent_span_id,
        'span_name',s.span_name,
        'span_kind',s.span_kind,
        'status',s.status,
        'started_at',s.started_at,
        'ended_at',s.ended_at,
        'data',s.data,
        'error_summary',s.error_summary
      ) order by s.started_at nulls last, s.created_at, s.span_id)
      from public.sis_agent_trace_spans s where s.trace_id=r.trace_id
    ),'[]'::jsonb)
  ) end
  from public.sis_agent_trace_runs r
  where r.trace_id=btrim(p_trace_id);
$$;

revoke all on function public.sis_agent_trace_read_v1(text) from public, anon, authenticated;
grant execute on function public.sis_agent_trace_read_v1(text) to service_role;

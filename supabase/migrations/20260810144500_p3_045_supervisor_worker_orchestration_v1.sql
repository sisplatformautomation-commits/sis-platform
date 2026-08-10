-- P3-045: SIS Supervisor & Multi-Agent Worker Orchestration v1
-- Builds on the neutral Work Item -> Job -> Attempt -> Step -> Artifact execution plane.
-- P3-043 remains the resource/action guard when external provider resources are requested.

create table if not exists public.sis_agent_workers (
  worker_key text primary key,
  worker_role text not null check (worker_role in ('supervisor','worker','reviewer')),
  domain_key text not null,
  status text not null default 'active' check (status in ('active','disabled')),
  max_concurrency integer not null default 1 check (max_concurrency between 1 and 32),
  runtime_binding jsonb not null default '{}'::jsonb check (jsonb_typeof(runtime_binding)='object' and pg_column_size(runtime_binding)<=16384),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sis_agent_workers_key_chk check (worker_key ~ '^sis\.[a-z0-9_\.]+$'),
  constraint sis_agent_workers_domain_chk check (domain_key ~ '^[a-z0-9_]+$')
);

create table if not exists public.sis_agent_capabilities (
  capability_key text primary key,
  capability_class text not null check (capability_class in ('orchestration','database','integration','repository','documentation','runtime','finance','review')),
  risk_level text not null check (risk_level in ('low','medium','high','critical')),
  provider_write boolean not null default false,
  external_financial_write boolean not null default false,
  destructive boolean not null default false,
  prod_approval_required boolean not null default false,
  independent_review_required boolean not null default false,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sis_agent_capabilities_key_chk check (capability_key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$')
);

create table if not exists public.sis_agent_worker_capabilities (
  worker_key text not null references public.sis_agent_workers(worker_key) on delete cascade,
  capability_key text not null references public.sis_agent_capabilities(capability_key) on delete cascade,
  environment_key text not null check (environment_key in ('dev','test','uat','prod')),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=8192),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(worker_key,capability_key,environment_key)
);

create table if not exists public.sis_agent_job_assignments (
  job_id uuid primary key references public.sis_jobs(id) on delete cascade,
  environment_key text not null check (environment_key in ('dev','test','uat','prod')),
  assigned_worker_key text not null references public.sis_agent_workers(worker_key) on delete restrict,
  reviewer_worker_key text references public.sis_agent_workers(worker_key) on delete restrict,
  required_capabilities text[] not null,
  required_resource_keys text[] not null default '{}'::text[],
  review_required boolean not null default true,
  review_profile text not null default 'qa_security' check (review_profile in ('none','qa','security','qa_security')),
  approval_required boolean not null default false,
  assignment_state text not null default 'queued' check (assignment_state in ('queued','blocked','running','review_required','accepted','rework','failed','cancelled')),
  active_attempt_id uuid references public.sis_job_attempts(id) on delete set null,
  lease_token uuid,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=32768),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sis_agent_job_assignments_caps_chk check (cardinality(required_capabilities) > 0 and array_position(required_capabilities,null) is null),
  constraint sis_agent_job_assignments_resources_chk check (array_position(required_resource_keys,null) is null),
  constraint sis_agent_job_assignments_self_review_chk check (reviewer_worker_key is null or reviewer_worker_key <> assigned_worker_key)
);

create table if not exists public.sis_agent_job_approvals (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.sis_jobs(id) on delete cascade,
  environment_key text not null check (environment_key in ('dev','test','uat','prod')),
  approval_scope text not null check (approval_scope in ('execute','prod_promotion','provider_write','external_financial_write','destructive_change')),
  decision text not null check (decision in ('granted','denied')),
  approved_by text not null,
  approval_source text not null,
  approval_event_id bigint references public.sis_events(id) on delete set null,
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=16384),
  created_at timestamptz not null default now(),
  constraint sis_agent_job_approvals_expiry_chk check (expires_at is null or expires_at > granted_at)
);

create table if not exists public.sis_agent_reviews (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.sis_jobs(id) on delete cascade,
  attempt_id uuid not null references public.sis_job_attempts(id) on delete cascade,
  reviewer_worker_key text not null references public.sis_agent_workers(worker_key) on delete restrict,
  review_type text not null check (review_type in ('qa','security','qa_security')),
  decision text not null check (decision in ('pass','changes_required','fail')),
  evidence jsonb not null default '{}'::jsonb check (jsonb_typeof(evidence)='object' and pg_column_size(evidence)<=32768),
  created_at timestamptz not null default now(),
  unique(attempt_id,reviewer_worker_key,review_type)
);

create index if not exists sis_agent_workers_role_status_idx on public.sis_agent_workers(worker_role,status);
create index if not exists sis_agent_worker_caps_lookup_idx on public.sis_agent_worker_capabilities(capability_key,environment_key,active,worker_key);
create index if not exists sis_agent_assignments_worker_state_idx on public.sis_agent_job_assignments(assigned_worker_key,assignment_state,environment_key);
create index if not exists sis_agent_assignments_reviewer_state_idx on public.sis_agent_job_assignments(reviewer_worker_key,assignment_state,environment_key);
create index if not exists sis_agent_approvals_job_idx on public.sis_agent_job_approvals(job_id,environment_key,decision,granted_at desc);
create index if not exists sis_agent_reviews_job_idx on public.sis_agent_reviews(job_id,created_at desc);

alter table public.sis_agent_workers enable row level security;
alter table public.sis_agent_capabilities enable row level security;
alter table public.sis_agent_worker_capabilities enable row level security;
alter table public.sis_agent_job_assignments enable row level security;
alter table public.sis_agent_job_approvals enable row level security;
alter table public.sis_agent_reviews enable row level security;

revoke all on table public.sis_agent_workers from public, anon, authenticated, service_role;
revoke all on table public.sis_agent_capabilities from public, anon, authenticated, service_role;
revoke all on table public.sis_agent_worker_capabilities from public, anon, authenticated, service_role;
revoke all on table public.sis_agent_job_assignments from public, anon, authenticated, service_role;
revoke all on table public.sis_agent_job_approvals from public, anon, authenticated, service_role;
revoke all on table public.sis_agent_reviews from public, anon, authenticated, service_role;

drop trigger if exists sis_agent_workers_set_updated_at on public.sis_agent_workers;
create trigger sis_agent_workers_set_updated_at before update on public.sis_agent_workers for each row execute function public.sis_set_updated_at();
drop trigger if exists sis_agent_capabilities_set_updated_at on public.sis_agent_capabilities;
create trigger sis_agent_capabilities_set_updated_at before update on public.sis_agent_capabilities for each row execute function public.sis_set_updated_at();
drop trigger if exists sis_agent_worker_caps_set_updated_at on public.sis_agent_worker_capabilities;
create trigger sis_agent_worker_caps_set_updated_at before update on public.sis_agent_worker_capabilities for each row execute function public.sis_set_updated_at();
drop trigger if exists sis_agent_assignments_set_updated_at on public.sis_agent_job_assignments;
create trigger sis_agent_assignments_set_updated_at before update on public.sis_agent_job_assignments for each row execute function public.sis_set_updated_at();

insert into public.sis_agent_capabilities(
  capability_key,capability_class,risk_level,provider_write,external_financial_write,destructive,prod_approval_required,independent_review_required,metadata
) values
('orchestration.plan','orchestration','low',false,false,false,false,false,'{"description":"Plan and decompose work items into guarded jobs"}'::jsonb),
('orchestration.delegate','orchestration','low',false,false,false,false,false,'{"description":"Select eligible worker profiles and queue jobs"}'::jsonb),
('database.read','database','low',false,false,false,false,false,'{}'::jsonb),
('database.migration','database','high',false,false,false,true,true,'{}'::jsonb),
('integration.provider_read','integration','medium',false,false,false,false,true,'{}'::jsonb),
('integration.provider_write','integration','high',true,false,false,true,true,'{}'::jsonb),
('repository.branch_write','repository','medium',false,false,false,false,true,'{}'::jsonb),
('repository.pr_write','repository','medium',false,false,false,false,true,'{}'::jsonb),
('repository.merge','repository','high',false,false,false,true,true,'{}'::jsonb),
('documentation.write','documentation','low',false,false,false,false,true,'{}'::jsonb),
('runtime.read','runtime','low',false,false,false,false,false,'{}'::jsonb),
('runtime.change','runtime','high',true,false,false,true,true,'{}'::jsonb),
('finance.read','finance','medium',false,false,false,false,true,'{}'::jsonb),
('finance.external_write','finance','critical',true,true,false,true,true,'{"default_grant":"none"}'::jsonb),
('review.qa','review','low',false,false,false,false,false,'{}'::jsonb),
('review.security','review','low',false,false,false,false,false,'{}'::jsonb)
on conflict(capability_key) do update set
  capability_class=excluded.capability_class,
  risk_level=excluded.risk_level,
  provider_write=excluded.provider_write,
  external_financial_write=excluded.external_financial_write,
  destructive=excluded.destructive,
  prod_approval_required=excluded.prod_approval_required,
  independent_review_required=excluded.independent_review_required,
  metadata=excluded.metadata,
  updated_at=now();

insert into public.sis_agent_workers(worker_key,worker_role,domain_key,status,max_concurrency,runtime_binding,metadata) values
('sis.supervisor','supervisor','orchestration','active',1,'{"binding":"logical","provider_actions":false}'::jsonb,'{"self_execution":false}'::jsonb),
('sis.worker.database','worker','database','active',2,'{"binding":"gpt_profile"}'::jsonb,'{}'::jsonb),
('sis.worker.integration','worker','integration','active',2,'{"binding":"gpt_profile"}'::jsonb,'{}'::jsonb),
('sis.worker.repository','worker','repository','active',2,'{"binding":"gpt_profile"}'::jsonb,'{}'::jsonb),
('sis.worker.documentation','worker','documentation','active',2,'{"binding":"gpt_profile"}'::jsonb,'{}'::jsonb),
('sis.worker.runtime','worker','runtime','active',2,'{"binding":"gpt_profile"}'::jsonb,'{}'::jsonb),
('sis.worker.finance','worker','finance','active',1,'{"binding":"gpt_profile"}'::jsonb,'{"external_write_default":false}'::jsonb),
('sis.reviewer.qa_security','reviewer','review','active',3,'{"binding":"gpt_profile"}'::jsonb,'{"independent":true}'::jsonb)
on conflict(worker_key) do update set
  worker_role=excluded.worker_role,domain_key=excluded.domain_key,status=excluded.status,max_concurrency=excluded.max_concurrency,
  runtime_binding=excluded.runtime_binding,metadata=excluded.metadata,updated_at=now();

insert into public.sis_agent_worker_capabilities(worker_key,capability_key,environment_key,active)
select x.worker_key,x.capability_key,e.environment_key,true
from (values
 ('sis.supervisor','orchestration.plan'),
 ('sis.supervisor','orchestration.delegate'),
 ('sis.worker.database','database.read'),
 ('sis.worker.database','database.migration'),
 ('sis.worker.integration','integration.provider_read'),
 ('sis.worker.integration','integration.provider_write'),
 ('sis.worker.repository','repository.branch_write'),
 ('sis.worker.repository','repository.pr_write'),
 ('sis.worker.repository','repository.merge'),
 ('sis.worker.documentation','documentation.write'),
 ('sis.worker.runtime','runtime.read'),
 ('sis.worker.runtime','runtime.change'),
 ('sis.worker.finance','finance.read'),
 ('sis.reviewer.qa_security','review.qa'),
 ('sis.reviewer.qa_security','review.security')
) as x(worker_key,capability_key)
cross join (values('dev'),('test'),('uat'),('prod')) as e(environment_key)
on conflict(worker_key,capability_key,environment_key) do update set active=true,updated_at=now();

-- Intentionally no default grant of finance.external_write to any worker.

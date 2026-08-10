-- P3-043 GPT Action Resource Registry and guarded Make dispatcher
-- Durable resource-key layer for GPT actions. Existing scenario-specific DEV actions remain compatible.
-- First registered resource: read-only Qonto adapter for sis_internal_hospitality.

create table if not exists public.sis_gpt_action_resources (
  id uuid primary key default gen_random_uuid(),
  resource_key text not null unique check (btrim(resource_key) <> ''),
  provider text not null check (provider in ('make')),
  resource_type text not null check (resource_type in ('make_scenario')),
  environment_key text not null check (environment_key in ('dev','test','uat','prod')),
  customer_key text,
  business_case_key text,
  display_name text not null,
  status text not null default 'active' check (status in ('active','disabled','superseded')),
  risk_class text not null,
  allowed_operations text[] not null check (cardinality(allowed_operations) > 0),
  guard_profile text not null,
  external_resource jsonb not null default '{}'::jsonb check (jsonb_typeof(external_resource)='object'),
  guard_config jsonb not null default '{}'::jsonb check (jsonb_typeof(guard_config)='object'),
  approval_scope jsonb not null default '{}'::jsonb check (jsonb_typeof(approval_scope)='object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sis_gpt_action_resources enable row level security;
revoke all on table public.sis_gpt_action_resources from public, anon, authenticated, service_role;

drop trigger if exists sis_gpt_action_resources_set_updated_at on public.sis_gpt_action_resources;
create trigger sis_gpt_action_resources_set_updated_at
before update on public.sis_gpt_action_resources
for each row execute function public.sis_set_updated_at();

create table if not exists public.sis_gpt_action_invocations (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.sis_gpt_action_resources(id) on delete restrict,
  resource_key text not null,
  operation text not null,
  actor text not null default 'sis_gpt_action',
  status text not null check (status in ('running','submitted','succeeded','failed')),
  correlation_id uuid not null default gen_random_uuid(),
  external_execution_id text,
  http_status integer,
  request_sha256 text,
  response_meta jsonb not null default '{}'::jsonb check (jsonb_typeof(response_meta)='object'),
  error_code text,
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists sis_gpt_action_invocations_resource_created_idx
  on public.sis_gpt_action_invocations(resource_id, created_at desc);
create index if not exists sis_gpt_action_invocations_execution_idx
  on public.sis_gpt_action_invocations(external_execution_id)
  where external_execution_id is not null;

alter table public.sis_gpt_action_invocations enable row level security;
revoke all on table public.sis_gpt_action_invocations from public, anon, authenticated, service_role;

insert into public.sis_gpt_action_resources (
  resource_key,provider,resource_type,environment_key,customer_key,business_case_key,display_name,status,risk_class,
  allowed_operations,guard_profile,external_resource,guard_config,approval_scope
) values (
  'make.lexhub.qonto_read.dev.sis_internal_hospitality','make','make_scenario','dev','sis_internal_hospitality','PLATFORM_FOUNDATION_3_0',
  'LEXHUB Qonto Read Adapter – SIS Internal Hospitality','active','external_provider_read_internal_audit_write',
  array['describe','run_once','execution_status'],'make_qonto_read_adapter_v1',
  jsonb_build_object('scenario_id',6871294,'connection_id',9597442),
  jsonb_build_object(
    'expected_scenario_name','LEXHUB | DEV | Qonto Read Adapter',
    'expected_scheduling_type','on-demand',
    'expected_module_count',15,
    'expected_qonto_api_modules',7,
    'expected_datastore_modules',7,
    'qonto_api_method','GET',
    'qonto_api_url_prefix','v2/transactions?',
    'datastore_key_prefix','LEXHUB_DEV_QONTO_PAGE_'
  ),
  jsonb_build_object(
    'approved_by','user_explicit',
    'scope','existing_make_dev_connections_for_development_and_test_only',
    'provider_write_allowed',false,
    'external_financial_writes',false,
    'prod_provider_writes',false,
    'public_anon_authenticated_execute_exception',false
  )
)
on conflict (resource_key) do update set
  provider=excluded.provider,
  resource_type=excluded.resource_type,
  environment_key=excluded.environment_key,
  customer_key=excluded.customer_key,
  business_case_key=excluded.business_case_key,
  display_name=excluded.display_name,
  status=excluded.status,
  risk_class=excluded.risk_class,
  allowed_operations=excluded.allowed_operations,
  guard_profile=excluded.guard_profile,
  external_resource=excluded.external_resource,
  guard_config=excluded.guard_config,
  approval_scope=excluded.approval_scope,
  updated_at=now();

create or replace function public.sis_gpt_action_list_v1(
  p_environment_key text default null,
  p_customer_key text default null
) returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'resource_key',r.resource_key,
    'display_name',r.display_name,
    'provider',r.provider,
    'resource_type',r.resource_type,
    'environment_key',r.environment_key,
    'customer_key',r.customer_key,
    'business_case_key',r.business_case_key,
    'risk_class',r.risk_class,
    'allowed_operations',r.allowed_operations,
    'status',r.status
  ) order by r.resource_key),'[]'::jsonb)
  from public.sis_gpt_action_resources r
  where r.status='active'
    and (p_environment_key is null or r.environment_key=lower(btrim(p_environment_key)))
    and (p_customer_key is null or r.customer_key=btrim(p_customer_key));
$$;

revoke all on function public.sis_gpt_action_list_v1(text,text) from public, anon, authenticated;
grant execute on function public.sis_gpt_action_list_v1(text,text) to service_role;

create or replace function public.sis_make_gpt_action_validate_blueprint_v1(
  p_resource_key text,
  p_scenario jsonb,
  p_blueprint jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_r public.sis_gpt_action_resources%rowtype;
  v_s jsonb;
  v_bp jsonb;
  v_flow jsonb;
  v_scenario_id bigint;
  v_connection_id bigint;
  v_module_count integer;
  v_qonto_api_count integer;
  v_datastore_count integer;
begin
  select * into v_r
  from public.sis_gpt_action_resources
  where resource_key=btrim(p_resource_key) and status='active';
  if v_r.id is null then raise exception 'GPT_ACTION_RESOURCE_NOT_FOUND'; end if;
  if v_r.provider<>'make' or v_r.resource_type<>'make_scenario' then raise exception 'GPT_ACTION_RESOURCE_TYPE_NOT_SUPPORTED'; end if;
  if v_r.guard_profile<>'make_qonto_read_adapter_v1' then raise exception 'GPT_ACTION_GUARD_PROFILE_NOT_SUPPORTED'; end if;

  v_scenario_id := nullif(v_r.external_resource->>'scenario_id','')::bigint;
  v_connection_id := nullif(v_r.external_resource->>'connection_id','')::bigint;
  if v_scenario_id is null or v_connection_id is null then raise exception 'GPT_ACTION_RESOURCE_CONFIG_INVALID'; end if;

  v_s := case when jsonb_typeof(p_scenario->'scenario')='object' then p_scenario->'scenario' else p_scenario end;
  v_bp := case
    when jsonb_typeof(p_blueprint#>'{response,blueprint}')='object' then p_blueprint#>'{response,blueprint}'
    when jsonb_typeof(p_blueprint->'blueprint')='object' then p_blueprint->'blueprint'
    else p_blueprint
  end;
  v_flow := coalesce(v_bp->'flow','[]'::jsonb);

  if jsonb_typeof(v_s)<>'object' or jsonb_typeof(v_flow)<>'array' then raise exception 'GPT_ACTION_PREFLIGHT_SHAPE_INVALID'; end if;
  if nullif(v_s->>'id','')::bigint is distinct from v_scenario_id then raise exception 'GPT_ACTION_SCENARIO_ID_MISMATCH'; end if;
  if v_s->>'name' is distinct from v_r.guard_config->>'expected_scenario_name' then raise exception 'GPT_ACTION_SCENARIO_NAME_MISMATCH'; end if;
  if v_s#>>'{scheduling,type}' is distinct from v_r.guard_config->>'expected_scheduling_type' then raise exception 'GPT_ACTION_SCHEDULING_MISMATCH'; end if;

  select count(*),
         count(*) filter (where m->>'module'='qonto:makeApiCall'),
         count(*) filter (where m->>'module'='datastore:UpdateRecord')
    into v_module_count,v_qonto_api_count,v_datastore_count
  from jsonb_array_elements(v_flow) m;

  if v_module_count <> (v_r.guard_config->>'expected_module_count')::integer then raise exception 'GPT_ACTION_MODULE_COUNT_MISMATCH'; end if;
  if v_qonto_api_count <> (v_r.guard_config->>'expected_qonto_api_modules')::integer then raise exception 'GPT_ACTION_QONTO_PAGE_COUNT_MISMATCH'; end if;
  if v_datastore_count <> (v_r.guard_config->>'expected_datastore_modules')::integer then raise exception 'GPT_ACTION_DATASTORE_COUNT_MISMATCH'; end if;

  if exists (
    select 1 from jsonb_array_elements(v_flow) m
    where m->>'module' not in ('qonto:readOrganization','qonto:makeApiCall','datastore:UpdateRecord')
  ) then raise exception 'GPT_ACTION_MODULE_NOT_ALLOWED'; end if;

  if exists (
    select 1 from jsonb_array_elements(v_flow) m
    where m->>'module' in ('qonto:readOrganization','qonto:makeApiCall')
      and nullif(m#>>'{parameters,__IMTCONN__}','')::bigint is distinct from v_connection_id
  ) then raise exception 'GPT_ACTION_CONNECTION_MISMATCH'; end if;

  if exists (
    select 1 from jsonb_array_elements(v_flow) m
    where m->>'module'='qonto:makeApiCall'
      and (upper(coalesce(m#>>'{mapper,method}','')) <> upper(v_r.guard_config->>'qonto_api_method')
           or coalesce(m#>>'{mapper,url}','') not like (v_r.guard_config->>'qonto_api_url_prefix') || '%')
  ) then raise exception 'GPT_ACTION_QONTO_READ_GUARD_FAILED'; end if;

  if exists (
    select 1 from jsonb_array_elements(v_flow) m
    where m->>'module'='datastore:UpdateRecord'
      and coalesce(m#>>'{mapper,key}','') not like (v_r.guard_config->>'datastore_key_prefix') || '%'
  ) then raise exception 'GPT_ACTION_DATASTORE_AUDIT_GUARD_FAILED'; end if;

  return jsonb_build_object(
    'ok',true,
    'resource_key',v_r.resource_key,
    'scenario_id',v_scenario_id,
    'connection_id',v_connection_id,
    'module_count',v_module_count,
    'qonto_api_modules',v_qonto_api_count,
    'datastore_modules',v_datastore_count,
    'provider_write_allowed',false,
    'external_financial_writes',false
  );
end;
$$;

revoke all on function public.sis_make_gpt_action_validate_blueprint_v1(text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.sis_make_gpt_action_validate_blueprint_v1(text,jsonb,jsonb) to service_role;

create or replace function public.sis_make_gpt_action_run_v1(
  p_resource_key text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, vault
as $$
declare
  v_r public.sis_gpt_action_resources%rowtype;
  v_scenario_id bigint;
  v_connection_id bigint;
  v_sc jsonb;
  v_bp jsonb;
  v_guard jsonb;
  v_token text;
  v_resp extensions.http_response;
  v_body jsonb;
  v_execution_id text;
  v_invocation_id uuid;
  v_request text := '{"responsive":false}';
  v_request_sha256 text;
begin
  select * into v_r from public.sis_gpt_action_resources where resource_key=btrim(p_resource_key) and status='active';
  if v_r.id is null then raise exception 'GPT_ACTION_RESOURCE_NOT_FOUND'; end if;
  if v_r.environment_key not in ('dev','test') then raise exception 'GPT_ACTION_NONPROD_ONLY'; end if;
  if not ('run_once'=any(v_r.allowed_operations)) then raise exception 'GPT_ACTION_OPERATION_NOT_ALLOWED'; end if;
  if coalesce((v_r.approval_scope->>'provider_write_allowed')::boolean,true) then raise exception 'GPT_ACTION_PROVIDER_WRITE_SCOPE_NOT_ALLOWED'; end if;
  if coalesce((v_r.approval_scope->>'external_financial_writes')::boolean,true) then raise exception 'GPT_ACTION_FINANCIAL_WRITE_SCOPE_NOT_ALLOWED'; end if;

  v_scenario_id := nullif(v_r.external_resource->>'scenario_id','')::bigint;
  v_connection_id := nullif(v_r.external_resource->>'connection_id','')::bigint;
  v_sc := public.asog_make_http_read('get_scenario',v_scenario_id);
  v_bp := public.asog_make_http_read('get_blueprint',v_scenario_id);
  if not coalesce((v_sc->>'ok')::boolean,false) or not coalesce((v_bp->>'ok')::boolean,false) then raise exception 'GPT_ACTION_MAKE_PREFLIGHT_READ_FAILED'; end if;
  v_guard := public.sis_make_gpt_action_validate_blueprint_v1(v_r.resource_key,v_sc->'body',v_bp->'body');

  select decrypted_secret into v_token from vault.decrypted_secrets where name='make_eu1_api_token' order by created_at desc limit 1;
  if v_token is null or length(v_token)<8 then raise exception 'MAKE_TOKEN_MISSING'; end if;
  v_request_sha256 := encode(extensions.digest(v_request,'sha256'),'hex');

  insert into public.sis_gpt_action_invocations(resource_id,resource_key,operation,status,request_sha256,response_meta)
  values(v_r.id,v_r.resource_key,'run_once','running',v_request_sha256,jsonb_build_object('scenario_id',v_scenario_id,'connection_id',v_connection_id,'guard',v_guard))
  returning id into v_invocation_id;

  select * into v_resp from extensions.http((
    'POST'::extensions.http_method,
    ('https://eu1.make.com/api/v2/connections/'||v_connection_id::text||'/test')::varchar,
    array[
      extensions.http_header('Authorization'::varchar,('Token '||v_token)::varchar),
      extensions.http_header('Accept'::varchar,'application/json'::varchar),
      extensions.http_header('Content-Type'::varchar,'application/json'::varchar)
    ]::extensions.http_header[],
    'application/json'::varchar,
    '{}'::varchar
  )::extensions.http_request);

  if v_resp.status not between 200 and 299 then
    update public.sis_gpt_action_invocations set status='failed',http_status=v_resp.status,error_code='connection_test_failed',error_message='Make connection test failed',completed_at=now() where id=v_invocation_id;
    return jsonb_build_object('ok',false,'resource_key',v_r.resource_key,'invocation_id',v_invocation_id,'phase','connection_test','http_status',v_resp.status);
  end if;

  select * into v_resp from extensions.http((
    'POST'::extensions.http_method,
    ('https://eu1.make.com/api/v2/scenarios/'||v_scenario_id::text||'/run')::varchar,
    array[
      extensions.http_header('Authorization'::varchar,('Token '||v_token)::varchar),
      extensions.http_header('Accept'::varchar,'application/json'::varchar),
      extensions.http_header('Content-Type'::varchar,'application/json'::varchar)
    ]::extensions.http_header[],
    'application/json'::varchar,
    v_request::varchar
  )::extensions.http_request);

  begin v_body:=coalesce(nullif(v_resp.content,''),'{}')::jsonb;
  exception when others then v_body:=jsonb_build_object(); end;
  v_execution_id:=coalesce(v_body->>'executionId',v_body->>'execution_id',v_body#>>'{execution,id}');

  if v_resp.status not between 200 and 299 or v_execution_id is null or v_execution_id !~ '^[0-9a-f]{32}$' then
    update public.sis_gpt_action_invocations set status='failed',http_status=v_resp.status,error_code='scenario_run_failed',error_message='Make scenario run did not return a verifiable execution id',response_meta=response_meta||jsonb_build_object('connection_test_verified',true),completed_at=now() where id=v_invocation_id;
    return jsonb_build_object('ok',false,'resource_key',v_r.resource_key,'invocation_id',v_invocation_id,'phase','run','http_status',v_resp.status,'connection_test_verified',true);
  end if;

  update public.sis_gpt_action_invocations
  set status='submitted',external_execution_id=v_execution_id,http_status=v_resp.status,response_meta=response_meta||jsonb_build_object('connection_test_verified',true,'execution_id',v_execution_id)
  where id=v_invocation_id;

  return jsonb_build_object(
    'ok',true,
    'resource_key',v_r.resource_key,
    'invocation_id',v_invocation_id,
    'scenario_id',v_scenario_id,
    'execution_id',v_execution_id,
    'http_status',v_resp.status,
    'connection_test_verified',true,
    'provider_write_allowed',false,
    'external_financial_writes',false
  );
exception when others then
  if v_invocation_id is not null then
    update public.sis_gpt_action_invocations set status='failed',error_code='dispatcher_exception',error_message=left(sqlerrm,1000),completed_at=now() where id=v_invocation_id and status='running';
  end if;
  raise;
end;
$$;

revoke all on function public.sis_make_gpt_action_run_v1(text) from public, anon, authenticated;
grant execute on function public.sis_make_gpt_action_run_v1(text) to service_role;

create or replace function public.sis_make_gpt_action_execution_status_v1(
  p_resource_key text,
  p_execution_id text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_r public.sis_gpt_action_resources%rowtype;
  v_scenario_id bigint;
  v_detail jsonb;
  v_status text;
begin
  if p_execution_id is null or p_execution_id !~ '^[0-9a-f]{32}$' then raise exception 'INVALID_EXECUTION_ID'; end if;
  select * into v_r from public.sis_gpt_action_resources where resource_key=btrim(p_resource_key) and status='active';
  if v_r.id is null then raise exception 'GPT_ACTION_RESOURCE_NOT_FOUND'; end if;
  if not ('execution_status'=any(v_r.allowed_operations)) then raise exception 'GPT_ACTION_OPERATION_NOT_ALLOWED'; end if;
  v_scenario_id:=nullif(v_r.external_resource->>'scenario_id','')::bigint;
  v_detail:=public.asog_make_execution_detail(v_scenario_id,p_execution_id);
  if not coalesce((v_detail->>'ok')::boolean,false) then return jsonb_build_object('ok',false,'resource_key',v_r.resource_key,'execution_id',p_execution_id,'http_status',v_detail->'http_status'); end if;
  v_status:=upper(coalesce(v_detail#>>'{body,status}','UNKNOWN'));

  if v_status='SUCCESS' then
    update public.sis_gpt_action_invocations set status='succeeded',completed_at=coalesce(completed_at,now()),response_meta=response_meta||jsonb_build_object('execution_status',v_status) where resource_id=v_r.id and external_execution_id=p_execution_id and status in ('running','submitted');
  elsif v_status in ('ERROR','FAILED','CANCELLED','CANCELED') then
    update public.sis_gpt_action_invocations set status='failed',completed_at=coalesce(completed_at,now()),error_code='make_execution_failed',response_meta=response_meta||jsonb_build_object('execution_status',v_status) where resource_id=v_r.id and external_execution_id=p_execution_id and status in ('running','submitted');
  end if;

  return jsonb_build_object('ok',true,'resource_key',v_r.resource_key,'scenario_id',v_scenario_id,'execution_id',p_execution_id,'status',v_status,'provider_write_allowed',false,'external_financial_writes',false);
end;
$$;

revoke all on function public.sis_make_gpt_action_execution_status_v1(text,text) from public, anon, authenticated;
grant execute on function public.sis_make_gpt_action_execution_status_v1(text,text) to service_role;

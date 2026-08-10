-- P3-044 provider-neutral knowledge, communication and storage foundation
-- Existing Google Drive references remain readable as legacy records.

alter table public.sis_knowledge_documents
  drop constraint if exists sis_knowledge_documents_source_chk;

alter table public.sis_knowledge_documents
  add column if not exists canonical_uri text,
  add column if not exists revision_ref text,
  add column if not exists content_format text,
  add column if not exists legacy_reference jsonb not null default '{}'::jsonb;

update public.sis_knowledge_documents
set canonical_uri = coalesce(canonical_uri, 'google-drive://' || file_id),
    content_format = coalesce(content_format, 'google_doc'),
    legacy_reference = case
      when source = 'google_drive' then legacy_reference || jsonb_build_object('google_drive_file_id', file_id, 'google_drive_canonical_file_id', canonical_file_id)
      else legacy_reference
    end
where canonical_uri is null or content_format is null or (source='google_drive' and legacy_reference='{}'::jsonb);

alter table public.sis_knowledge_documents
  alter column canonical_uri set not null;

alter table public.sis_knowledge_documents
  add constraint sis_knowledge_documents_source_chk
    check (source in ('google_drive','github','supabase_storage','customer_reference')),
  add constraint sis_knowledge_documents_canonical_uri_chk
    check (length(btrim(canonical_uri)) > 0),
  add constraint sis_knowledge_documents_content_format_chk
    check (content_format is null or content_format in ('markdown','text','json','pdf','binary','google_doc','external_reference')),
  add constraint sis_knowledge_documents_legacy_reference_object_chk
    check (jsonb_typeof(legacy_reference)='object');

create index if not exists sis_knowledge_documents_source_uri_idx
  on public.sis_knowledge_documents(source, canonical_uri);

create or replace view public.sis_v_knowledge_documents_v2
with (security_invoker=true)
as
select
  id,
  business_case_id,
  document_type,
  title,
  version,
  status,
  is_canonical,
  source as storage_provider,
  canonical_uri,
  revision_ref,
  content_format,
  content_hash,
  hash_algorithm,
  published_at,
  verified_at,
  file_id as legacy_or_provider_object_id,
  canonical_file_id as legacy_or_provider_canonical_id,
  legacy_reference,
  metadata,
  created_at,
  updated_at
from public.sis_knowledge_documents;

revoke all on public.sis_v_knowledge_documents_v2 from public, anon, authenticated;
grant select on public.sis_v_knowledge_documents_v2 to service_role;

create or replace function public.sis_register_knowledge_document_v2(
  p_business_case_key text,
  p_document_type text,
  p_title text,
  p_version text,
  p_source text,
  p_provider_object_id text,
  p_canonical_uri text,
  p_revision_ref text,
  p_content_hash text,
  p_content_format text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_business_case_id uuid;
  v_id uuid;
  v_source text := lower(btrim(p_source));
  v_object_id text := btrim(p_provider_object_id);
  v_uri text := btrim(p_canonical_uri);
begin
  if v_source not in ('google_drive','github','supabase_storage','customer_reference') then
    raise exception 'KNOWLEDGE_SOURCE_NOT_ALLOWED';
  end if;
  if p_document_type is null or p_document_type !~ '^[a-z0-9][a-z0-9_]*$' then
    raise exception 'INVALID_DOCUMENT_TYPE';
  end if;
  if v_object_id is null or v_object_id='' or v_uri is null or v_uri='' then
    raise exception 'KNOWLEDGE_REFERENCE_REQUIRED';
  end if;
  if p_content_hash is null or lower(p_content_hash) !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_SHA256';
  end if;
  if p_content_format is not null and p_content_format not in ('markdown','text','json','pdf','binary','google_doc','external_reference') then
    raise exception 'INVALID_CONTENT_FORMAT';
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>32768 then
    raise exception 'INVALID_KNOWLEDGE_METADATA';
  end if;

  select id into v_business_case_id
  from public.sis_business_cases
  where business_case_key=btrim(p_business_case_key);
  if v_business_case_id is null then raise exception 'BUSINESS_CASE_NOT_FOUND'; end if;

  update public.sis_knowledge_documents
  set is_canonical=false,
      status='superseded',
      metadata=metadata || jsonb_build_object('superseded_at',now(),'superseded_by_uri',v_uri)
  where business_case_id=v_business_case_id
    and document_type=p_document_type
    and is_canonical=true;

  insert into public.sis_knowledge_documents(
    business_case_id,document_type,file_id,canonical_file_id,title,version,content_hash,hash_algorithm,
    status,is_canonical,source,published_at,verified_at,metadata,canonical_uri,revision_ref,content_format,legacy_reference
  ) values (
    v_business_case_id,p_document_type,v_object_id,v_object_id,p_title,p_version,lower(p_content_hash),'sha256',
    'published',true,v_source,now(),now(),p_metadata,v_uri,nullif(btrim(p_revision_ref),''),p_content_format,
    case when v_source='google_drive' then jsonb_build_object('google_drive_file_id',v_object_id) else '{}'::jsonb end
  ) returning id into v_id;

  return jsonb_build_object(
    'ok',true,
    'id',v_id,
    'business_case_key',btrim(p_business_case_key),
    'document_type',p_document_type,
    'source',v_source,
    'canonical_uri',v_uri,
    'revision_ref',nullif(btrim(p_revision_ref),''),
    'content_hash',lower(p_content_hash),
    'is_canonical',true
  );
end;
$$;
revoke all on function public.sis_register_knowledge_document_v2(text,text,text,text,text,text,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.sis_register_knowledge_document_v2(text,text,text,text,text,text,text,text,text,text,jsonb) to service_role;

insert into storage.buckets(id,name,public,file_size_limit)
values('sis-platform-artifacts','sis-platform-artifacts',false,52428800)
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,updated_at=now();

create table if not exists public.sis_storage_backends (
  backend_key text primary key,
  provider text not null check (provider in ('supabase_storage','customer_reference')),
  bucket_id text,
  visibility text not null check (visibility in ('private','external')),
  path_strategy text not null,
  status text not null default 'active' check (status in ('active','disabled','superseded')),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sis_storage_backends enable row level security;
revoke all on table public.sis_storage_backends from public, anon, authenticated;
grant select on table public.sis_storage_backends to service_role;

drop trigger if exists sis_storage_backends_set_updated_at on public.sis_storage_backends;
create trigger sis_storage_backends_set_updated_at
before update on public.sis_storage_backends
for each row execute function public.sis_set_updated_at();

insert into public.sis_storage_backends(backend_key,provider,bucket_id,visibility,path_strategy,status,metadata)
values(
  'supabase.sis_platform_artifacts','supabase_storage','sis-platform-artifacts','private','sha256_partitioned_v1','active',
  jsonb_build_object('object_path','sha256/<first2>/<next2>/<sha256>','overwrite_policy','content_addressed_same_hash_only','customer_business_data',false)
)
on conflict(backend_key) do update set
  provider=excluded.provider,bucket_id=excluded.bucket_id,visibility=excluded.visibility,path_strategy=excluded.path_strategy,
  status=excluded.status,metadata=excluded.metadata,updated_at=now();

create or replace function public.sis_storage_object_ref_v1(p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_hash text := lower(btrim(p_sha256));
  v_path text;
begin
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'INVALID_SHA256'; end if;
  v_path := 'sha256/' || substr(v_hash,1,2) || '/' || substr(v_hash,3,2) || '/' || v_hash;
  return jsonb_build_object(
    'provider','supabase_storage',
    'backend_key','supabase.sis_platform_artifacts',
    'bucket_id','sis-platform-artifacts',
    'object_path',v_path,
    'storage_ref','supabase://sis-platform-artifacts/' || v_path,
    'content_hash',v_hash
  );
end;
$$;
revoke all on function public.sis_storage_object_ref_v1(text) from public, anon, authenticated;
grant execute on function public.sis_storage_object_ref_v1(text) to service_role;

create table if not exists public.sis_platform_messages (
  id uuid primary key default gen_random_uuid(),
  business_case_id uuid references public.sis_business_cases(id) on delete restrict,
  work_item_id uuid references public.sis_work_items(id) on delete restrict,
  message_type text not null check (message_type in ('status','decision','action_required','handoff','notification','system')),
  sender_key text not null check (length(btrim(sender_key)) between 1 and 200),
  recipient_key text not null default 'sis' check (length(btrim(recipient_key)) between 1 and 200),
  subject text not null check (length(btrim(subject)) between 1 and 500),
  body text not null check (octet_length(body)<=16384),
  correlation_id uuid not null default gen_random_uuid(),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and pg_column_size(metadata)<=16384),
  created_at timestamptz not null default now()
);
create index if not exists sis_platform_messages_bc_created_idx on public.sis_platform_messages(business_case_id,created_at desc);
create index if not exists sis_platform_messages_wi_created_idx on public.sis_platform_messages(work_item_id,created_at desc);
create index if not exists sis_platform_messages_correlation_idx on public.sis_platform_messages(correlation_id);

alter table public.sis_platform_messages enable row level security;
revoke all on table public.sis_platform_messages from public, anon, authenticated, service_role;

create or replace function public.sis_block_platform_message_mutation_v1()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  raise exception 'sis_platform_messages_are_append_only';
end;
$$;

drop trigger if exists sis_platform_messages_no_update_delete on public.sis_platform_messages;
create trigger sis_platform_messages_no_update_delete
before update or delete on public.sis_platform_messages
for each row execute function public.sis_block_platform_message_mutation_v1();

drop trigger if exists sis_platform_messages_no_truncate on public.sis_platform_messages;
create trigger sis_platform_messages_no_truncate
before truncate on public.sis_platform_messages
for each statement execute function public.sis_block_platform_message_mutation_v1();

create or replace function public.sis_platform_message_publish_v1(
  p_message_type text,
  p_sender_key text,
  p_subject text,
  p_body text,
  p_business_case_key text default null,
  p_work_item_key text default null,
  p_recipient_key text default 'sis',
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_bc_id uuid;
  v_wi_id uuid;
  v_id uuid;
  v_corr uuid;
begin
  if p_message_type not in ('status','decision','action_required','handoff','notification','system') then raise exception 'INVALID_MESSAGE_TYPE'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or pg_column_size(p_metadata)>16384 then raise exception 'INVALID_MESSAGE_METADATA'; end if;
  if octet_length(coalesce(p_body,''))>16384 then raise exception 'MESSAGE_BODY_TOO_LARGE'; end if;

  if nullif(btrim(coalesce(p_business_case_key,'')),'') is not null then
    select id into v_bc_id from public.sis_business_cases where business_case_key=btrim(p_business_case_key);
    if v_bc_id is null then raise exception 'BUSINESS_CASE_NOT_FOUND'; end if;
  end if;
  if nullif(btrim(coalesce(p_work_item_key,'')),'') is not null then
    select id,business_case_id into v_wi_id,v_bc_id from public.sis_work_items where item_key=btrim(p_work_item_key);
    if v_wi_id is null then raise exception 'WORK_ITEM_NOT_FOUND'; end if;
    if nullif(btrim(coalesce(p_business_case_key,'')),'') is not null and not exists(
      select 1 from public.sis_business_cases where id=v_bc_id and business_case_key=btrim(p_business_case_key)
    ) then raise exception 'WORK_ITEM_BUSINESS_CASE_MISMATCH'; end if;
  end if;

  insert into public.sis_platform_messages(business_case_id,work_item_id,message_type,sender_key,recipient_key,subject,body,metadata)
  values(v_bc_id,v_wi_id,p_message_type,btrim(p_sender_key),btrim(coalesce(p_recipient_key,'sis')),btrim(p_subject),p_body,p_metadata)
  returning id,correlation_id into v_id,v_corr;

  return jsonb_build_object('ok',true,'id',v_id,'correlation_id',v_corr,'message_type',p_message_type,'created_at',now());
end;
$$;
revoke all on function public.sis_platform_message_publish_v1(text,text,text,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.sis_platform_message_publish_v1(text,text,text,text,text,text,text,jsonb) to service_role;

create or replace function public.sis_platform_message_list_v1(
  p_business_case_key text default null,
  p_work_item_key text default null,
  p_limit integer default 20
) returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,
    'business_case_key',bc.business_case_key,
    'work_item_key',wi.item_key,
    'message_type',m.message_type,
    'sender_key',m.sender_key,
    'recipient_key',m.recipient_key,
    'subject',m.subject,
    'body',m.body,
    'correlation_id',m.correlation_id,
    'metadata',m.metadata,
    'created_at',m.created_at
  ) order by m.created_at desc),'[]'::jsonb)
  from (
    select m.*
    from public.sis_platform_messages m
    left join public.sis_business_cases bc0 on bc0.id=m.business_case_id
    left join public.sis_work_items wi0 on wi0.id=m.work_item_id
    where (p_business_case_key is null or bc0.business_case_key=btrim(p_business_case_key))
      and (p_work_item_key is null or wi0.item_key=btrim(p_work_item_key))
    order by m.created_at desc
    limit greatest(1,least(coalesce(p_limit,20),100))
  ) m
  left join public.sis_business_cases bc on bc.id=m.business_case_id
  left join public.sis_work_items wi on wi.id=m.work_item_id;
$$;
revoke all on function public.sis_platform_message_list_v1(text,text,integer) from public, anon, authenticated;
grant execute on function public.sis_platform_message_list_v1(text,text,integer) to service_role;

alter function public.sis_chat_bootstrap_context_v1(text,integer) rename to sis_chat_bootstrap_context_legacy_v1;
revoke all on function public.sis_chat_bootstrap_context_legacy_v1(text,integer) from public, anon, authenticated, service_role;

create or replace function public.sis_chat_bootstrap_context_v1(
  p_business_case_key text default null,
  p_work_item_limit integer default 8
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_result jsonb;
  v_business_cases jsonb;
begin
  v_result := public.sis_chat_bootstrap_context_legacy_v1(p_business_case_key,p_work_item_limit);

  select coalesce(jsonb_agg(
    bc || jsonb_build_object(
      'canonical_documents',coalesce((
        select jsonb_agg(jsonb_build_object(
          'document_type',kd.document_type,
          'title',kd.title,
          'storage_provider',kd.source,
          'canonical_uri',kd.canonical_uri,
          'revision_ref',kd.revision_ref,
          'canonical_file_id',kd.canonical_file_id,
          'status',kd.status,
          'version',kd.version,
          'content_hash',kd.content_hash,
          'verified_at',kd.verified_at,
          'updated_at',kd.updated_at
        ) order by kd.verified_at desc nulls last,kd.updated_at desc)
        from public.sis_knowledge_documents kd
        where kd.business_case_id=(bc->>'id')::uuid
          and kd.is_canonical=true and kd.status='published'
      ),'[]'::jsonb)
    )
  ),'[]'::jsonb) into v_business_cases
  from jsonb_array_elements(coalesce(v_result->'business_cases','[]'::jsonb)) bc;

  v_result := jsonb_set(v_result,'{business_cases}',v_business_cases,true);
  v_result := jsonb_set(v_result,'{schema_version}',to_jsonb(3),true);
  v_result := jsonb_set(v_result,'{source_of_truth}',jsonb_build_object(
    'machine_state','supabase',
    'human_readable_projection','github',
    'binary_artifacts','supabase_storage',
    'legacy_knowledge_provider','google_drive',
    'google_drive_role','legacy_or_optional_connector',
    'chat_history_role','secondary_context'
  ),true);
  return v_result;
end;
$$;
revoke all on function public.sis_chat_bootstrap_context_v1(text,integer) from public, anon, authenticated;
grant execute on function public.sis_chat_bootstrap_context_v1(text,integer) to service_role;

create or replace function public.sis_chat_start_menu_v1(p_work_item_limit integer default 5)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_context jsonb;
  v_menu jsonb;
begin
  v_context := public.sis_chat_bootstrap_context_v1(null,greatest(1,least(coalesce(p_work_item_limit,5),12)));
  select coalesce(jsonb_agg(jsonb_build_object(
    'type','business_case',
    'business_case_key',bc->>'business_case_key',
    'label',bc->>'name',
    'status',bc->>'status',
    'priority',bc->>'priority',
    'progress',nullif(bc->>'progress','')::integer,
    'current_step',bc->>'current_step',
    'next_action',bc->>'next_action',
    'profiles',coalesce(bc->'profiles','[]'::jsonb),
    'summary_may_be_stale',coalesce((bc->>'summary_may_be_stale')::boolean,false),
    'canonical_document_missing',coalesce((bc->>'canonical_document_missing')::boolean,false)
  ) order by case bc->>'priority' when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
             (bc->>'progress')::integer desc nulls last,bc->>'name'),'[]'::jsonb)
  into v_menu
  from jsonb_array_elements(coalesce(v_context->'business_cases','[]'::jsonb)) bc;

  return jsonb_build_object(
    'schema_version',3,
    'intent','sis_start',
    'mode','read_only_navigation',
    'execution_allowed',false,
    'approval_granted',false,
    'task_start_allowed',false,
    'generated_at',now(),
    'prompt','Woran möchtest du arbeiten?',
    'menu',coalesce(v_menu,'[]'::jsonb) || jsonb_build_array(
      jsonb_build_object('type','platform','key','SIS_PLATFORM_CROSS_CUTTING','label','SIS Plattform / Übergreifend','description','Architektur, Umstrukturierung, Agenten, Berechtigungen, Observability und andere programmweite Themen.'),
      jsonb_build_object('type','new','key','NEW_BUSINESS_CASE','label','Neuer Business Case','description','Neuen Bedarf beschreiben; SIS ordnet ihn einem bestehenden Business Case zu oder schlägt einen neuen vor.')
    ),
    'warnings',coalesce(v_context->'warnings','[]'::jsonb),
    'source_of_truth',v_context->'source_of_truth',
    'guardrails',jsonb_build_object(
      'sis_token_is_navigation_only',true,
      'explicit_task_reference_required_for_execution',true,
      'explicit_execution_verb_required_for_execution',true,
      'business_case_selection_does_not_start_work',true,
      'platform_selection_does_not_start_work',true
    )
  );
end;
$$;
revoke all on function public.sis_chat_start_menu_v1(integer) from public, anon, authenticated;
grant execute on function public.sis_chat_start_menu_v1(integer) to service_role;

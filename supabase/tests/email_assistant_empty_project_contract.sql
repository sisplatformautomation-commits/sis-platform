-- Read-only contract for the supported data-less Email Assistant recovery path.
-- Expected to run after:
--   1) email_assistant_empty_project_prerequisites.sql
--   2) branch/main migration replay including historical email_assistant_profiles
--   3) email_assistant_empty_project_normalize
--   4) email_assistant_profile_table_lockdown

do $test$
declare
  v_email_id uuid;
  v_profile_count integer;
  v_menu jsonb;
  v_selection jsonb;
begin
  if not exists (
    select 1 from supabase_migrations.schema_migrations
    where name = 'email_assistant_profiles'
  ) then
    raise exception 'historical email_assistant_profiles migration is missing';
  end if;

  if not exists (
    select 1 from supabase_migrations.schema_migrations
    where name = 'email_assistant_empty_project_normalize'
  ) then
    raise exception 'email_assistant_empty_project_normalize migration is missing';
  end if;

  if not exists (
    select 1 from supabase_migrations.schema_migrations
    where name = 'email_assistant_profile_table_lockdown'
  ) then
    raise exception 'email_assistant_profile_table_lockdown migration is missing';
  end if;

  select id into v_email_id
  from public.sis_business_cases
  where business_case_key = 'EMAIL_ASSISTANT';

  if v_email_id is null then
    raise exception 'EMAIL_ASSISTANT is missing';
  end if;

  if not exists (
    select 1
    from public.sis_business_cases
    where id = v_email_id
      and status = 'blocked'
      and priority = 'normal'
      and progress = 0
      and coalesce((metadata ->> 'bootstrap_empty_project_seed_v1')::boolean, false)
      and coalesce((metadata ->> 'bootstrap_normalized_v1')::boolean, false)
      and not coalesce((metadata ->> 'mail_write_allowed')::boolean, false)
      and not coalesce((metadata ->> 'external_writes_enabled')::boolean, false)
      and not coalesce((metadata ->> 'prod_changes')::boolean, false)
  ) then
    raise exception 'EMAIL_ASSISTANT is not truthfully normalized for a data-less environment';
  end if;

  select count(*) into v_profile_count
  from public.sis_business_case_profiles
  where business_case_id = v_email_id
    and profile_key in ('gmbh', 'personal')
    and status = 'blocked'
    and priority = 'normal'
    and progress = 0
    and coalesce((metadata ->> 'bootstrap_empty_project_seed_v1')::boolean, false)
    and coalesce((metadata ->> 'bootstrap_normalized_v1')::boolean, false)
    and not coalesce((metadata ->> 'mail_write_allowed')::boolean, false)
    and not coalesce((metadata ->> 'external_writes_enabled')::boolean, false)
    and not coalesce((metadata ->> 'prod_changes')::boolean, false);

  if v_profile_count <> 2 then
    raise exception 'expected two blocked normalized Email Assistant profiles, got %', v_profile_count;
  end if;

  if exists (
    select 1 from public.sis_business_cases
    where business_case_key = 'GMBH_MAIL_ASSISTANT'
  ) then
    raise exception 'GMBH_MAIL_ASSISTANT should have been consolidated into EMAIL_ASSISTANT';
  end if;

  if not exists (
    select 1 from public.sis_business_cases
    where business_case_key = 'PERSONAL_MAIL_ASSISTANT'
      and status = 'archived'
      and coalesce((metadata ->> 'bootstrap_empty_project_seed_v1')::boolean, false)
      and coalesce((metadata ->> 'bootstrap_normalized_v1')::boolean, false)
  ) then
    raise exception 'Personal legacy shell is missing or not normalized';
  end if;

  if not exists (
    select 1 from public.sis_business_case_aliases
    where alias_key = 'GMBH_MAIL_ASSISTANT'
      and business_case_id = v_email_id
      and profile_key = 'gmbh'
  ) or not exists (
    select 1 from public.sis_business_case_aliases
    where alias_key = 'PERSONAL_MAIL_ASSISTANT'
      and business_case_id = v_email_id
      and profile_key = 'personal'
  ) then
    raise exception 'Email Assistant legacy aliases are incomplete';
  end if;

  v_selection := public.sis_chat_bootstrap_context_v1('GMBH_MAIL_ASSISTANT', 8) -> 'selection';
  if v_selection ->> 'business_case_key' <> 'EMAIL_ASSISTANT'
     or v_selection ->> 'profile_key' <> 'gmbh' then
    raise exception 'GMBH legacy alias bootstrap resolution failed';
  end if;

  v_selection := public.sis_chat_bootstrap_context_v1('PERSONAL_MAIL_ASSISTANT', 8) -> 'selection';
  if v_selection ->> 'business_case_key' <> 'EMAIL_ASSISTANT'
     or v_selection ->> 'profile_key' <> 'personal' then
    raise exception 'Personal legacy alias bootstrap resolution failed';
  end if;

  v_menu := public.sis_chat_start_menu_v1(5);
  if coalesce((v_menu ->> 'execution_allowed')::boolean, true)
     or coalesce((v_menu ->> 'approval_granted')::boolean, true)
     or coalesce((v_menu ->> 'task_start_allowed')::boolean, true) then
    raise exception 'SIS start menu unexpectedly authorizes execution';
  end if;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'sis_business_case_profiles'
      and c.relrowsecurity
  ) or not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'sis_business_case_aliases'
      and c.relrowsecurity
  ) then
    raise exception 'Email Assistant profile/alias tables must have RLS enabled';
  end if;

  if has_table_privilege('anon', 'public.sis_business_case_profiles', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     or has_table_privilege('authenticated', 'public.sis_business_case_profiles', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     or has_table_privilege('anon', 'public.sis_business_case_aliases', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     or has_table_privilege('authenticated', 'public.sis_business_case_aliases', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then
    raise exception 'anon/authenticated unexpectedly have direct profile/alias table privileges';
  end if;

  if not has_table_privilege('service_role', 'public.sis_business_case_profiles', 'SELECT')
     or has_table_privilege('service_role', 'public.sis_business_case_profiles', 'INSERT,UPDATE,DELETE,TRUNCATE')
     or not has_table_privilege('service_role', 'public.sis_business_case_aliases', 'SELECT')
     or has_table_privilege('service_role', 'public.sis_business_case_aliases', 'INSERT,UPDATE,DELETE,TRUNCATE') then
    raise exception 'service_role profile/alias privileges are not SELECT-only';
  end if;
end
$test$;

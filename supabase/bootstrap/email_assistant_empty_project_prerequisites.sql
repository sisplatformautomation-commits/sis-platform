-- Empty-project recovery prerequisite for the historical email_assistant_profiles migration.
-- Scope: DEV/TEST or other data-less bootstrap environments only.
--
-- Why this exists:
-- The already-applied production migration 20260810004840_email_assistant_profiles
-- expects legacy GMBH_MAIL_ASSISTANT and PERSONAL_MAIL_ASSISTANT rows. A Supabase
-- data-less branch does not copy those production rows, so replay stops before the
-- migration can complete. This seed supplies only the control-plane prerequisites
-- required by that historical migration. It does not copy customer data, secrets,
-- connections, deployments, documents, or runtime resources.
--
-- Run only after the base SIS tables exist and only while email_assistant_profiles
-- is still unapplied. The script is idempotent in that pre-migration state.

do $bootstrap$
declare
  v_program_id uuid;
begin
  if to_regclass('public.sis_programs') is null
     or to_regclass('public.sis_business_cases') is null then
    raise exception 'Base SIS control-plane tables are required before empty-project prerequisites can be seeded';
  end if;

  -- If the consolidation already exists, there is nothing to seed.
  if to_regclass('public.sis_business_case_profiles') is not null
     or exists (
       select 1
       from public.sis_business_cases
       where business_case_key = 'EMAIL_ASSISTANT'
     ) then
    return;
  end if;

  insert into public.sis_programs (
    program_key,
    name,
    description,
    status,
    metadata
  )
  values (
    'SIS_AUTOMATION_PLATFORM',
    'SIS Automation Platform',
    'SIS control-plane program created for a data-less migration replay.',
    'active',
    jsonb_build_object(
      'bootstrap_empty_project_seed_v1', true,
      'bootstrap_scope', 'control_plane_only',
      'synthetic', true
    )
  )
  on conflict (program_key) do nothing;

  select id
    into v_program_id
  from public.sis_programs
  where program_key = 'SIS_AUTOMATION_PLATFORM';

  if v_program_id is null then
    raise exception 'SIS_AUTOMATION_PLATFORM program could not be resolved';
  end if;

  insert into public.sis_business_cases (
    program_id,
    business_case_key,
    name,
    description,
    status,
    priority,
    progress,
    current_step,
    next_action,
    blocker,
    metadata
  )
  values (
    v_program_id,
    'GMBH_MAIL_ASSISTANT',
    'GmbH Mail Assistant',
    'Bootstrap prerequisite for historical Email Assistant profile consolidation. No mailbox or external connection is configured.',
    'blocked',
    'normal',
    0,
    'Empty-project bootstrap prerequisite only; no mailbox has been verified.',
    'Configure and verify the GmbH mailbox in DEV/TEST before activation.',
    'No mailbox or external connection is configured in this data-less environment.',
    jsonb_build_object(
      'bootstrap_empty_project_seed_v1', true,
      'bootstrap_scope', 'control_plane_only',
      'synthetic', true,
      'mail_write_allowed', false,
      'external_writes_enabled', false,
      'prod_changes', false
    )
  )
  on conflict (business_case_key) do nothing;

  insert into public.sis_business_cases (
    program_id,
    business_case_key,
    name,
    description,
    status,
    priority,
    progress,
    current_step,
    next_action,
    blocker,
    metadata
  )
  values (
    v_program_id,
    'PERSONAL_MAIL_ASSISTANT',
    'Personal Mail Assistant',
    'Bootstrap prerequisite for historical Email Assistant profile consolidation. No mailbox or external connection is configured.',
    'blocked',
    'normal',
    0,
    'Empty-project bootstrap prerequisite only; no mailbox has been verified.',
    'Configure and verify the personal mailbox and alert channel in DEV/TEST before activation.',
    'No mailbox or alert connection is configured in this data-less environment.',
    jsonb_build_object(
      'bootstrap_empty_project_seed_v1', true,
      'bootstrap_scope', 'control_plane_only',
      'synthetic', true,
      'mail_write_allowed', false,
      'external_writes_enabled', false,
      'prod_changes', false
    )
  )
  on conflict (business_case_key) do nothing;
end
$bootstrap$;

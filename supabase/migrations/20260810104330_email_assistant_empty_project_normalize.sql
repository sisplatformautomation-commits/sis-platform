-- Normalize the historical Email Assistant consolidation when it was reached
-- through the explicit empty-project bootstrap prerequisite.
--
-- This migration is intentionally marker-gated. On an environment that contains
-- real legacy Email Assistant data, it is a no-op. On a data-less bootstrap where
-- the prerequisite seed supplied synthetic legacy rows, it replaces the historical
-- migration's production-derived active/70 status with a truthful blocked/0 state.

do $migration$
declare
  v_email_id uuid;
begin
  if to_regclass('public.sis_business_case_profiles') is null then
    return;
  end if;

  select bc.id
    into v_email_id
  from public.sis_business_cases bc
  join public.sis_business_case_profiles p
    on p.business_case_id = bc.id
   and p.profile_key = 'gmbh'
  where bc.business_case_key = 'EMAIL_ASSISTANT'
    and coalesce((p.metadata ->> 'bootstrap_empty_project_seed_v1')::boolean, false)
  limit 1;

  if v_email_id is null then
    return;
  end if;

  update public.sis_business_case_profiles
  set status = 'blocked',
      priority = 'normal',
      progress = 0,
      current_step = case profile_key
        when 'gmbh' then 'Empty-project bootstrap complete; no GmbH mailbox has been verified.'
        when 'personal' then 'Empty-project bootstrap complete; no personal mailbox or alert channel has been verified.'
        else current_step
      end,
      next_action = case profile_key
        when 'gmbh' then 'Configure and verify the GmbH mailbox in DEV/TEST before activation.'
        when 'personal' then 'Configure and verify the personal mailbox and alert channel in DEV/TEST before activation.'
        else next_action
      end,
      blocker = case profile_key
        when 'gmbh' then 'No GmbH mailbox or external connection is configured in this data-less environment.'
        when 'personal' then 'No personal mailbox or alert connection is configured in this data-less environment.'
        else blocker
      end,
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'bootstrap_empty_project_seed_v1', true,
        'bootstrap_normalized_v1', true,
        'bootstrap_scope', 'control_plane_only',
        'synthetic', true,
        'mail_write_allowed', false,
        'external_writes_enabled', false,
        'prod_changes', false
      ),
      updated_at = now()
  where business_case_id = v_email_id
    and profile_key in ('gmbh', 'personal');

  update public.sis_business_cases
  set status = 'blocked',
      priority = 'normal',
      progress = 0,
      current_step = 'Empty-project bootstrap complete; Email Assistant profiles exist but no mailbox or external connection is verified.',
      next_action = 'Configure and verify a mailbox/profile in DEV/TEST before activation.',
      blocker = 'Email Assistant is intentionally blocked in this data-less environment until a mailbox/profile is configured and verified.',
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'bootstrap_empty_project_seed_v1', true,
        'bootstrap_normalized_v1', true,
        'bootstrap_scope', 'control_plane_only',
        'synthetic', true,
        'mail_write_allowed', false,
        'external_writes_enabled', false,
        'prod_changes', false
      ),
      updated_at = now()
  where id = v_email_id;

  update public.sis_business_cases
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'bootstrap_normalized_v1', true,
        'bootstrap_scope', 'control_plane_only',
        'synthetic', true
      ),
      updated_at = now()
  where business_case_key = 'PERSONAL_MAIL_ASSISTANT'
    and coalesce((metadata ->> 'bootstrap_empty_project_seed_v1')::boolean, false);
end
$migration$;

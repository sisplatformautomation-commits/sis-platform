create or replace function public.sis_chat_start_menu_v1(
  p_work_item_limit integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_context jsonb;
  v_menu jsonb;
begin
  v_context := public.sis_chat_bootstrap_context_v1(null, greatest(1, least(coalesce(p_work_item_limit, 5), 12)));

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', 'business_case',
    'business_case_key', bc->>'business_case_key',
    'label', bc->>'name',
    'status', bc->>'status',
    'priority', bc->>'priority',
    'progress', nullif(bc->>'progress', '')::integer,
    'current_step', bc->>'current_step',
    'next_action', bc->>'next_action',
    'summary_may_be_stale', coalesce((bc->>'summary_may_be_stale')::boolean, false),
    'canonical_document_missing', coalesce((bc->>'canonical_document_missing')::boolean, false)
  ) order by
    case bc->>'priority' when 'critical' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
    (bc->>'progress')::integer desc nulls last,
    bc->>'name'), '[]'::jsonb)
  into v_menu
  from jsonb_array_elements(coalesce(v_context->'business_cases', '[]'::jsonb)) bc;

  return jsonb_build_object(
    'schema_version', 1,
    'intent', 'sis_start',
    'mode', 'read_only_navigation',
    'execution_allowed', false,
    'approval_granted', false,
    'task_start_allowed', false,
    'generated_at', now(),
    'prompt', 'Woran möchtest du arbeiten?',
    'menu', coalesce(v_menu, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object(
        'type', 'platform',
        'key', 'SIS_PLATFORM_CROSS_CUTTING',
        'label', 'SIS Plattform / Übergreifend',
        'description', 'Architektur, Umstrukturierung, Agenten, Berechtigungen, Observability und andere programmweite Themen.'
      ),
      jsonb_build_object(
        'type', 'new',
        'key', 'NEW_BUSINESS_CASE',
        'label', 'Neuer Business Case',
        'description', 'Neuen Bedarf beschreiben; SIS ordnet ihn einem bestehenden Business Case zu oder schlägt einen neuen vor.'
      )
    ),
    'warnings', coalesce(v_context->'warnings', '[]'::jsonb),
    'source_of_truth', v_context->'source_of_truth',
    'guardrails', jsonb_build_object(
      'sis_token_is_navigation_only', true,
      'explicit_task_reference_required_for_execution', true,
      'explicit_execution_verb_required_for_execution', true,
      'business_case_selection_does_not_start_work', true,
      'platform_selection_does_not_start_work', true
    )
  );
end;
$function$;

revoke all on function public.sis_chat_start_menu_v1(integer) from public;
revoke all on function public.sis_chat_start_menu_v1(integer) from anon;
revoke all on function public.sis_chat_start_menu_v1(integer) from authenticated;
grant execute on function public.sis_chat_start_menu_v1(integer) to service_role;

comment on function public.sis_chat_start_menu_v1(integer) is
'Read-only SIS start/navigation contract. The token SIS means context hydration and menu display only; it never grants approval or starts a task.';

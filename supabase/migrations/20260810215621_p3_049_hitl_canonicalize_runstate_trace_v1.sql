create or replace function public.sis_agent_hitl_canonicalize_trace_v1()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_state jsonb;
  v_trace_id text;
  v_group_id text;
begin
  if new.sdk_state is not null and new.status='pending_approval' then
    begin
      v_state := new.sdk_state::jsonb;
    exception when others then
      raise exception 'HITL_SDK_STATE_NOT_JSON';
    end;
    v_trace_id := nullif(v_state->'trace'->>'id','');
    v_group_id := nullif(v_state->'trace'->>'group_id','');
    if v_trace_id is null then raise exception 'HITL_RUNSTATE_TRACE_REQUIRED'; end if;
    new.trace_id := v_trace_id;
    new.trace_group_id := v_group_id;
  end if;
  return new;
end;
$$;

revoke all on function public.sis_agent_hitl_canonicalize_trace_v1() from public, anon, authenticated;

drop trigger if exists sis_agent_hitl_canonicalize_trace_trg on public.sis_agent_hitl_runs;
create trigger sis_agent_hitl_canonicalize_trace_trg
before insert or update of sdk_state,status on public.sis_agent_hitl_runs
for each row execute function public.sis_agent_hitl_canonicalize_trace_v1();

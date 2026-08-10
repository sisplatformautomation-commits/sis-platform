-- P3-045 TEST finding: sis_job_events severity enum uses 'warn', not 'warning'.
create or replace function public.sis_agent_supervisor_recover_expired_leases_v1(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  r record;
  v_count integer:=0;
  v_retry boolean;
begin
  for r in
    select a.job_id,a.active_attempt_id,j.correlation_id,at.attempt_no,j.max_attempts,a.assigned_worker_key
    from public.sis_agent_job_assignments a
    join public.sis_jobs j on j.id=a.job_id
    join public.sis_job_attempts at on at.id=a.active_attempt_id
    where a.assignment_state='running' and j.status='running' and at.status='running'
      and at.lease_expires_at is not null and at.lease_expires_at<now()
    order by at.lease_expires_at
    for update of a,j,at skip locked
    limit greatest(1,least(coalesce(p_limit,20),100))
  loop
    v_retry:=r.attempt_no<r.max_attempts;
    update public.sis_job_attempts
      set status='timed_out',finished_at=now(),error_code='LEASE_EXPIRED',error_message='Worker lease expired before completion',updated_at=now()
      where id=r.active_attempt_id;
    if v_retry then
      update public.sis_jobs set status='retry_wait',available_at=now(),updated_at=now() where id=r.job_id;
      update public.sis_agent_job_assignments set assignment_state='rework',active_attempt_id=null,lease_token=null,updated_at=now() where job_id=r.job_id;
    else
      update public.sis_jobs set status='failed',finished_at=now(),updated_at=now() where id=r.job_id;
      update public.sis_agent_job_assignments set assignment_state='failed',lease_token=null,updated_at=now() where job_id=r.job_id;
    end if;
    insert into public.sis_job_events(job_id,attempt_id,event_type,source,severity,correlation_id,payload)
    values(r.job_id,r.active_attempt_id,'agent.lease.expired','sis.supervisor','warn',r.correlation_id,
      jsonb_build_object('worker_key',r.assigned_worker_key,'retry_scheduled',v_retry));
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('ok',true,'recovered',v_count);
end;
$$;
revoke all on function public.sis_agent_supervisor_recover_expired_leases_v1(integer) from public, anon, authenticated;
grant execute on function public.sis_agent_supervisor_recover_expired_leases_v1(integer) to service_role;

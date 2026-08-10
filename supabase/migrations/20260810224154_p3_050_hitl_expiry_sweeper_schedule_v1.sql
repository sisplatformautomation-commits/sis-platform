create extension if not exists pg_cron;

select cron.schedule(
  'sis-agent-hitl-expiry-sweeper-test',
  '*/5 * * * *',
  $$select public.sis_agent_hitl_sweep_expired_v1(now(),100);$$
);

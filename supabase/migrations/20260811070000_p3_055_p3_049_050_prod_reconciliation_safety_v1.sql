-- P3-055: production safety gate for the P3-049 -> P3-050 migration reconciliation.
-- The canonical P3-049/P3-050 migrations were designed and verified for DEV/TEST.
-- This follow-up keeps their schema/history available in PROD without activating a PROD HITL runtime.
-- In particular, it removes the TEST-only pg_cron sweeper created by the canonical P3-050 schedule migration.
-- The body is intentionally gated by the live P3-055 control-plane approval so later TEST syncs are no-ops.

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF to_regclass('public.sis_work_items') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.sis_work_items
       WHERE item_key = 'P3-055'
         AND metadata->>'approval_granted' = 'true'
         AND metadata->>'approved_scope' = 'P3-049 -> P3-050 PROD migration promotion'
         AND metadata->>'runtime_activation' = 'false'
     ) THEN

    IF to_regclass('public.sis_agent_hitl_runs') IS NULL THEN
      RAISE EXCEPTION 'P3_055_P3_049_PREREQUISITE_MISSING';
    END IF;

    IF to_regclass('public.sis_agent_hitl_effect_ledger') IS NULL THEN
      RAISE EXCEPTION 'P3_055_P3_050_PREREQUISITE_MISSING';
    END IF;

    -- The promoted historical stack remains non-PROD by contract.
    IF EXISTS (
      SELECT 1
      FROM public.sis_agent_hitl_runs
      WHERE environment_key = 'prod'
    ) THEN
      RAISE EXCEPTION 'P3_055_PROD_HITL_RUNTIME_MUST_REMAIN_INACTIVE';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.sis_agent_hitl_effect_ledger
      WHERE environment_key = 'prod'
    ) THEN
      RAISE EXCEPTION 'P3_055_PROD_HITL_EFFECT_RUNTIME_MUST_REMAIN_INACTIVE';
    END IF;

    -- Remove the TEST-only scheduler if the canonical P3-050 migration created it.
    FOR v_job_id IN
      SELECT jobid
      FROM cron.job
      WHERE jobname = 'sis-agent-hitl-expiry-sweeper-test'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;

    IF EXISTS (
      SELECT 1
      FROM cron.job
      WHERE jobname = 'sis-agent-hitl-expiry-sweeper-test'
    ) THEN
      RAISE EXCEPTION 'P3_055_TEST_HITL_SWEEPER_STILL_ACTIVE';
    END IF;
  END IF;
END;
$$;

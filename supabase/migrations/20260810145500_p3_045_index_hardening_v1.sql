-- P3-045 advisor cleanup for covering foreign-key indexes.
create index if not exists sis_agent_job_approvals_event_idx on public.sis_agent_job_approvals(approval_event_id) where approval_event_id is not null;
create index if not exists sis_agent_assignments_active_attempt_idx on public.sis_agent_job_assignments(active_attempt_id) where active_attempt_id is not null;
create index if not exists sis_agent_reviews_reviewer_created_idx on public.sis_agent_reviews(reviewer_worker_key,created_at desc);

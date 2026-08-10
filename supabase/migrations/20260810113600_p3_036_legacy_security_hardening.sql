-- P3-036 legacy security hardening
-- TEST-validated before promotion. Restrict legacy SECURITY DEFINER helper functions
-- to service_role/postgres and pin sanitizer search_path.

revoke execute on function public.asog_make_create_logged_image_regression(text,text) from public, anon, authenticated;
revoke execute on function public.asog_make_create_safe_image_regression(text,text) from public, anon, authenticated;
revoke execute on function public.asog_make_execution_detail(bigint,text) from public, anon, authenticated;
revoke execute on function public.asog_make_logged_regression_action(text,bigint) from public, anon, authenticated;
revoke execute on function public.asog_make_read_regression_audit(text) from public, anon, authenticated;
revoke execute on function public.asog_make_safe_image_regression_action(text,bigint) from public, anon, authenticated;
revoke execute on function public.sis_gmbh_mail_action_plan_dev(text) from public, anon, authenticated;
revoke execute on function public.sis_make_create_gmbh_mail_fixture_runner_dev() from public, anon, authenticated;
revoke execute on function public.sis_make_create_gmbh_mail_inbox_list_webhook_dev() from public, anon, authenticated;
revoke execute on function public.sis_make_create_gmbh_mail_trash_executor_dev() from public, anon, authenticated;
revoke execute on function public.sis_make_drive_utility_action(text) from public, anon, authenticated;
revoke execute on function public.sis_make_gmbh_gmail_execution_log_dev(text) from public, anon, authenticated;
revoke execute on function public.sis_make_gmbh_gmail_module_log_detail_dev(integer,text) from public, anon, authenticated;
revoke execute on function public.sis_make_gmbh_mail_classification_execution_detail_dev(text) from public, anon, authenticated;
revoke execute on function public.sis_make_prepare_gmbh_mail_classification_dev() from public, anon, authenticated;
revoke execute on function public.sis_make_run_gmbh_mail_classification_dev(text) from public, anon, authenticated;
revoke execute on function public.sis_make_run_gmbh_mail_fixture_dev(text,text,text,text,text,text,text) from public, anon, authenticated;

alter function public.sis_sanitize_make_blueprint(jsonb,text)
  set search_path = pg_catalog, public;

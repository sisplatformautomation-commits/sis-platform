-- SIS Runtime Foundation v1.2
-- Keep service_role on the gateway RPC path by removing direct table mutation rights.
-- SECURITY DEFINER runtime functions execute as the function owner and remain usable.

revoke all on table public.sis_runtime_environments from service_role;
revoke all on table public.sis_runtime_access_sessions from service_role;
revoke all on table public.sis_runtime_write_approvals from service_role;

grant select on table public.sis_runtime_environments to service_role;
grant select on table public.sis_runtime_access_sessions to service_role;
grant select on table public.sis_runtime_write_approvals to service_role;

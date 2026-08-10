-- The historical email_assistant_profiles migration grants service_role SELECT,
-- but Supabase default table privileges can leave direct DML privileges in place.
-- Keep the intended read-only direct surface; migrations remain owner-controlled.

revoke all on table public.sis_business_case_profiles from service_role;
grant select on table public.sis_business_case_profiles to service_role;

revoke all on table public.sis_business_case_aliases from service_role;
grant select on table public.sis_business_case_aliases to service_role;

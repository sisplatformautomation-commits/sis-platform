-- TEST advisor finding: trigger-only SECURITY DEFINER function must not be callable through exposed RPC roles.
revoke all on function public.sis_block_platform_message_mutation_v1() from public, anon, authenticated, service_role;

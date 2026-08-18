-- Revoking from PUBLIC is not enough on Supabase.
--
-- The project carries `alter default privileges in schema public grant execute
-- on functions to anon, authenticated`, so every new function gets an EXPLICIT
-- grant to the `anon` role as well as the implicit one to PUBLIC. Revoking
-- PUBLIC leaves the explicit one standing, and `has_function_privilege('anon',
-- ...)` still answers true — which is exactly what the check after the previous
-- migration showed, and the reason there are two files here rather than one.
--
-- The lesson is worth keeping: on this project, locking a function down means
-- naming `anon` and `authenticated`, not just `public`. Every revocation in the
-- earlier migrations that actually worked — `is_pro_account`,
-- `profile_is_autohidden`, `pilot_live_readable` — named all three.

revoke all on function public.pilot_live_clear() from anon;
revoke all on function public.pilot_live_following(integer) from anon;
revoke all on function public.pilot_landing_board(integer, integer) from anon;
revoke all on function public.record_terms_acceptance(integer, timestamptz) from anon;
revoke all on function public.my_terms_acceptance() from anon;

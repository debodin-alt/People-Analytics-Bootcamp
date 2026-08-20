-- Actually close anonymous access.
--
-- The previous migration revoked EXECUTE from `anon` and it made no
-- difference: CREATE FUNCTION grants EXECUTE to PUBLIC by default in
-- Postgres, and anon is a member of PUBLIC, so the privilege was still
-- arriving by the other path. Every measure remained callable with the
-- publishable key (verified: HTTP 200 after the revoke).
--
-- This is a good argument for testing a lockdown rather than asserting
-- it. The fix is to revoke from PUBLIC as well, then grant back to
-- authenticated explicitly — and to pin the default so functions created
-- later do not silently re-open the same hole.

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'metrics'
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- Functions created from here on must not be world-executable either.
alter default privileges in schema metrics revoke execute on functions from public;

-- The schema itself: anon has no reason to resolve names in it.
revoke usage on schema metrics from anon;
grant usage on schema metrics to authenticated;

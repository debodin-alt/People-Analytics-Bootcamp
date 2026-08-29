-- A public entry point for ingestion, because `staging` is not exposed.
--
-- PostgREST serves `public`, `metrics` and `graphql_public` only, so the
-- upload screen's calls into `staging` returned 406 for every function.
-- Found by exercising the path the browser actually uses rather than the
-- one the psql session can reach — the same distinction that made the
-- earlier grant fix necessary.
--
-- The fix is a thin public API rather than exposing the schema. Staging is
-- machinery: fifteen writable mirrors of the people tables, and nothing
-- outside the load path has any business addressing them. Exposing the
-- schema to reach six functions would put those tables one grant away from
-- the internet forever, in exchange for saving this file. The wrappers add
-- no logic and no privilege — each one is a call, and every check still
-- happens in the function underneath.

create or replace function public.ingest_target_schema()
returns table (table_name text, columns text[])
language sql stable security invoker set search_path = ''
as $$ select * from staging.target_schema(); $$;

create or replace function public.ingest_reset()
returns void
language sql volatile security invoker set search_path = ''
as $$ select staging.reset(); $$;

create or replace function public.ingest_stage_rows(p_table text, p_rows jsonb)
returns integer
language sql volatile security invoker set search_path = ''
as $$ select staging.stage_rows(p_table, p_rows); $$;

create or replace function public.ingest_staged_summary()
returns table (table_name text, rows_staged integer)
language sql stable security invoker set search_path = ''
as $$ select * from staging.staged_summary(); $$;

create or replace function public.ingest_validate(p_max_failures integer default 500)
returns table (table_name text, source_row integer, rule text, detail text)
language sql volatile security invoker set search_path = ''
as $$ select * from staging.validate_load(p_max_failures); $$;

create or replace function public.ingest_blockers()
returns table (blocker text, detail text)
language sql stable security invoker set search_path = ''
as $$ select * from staging.promotion_blockers(); $$;

create or replace function public.ingest_promote(p_file_names text[], p_note text default null)
returns table (data_load_id text, tables_replaced text[], row_counts jsonb)
language sql volatile security invoker set search_path = ''
as $$ select * from staging.promote_load(p_file_names, p_note); $$;

comment on function public.ingest_promote(text[], text) is
  'Public entry point for promotion. SECURITY INVOKER on purpose: it grants nothing of its own, and the capability check, validation and refusal all remain in staging.promote_load beneath it.';

-- CREATE FUNCTION grants EXECUTE to PUBLIC by default, and anon inherits
-- it — the defect fixed once already in 20260820000017. Revoke, then grant
-- deliberately.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'ingest\_%'
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- What the uploader is allowed to load into, and the columns each table
-- accepts.
--
-- The upload screen needs this to match sheets to tables and headers to
-- columns. It reads it from the database rather than carrying its own copy
-- for the same reason the metric catalog and the filter vocabulary are
-- read rather than hardcoded: a second list would drift, and a loader
-- working from a stale column list silently drops the column that was
-- added last week.

create or replace function staging.target_schema()
returns table (table_name text, columns text[])
language sql stable security definer set search_path = ''
as $$
  select
    t.tablename::text,
    array_agg(c.column_name::text order by c.ordinal_position)
  from pg_catalog.pg_tables t
  join information_schema.columns c
    on c.table_schema = 'public' and c.table_name = t.tablename
  where t.schemaname = 'staging'
  group by t.tablename
  order by t.tablename;
$$;

comment on function staging.target_schema() is
  'The loadable tables and the columns each accepts, read from the live schema so the upload screen cannot work from a stale column list.';

grant execute on function staging.target_schema() to authenticated;

-- Writing into staging, without granting anyone a table.
--
-- Every other client path in this platform goes through a SECURITY DEFINER
-- function and no table is reachable directly — that was the fix for the
-- original data-exposure defect, and ingestion should not be the exception
-- that reintroduces it. Granting INSERT on staging to `authenticated`
-- would hand every signed-in user a writable mirror of the employee table,
-- protected only by RLS policies that would have to be written and kept
-- correct for fifteen tables.
--
-- So rows arrive as JSON through one gated function. The table name is
-- checked against pg_tables rather than interpolated, so it cannot be used
-- to reach anything outside the staging schema, and jsonb_populate_recordset
-- does the column mapping — a key the table does not have is ignored rather
-- than becoming a syntax error, which is the right behaviour for a
-- spreadsheet carrying an extra column nobody needs.

create or replace function staging.stage_rows(p_table text, p_rows jsonb)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare v_n integer;
begin
  perform metrics.require_capability('governance');

  if not exists (
    select 1 from pg_catalog.pg_tables
    where schemaname = 'staging' and tablename = p_table
  ) then
    raise exception 'Unknown staging table: %', p_table
      using hint = 'The uploaded sheet does not correspond to a table in this platform.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be a JSON array.';
  end if;

  execute format(
    'insert into staging.%I select * from jsonb_populate_recordset(null::staging.%I, $1)',
    p_table, p_table) using p_rows;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function staging.stage_rows(text, jsonb) is
  'Appends rows to a staging table from JSON, gated on `governance`. The only write path into staging: no client holds a table grant, so the schema cannot be reached except through this function. Unknown keys in a row are ignored, so an extra spreadsheet column is not an error.';

create or replace function staging.reset()
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare r record;
begin
  perform metrics.require_capability('governance');
  for r in select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging'
  loop
    execute format('delete from staging.%I', r.t);
  end loop;
end;
$$;

comment on function staging.reset() is
  'Empties every staging table. Called before an upload so a half-finished previous attempt cannot be promoted along with the new one.';

/**
 * What is currently staged, for the upload screen to show back before
 * anyone promotes anything. Reporting from the tables rather than from
 * what the browser believes it sent is the point: those two disagreeing
 * is precisely the situation worth catching before a promote.
 */
create or replace function staging.staged_summary()
returns table (table_name text, rows_staged integer)
language plpgsql stable security definer set search_path = ''
as $$
declare r record; v_n integer;
begin
  perform metrics.require_capability('governance');
  for r in select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging' order by 1
  loop
    execute format('select count(*) from staging.%I', r.t) into v_n;
    if v_n > 0 then
      table_name := r.t; rows_staged := v_n; return next;
    end if;
  end loop;
end;
$$;

comment on function staging.staged_summary() is
  'Row counts currently held in staging, read from the tables themselves rather than from what the uploader thinks it sent.';

grant execute on function staging.stage_rows(text, jsonb) to authenticated;
grant execute on function staging.reset() to authenticated;
grant execute on function staging.staged_summary() to authenticated;

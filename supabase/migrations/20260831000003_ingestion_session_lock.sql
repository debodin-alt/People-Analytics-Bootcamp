-- Concurrent-upload race condition (code review, 2026-08-31).
--
-- Staging tables are shared and global: nothing before this stopped two
-- admins from uploading at the same time. Admin A's reset() mid-upload
-- could wipe Admin B's freshly-staged rows, or a promote could commit a
-- mixture of both admins' files as one load with no way to tell which
-- rows came from which.
--
-- Fixed with a lock, not per-row scoping. Uploads are a rare, admin-only,
-- one-at-a-time operation, so serializing them is the right shape of fix
-- — adding a session column to all fifteen staging tables (and every
-- query that touches them) would be a much larger change to protect
-- against something that should simply not happen concurrently at all.
--
-- The lock table lives in `metrics` (identity/session plumbing), not
-- `staging`, so it is never swept up by the "loop over every staging
-- table" queries in reset(), staged_summary() and promote_load()'s own
-- cleanup — all three iterate `pg_tables where schemaname = 'staging'`,
-- and a lock table sitting in that schema would be misreported as staged
-- data, or wiped/re-created as a side effect of an unrelated reset.
--
-- 20-minute expiry so an abandoned tab (closed mid-upload, never reaching
-- promote or a fresh reset) doesn't lock everyone else out indefinitely;
-- the same user can always re-acquire their own lock immediately.

create table if not exists metrics.load_lock (
  id boolean primary key default true,
  locked_by uuid not null,
  locked_by_label text,
  locked_at timestamptz not null default now(),
  constraint load_lock_singleton check (id)
);

comment on table metrics.load_lock is
  'At most one row: who currently holds the ingestion upload lock, and since when. Deliberately outside the `staging` schema — see the migration header.';

create or replace function metrics.acquire_load_lock()
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_holder uuid;
  v_label text;
  v_since timestamptz;
begin
  perform metrics.require_capability('governance');

  select locked_by, locked_by_label, locked_at into v_holder, v_label, v_since
  from metrics.load_lock where id = true;

  if v_holder is not null and v_holder <> auth.uid()
     and v_since > now() - interval '20 minutes' then
    raise exception 'Another upload is already in progress (started by % at %). Wait for it to finish, or try again in 20 minutes if it was abandoned.',
      coalesce(v_label, v_holder::text), v_since
      using errcode = 'lock_not_available';
  end if;

  insert into metrics.load_lock (id, locked_by, locked_by_label, locked_at)
  values (
    true,
    auth.uid(),
    (select coalesce(u.email, a.auth_user_id::text) from public.app_users a
       left join auth.users u on u.id = a.auth_user_id
       where a.auth_user_id = auth.uid()),
    now()
  )
  on conflict (id) do update
    set locked_by = excluded.locked_by,
        locked_by_label = excluded.locked_by_label,
        locked_at = excluded.locked_at;
end;
$$;

comment on function metrics.acquire_load_lock() is
  'Called by staging.reset() at the start of an upload. Refuses if a different, non-expired session already holds the lock; otherwise (re-)acquires it for the caller.';

create or replace function metrics.assert_load_lock()
returns void
language plpgsql stable security definer set search_path = ''
as $$
declare v_holder uuid; v_since timestamptz;
begin
  select locked_by, locked_at into v_holder, v_since from metrics.load_lock where id = true;
  if v_holder is null or v_holder <> auth.uid() or v_since <= now() - interval '20 minutes' then
    raise exception 'No active upload session for this account (it may have expired or been superseded by another admin). Start over from the beginning of the upload screen.'
      using errcode = 'lock_not_available';
  end if;
end;
$$;

comment on function metrics.assert_load_lock() is
  'Called by staging.stage_rows() and staging.promote_load() to confirm the caller still holds the lock they acquired via reset(), so a second admin cannot write into or promote a session they never started.';

create or replace function metrics.release_load_lock()
returns void
language sql volatile security definer set search_path = ''
as $$
  delete from metrics.load_lock where id = true;
$$;

comment on function metrics.release_load_lock() is
  'Called at the end of a successful promote_load() so the next upload does not have to wait out the 20-minute expiry.';

grant execute on function metrics.acquire_load_lock() to authenticated;
grant execute on function metrics.assert_load_lock() to authenticated;
grant execute on function metrics.release_load_lock() to authenticated;

-- ---------------------------------------------------------------------
-- Wire the lock into the three write paths.
-- ---------------------------------------------------------------------

create or replace function staging.stage_rows(p_table text, p_rows jsonb)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare v_n integer;
begin
  perform metrics.require_capability('governance');
  perform metrics.assert_load_lock();

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

create or replace function staging.reset()
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare r record;
begin
  perform metrics.require_capability('governance');
  perform metrics.acquire_load_lock();

  for r in select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging'
  loop
    execute format('delete from staging.%I', r.t);
  end loop;
end;
$$;

create or replace function staging.promote_load(
  p_file_names text[],
  p_note text default null
)
returns table (data_load_id text, tables_replaced text[], row_counts jsonb)
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_failures integer;
  v_blockers integer;
  v_first_blocker text;
  v_load_id text;
  v_tables text[] := '{}';
  v_counts jsonb := '{}'::jsonb;
  v_cols text;
  v_n integer;
  r record;
  v_by text;
begin
  perform metrics.require_capability('governance');
  perform metrics.assert_load_lock();

  -- Refuse on any invalid row. All-or-nothing means the decision is taken
  -- before anything is written, not discovered halfway through (ING-8).
  select count(*) into v_failures from staging.validate_load(1);
  if v_failures > 0 then
    raise exception 'This load has validation failures. Fix them and re-validate before promoting.'
      using errcode = 'check_violation';
  end if;

  select count(*), min(detail) into v_blockers, v_first_blocker
  from staging.promotion_blockers();
  if v_blockers > 0 then
    raise exception 'Cannot promote: %', v_first_blocker
      using errcode = 'foreign_key_violation';
  end if;

  -- Self-referencing managers, and the account mapping above, are judged
  -- on the transaction's end state rather than statement by statement.
  set constraints all deferred;

  -- Delete children before parents, insert parents before children. The
  -- order comes from the foreign keys themselves (staging.table_load_order),
  -- so a new table cannot be placed wrongly by hand.
  for r in
    select o.table_name as t
    from staging.table_load_order() o
    order by o.depth desc, o.table_name
  loop
    execute format('select count(*) from staging.%I', r.t) into v_n;
    continue when v_n = 0;
    execute format('delete from public.%I', r.t);
  end loop;

  for r in
    select o.table_name as t
    from staging.table_load_order() o
    order by o.depth, o.table_name
  loop
    execute format('select count(*) from staging.%I', r.t) into v_n;
    continue when v_n = 0;

    -- Column list from production, which excludes _source_row without
    -- having to name it: staging carries it, public does not.
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into v_cols
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = r.t;

    execute format('insert into public.%I (%s) select %s from staging.%I',
                   r.t, v_cols, v_cols, r.t);

    v_tables := v_tables || r.t;
    v_counts := v_counts || jsonb_build_object(r.t, v_n);
  end loop;

  if array_length(v_tables, 1) is null then
    raise exception 'Nothing staged — upload a file before promoting.'
      using errcode = 'no_data_found';
  end if;

  select coalesce(u.email, a.auth_user_id::text) into v_by
  from public.app_users a
  left join auth.users u on u.id = a.auth_user_id
  where a.auth_user_id = auth.uid();

  v_load_id := 'load_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS')
               || '_' || substr(md5(random()::text), 1, 6);

  insert into public.data_loads (data_load_id, source_type, file_names, row_counts,
                                 validation_summary, loaded_by)
  values (v_load_id, 'file_upload', coalesce(p_file_names, '{}'), v_counts,
          coalesce(p_note, format('%s tables, %s rows, no validation failures',
                                  array_length(v_tables, 1),
                                  (select sum(value::int) from jsonb_each_text(v_counts)))),
          coalesce(v_by, 'unknown'));

  -- Derived aggregates are part of the load, not a step someone remembers
  -- to run afterwards (ING-10). A promote that left the materialized views
  -- stale would report yesterday's headcount against today's data.
  perform metrics.refresh_aggregates();

  -- Staging is a landing area, not a record. Leaving it populated makes the
  -- next upload ambiguous — is this row from the new file or the last one?
  for r in select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging'
  loop
    execute format('delete from staging.%I', r.t);
  end loop;

  perform metrics.release_load_lock();

  return query select v_load_id, v_tables, v_counts;
end;
$$;

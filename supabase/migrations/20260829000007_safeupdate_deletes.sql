-- Unqualified DELETE is refused through the API role.
--
-- Found by calling the ingestion functions the way the browser does rather
-- than the way psql does. Supabase runs the PostgREST role with safeupdate
-- enabled, which rejects any DELETE or UPDATE without a WHERE clause:
--
--   ERROR 21000: DELETE requires a WHERE clause
--
-- Every psql test passed, because psql is not that role. Through the API,
-- reset() failed outright and promote_load() would have failed at its first
-- delete — that is, the upload screen would have been broken on its first
-- real use while the suite stayed green.
--
-- Every whole-table delete in this path now appends `where true`, which
-- satisfies the guard without changing what the statements do.
-- The guard is worth keeping rather than disabling: it exists to stop an
-- accidental unbounded delete, and this path deletes whole production
-- tables for a living.
--
-- Bodies are taken from pg_get_functiondef and patched, not retyped.


CREATE OR REPLACE FUNCTION staging.promote_load(p_file_names text[], p_note text DEFAULT NULL::text)
 RETURNS TABLE(data_load_id text, tables_replaced text[], row_counts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    execute format('delete from public.%I where true', r.t);
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
    execute format('delete from staging.%I where true', r.t);
  end loop;

  return query select v_load_id, v_tables, v_counts;
end;
$function$;

CREATE OR REPLACE FUNCTION staging.reset()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  perform metrics.require_capability('governance');
  for r in select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging'
  loop
    execute format('delete from staging.%I where true', r.t);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION staging.validate_load(p_max_failures integer DEFAULT 500)
 RETURNS TABLE(table_name text, source_row integer, rule text, detail text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r record;
  v_sql text;
  v_count integer;
begin
  perform metrics.require_capability('governance');

  -- pg_temp, spelled out. search_path is empty on purpose (a SECURITY
  -- DEFINER function with a mutable search_path is a privilege-escalation
  -- hole), which means every name here must be qualified — including the
  -- temp table, which otherwise fails to resolve at runtime rather than at
  -- creation.
  create temp table if not exists _failures (
    table_name text, source_row integer, rule text, detail text
  );
  delete from pg_temp._failures where true;

  for r in
    select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging' order by 1
  loop
    -- Skip tables nobody staged. A partial upload is legitimate: someone
    -- refreshing only the engagement survey should not be told the
    -- requisitions they never touched are missing.
    execute format('select count(*) from staging.%I', r.t) into v_count;
    continue when v_count = 0;

    -- 1. Required columns. NOT NULL in public, stripped in staging so bad
    --    rows can be collected and reported together rather than rejected
    --    one at a time by the first insert that fails.
    for v_sql in
      select format(
        'insert into pg_temp._failures
         select %L, s._source_row, %L, %L
         from staging.%I s where s.%I is null',
        r.t, 'required', 'Column "' || c.column_name || '" is required but empty',
        r.t, c.column_name)
      from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = r.t and c.is_nullable = 'NO'
    loop
      execute v_sql;
    end loop;

    -- 2. CHECK constraints, evaluated as production evaluates them.
    --    pg_get_constraintdef yields "CHECK ((expr))"; the expression is
    --    reused verbatim, staging having the same column names. A CHECK
    --    over a column the file omitted evaluates to NULL rather than
    --    false, so it surfaces above as a missing required column instead
    --    of as a confusing value error.
    for v_sql in
      select format(
        'insert into pg_temp._failures
         select %L, s._source_row, %L, %L
         from staging.%I s where not (%s)',
        r.t, 'value', 'Fails ' || con.conname || ': ' || pg_catalog.pg_get_constraintdef(con.oid),
        r.t, substring(pg_catalog.pg_get_constraintdef(con.oid) from 7))
      from pg_catalog.pg_constraint con
      join pg_catalog.pg_class cl on cl.oid = con.conrelid
      join pg_catalog.pg_namespace n on n.oid = cl.relnamespace
      where n.nspname = 'public' and cl.relname = r.t and con.contype = 'c'
    loop
      execute v_sql;
    end loop;

    -- 3. Primary key duplicated inside the file itself.
    for v_sql in
      select format(
        'insert into pg_temp._failures
         select %L, s._source_row, %L, %L || (%s)::text
         from staging.%I s
         where exists (select 1 from staging.%I d
                       where (%s) is not distinct from (%s)
                         and d._source_row is distinct from s._source_row)',
        r.t, 'duplicate', 'Duplicate key: ',
        pk.cols_s, r.t, r.t, pk.cols_d, pk.cols_s)
      from (
        select
          string_agg(format('s.%I', a.attname), ', ' order by k.ord) as cols_s,
          string_agg(format('d.%I', a.attname), ', ' order by k.ord) as cols_d
        from pg_catalog.pg_constraint con
        join pg_catalog.pg_class cl on cl.oid = con.conrelid
        join pg_catalog.pg_namespace n on n.oid = cl.relnamespace
        cross join lateral unnest(con.conkey) with ordinality as k(att, ord)
        join pg_catalog.pg_attribute a on a.attrelid = cl.oid and a.attnum = k.att
        where n.nspname = 'public' and cl.relname = r.t and con.contype = 'p'
      ) pk
      where pk.cols_s is not null
    loop
      execute v_sql;
    end loop;
  end loop;

  -- 4. Foreign keys, resolved against production *and* the rest of this
  --    load. A file introducing a new manager and their reports together
  --    is valid; checking only against public would reject it. Where the
  --    parent table is not part of this upload, only public is consulted —
  --    building that clause conditionally rather than letting a missing
  --    staging table raise and silently skip the whole rule.
  for v_sql in
    select format(
      'insert into pg_temp._failures
       select %L, s._source_row, %L, %L || s.%I::text
       from staging.%I s
       where s.%I is not null
         and not exists (select 1 from public.%I p where p.%I = s.%I)
         %s',
      child.relname, 'reference',
      'No such ' || parent.relname || ': ', ca.attname,
      child.relname, ca.attname,
      parent.relname, pa.attname, ca.attname,
      case when parent_staged.tablename is null then ''
           else format('and not exists (select 1 from staging.%I t where t.%I = s.%I)',
                       parent.relname, pa.attname, ca.attname)
      end)
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class child on child.oid = con.conrelid
    join pg_catalog.pg_class parent on parent.oid = con.confrelid
    join pg_catalog.pg_namespace n on n.oid = child.relnamespace
    join pg_catalog.pg_attribute ca on ca.attrelid = child.oid and ca.attnum = con.conkey[1]
    join pg_catalog.pg_attribute pa on pa.attrelid = parent.oid and pa.attnum = con.confkey[1]
    join pg_catalog.pg_tables child_staged
      on child_staged.schemaname = 'staging' and child_staged.tablename = child.relname
    left join pg_catalog.pg_tables parent_staged
      on parent_staged.schemaname = 'staging' and parent_staged.tablename = parent.relname
    where n.nspname = 'public'
      and con.contype = 'f'
      and array_length(con.conkey, 1) = 1   -- composite FKs are left to the promote
  loop
    execute v_sql;
  end loop;

  return query
    select f.table_name, f.source_row, f.rule, f.detail
    from pg_temp._failures f
    order by f.table_name, f.source_row nulls last
    limit p_max_failures;
end;
$function$;

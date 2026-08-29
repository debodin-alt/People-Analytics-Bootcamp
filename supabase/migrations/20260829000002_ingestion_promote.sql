-- Promotion: staging -> production, one transaction, all or nothing
-- (ING-8, ING-9), with the aggregate refresh inside it (ING-10).
--
-- Two things surfaced only by trying to write this, both of which would
-- have failed on a real upload:
--
--   app_users.employee_id references employees with ON DELETE NO ACTION.
--   Promotion replaces whole tables, so the delete step would have been
--   rejected outright for any account mapped to an employee — which is
--   every account that matters. The constraint is made deferrable here so
--   the delete-then-insert pair is judged on its end state, and a
--   pre-flight check reports the real problem (an extract that drops
--   someone who has a dashboard login) as a sentence rather than as a
--   foreign key error at commit.
--
--   employees.manager_employee_id is self-referencing. Rows arrive in file
--   order, so a report can precede their manager. Those constraints were
--   already deferrable — this defers them explicitly rather than relying
--   on the file happening to be sorted.
--
-- Whole-table replacement is the right model for a periodic HR extract:
-- the file is the current state of the workforce, and an upsert would
-- leave departed employees in place forever. Only tables that actually
-- received rows are replaced, so refreshing just the engagement survey
-- cannot empty the requisitions nobody touched.

alter table public.app_users
  alter constraint app_users_employee_id_fkey deferrable initially immediate;

-- ---------------------------------------------------------------------
-- Pre-flight: what would break, as distinct from what is invalid.
--
-- Kept separate from validate_load because it answers a different
-- question. validate_load asks "are these rows well formed"; this asks
-- "would replacing production with them break something that is not in
-- the file". A user needs both answers before pressing the button, and
-- conflating them makes the message worse.
-- ---------------------------------------------------------------------

create or replace function staging.promotion_blockers()
returns table (blocker text, detail text)
language plpgsql stable security definer set search_path = ''
as $$
declare v_staged_employees integer;
begin
  perform metrics.require_capability('governance');

  select count(*) into v_staged_employees from staging.employees;
  if v_staged_employees = 0 then
    return;   -- employees not part of this load; nothing can be orphaned
  end if;

  return query
    select
      'account would lose its employee'::text,
      format('%s is mapped to employee %s, who is not in the uploaded file. '
             || 'Add them to the extract, or clear the mapping before loading.',
             coalesce(u.email, a.auth_user_id::text), a.employee_id)
    from public.app_users a
    left join auth.users u on u.id = a.auth_user_id
    where a.employee_id is not null
      and not exists (select 1 from staging.employees s where s.employee_id = a.employee_id);
end;
$$;

comment on function staging.promotion_blockers() is
  'Things that would break if this load were promoted, as opposed to rows that are themselves invalid. Currently: dashboard accounts mapped to an employee the incoming extract omits, which would otherwise surface as a foreign key error at commit rather than as something a person can act on.';

-- ---------------------------------------------------------------------
-- Promote
-- ---------------------------------------------------------------------

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

  return query select v_load_id, v_tables, v_counts;
end;
$$;

comment on function staging.promote_load(text[], text) is
  'Replaces production with the staged extract in one transaction: refuses if any row is invalid or any account would lose its employee, defers self-referencing and mapping constraints, replaces only the tables that received rows, records the load in data_loads, refreshes the materialized aggregates, and clears staging. Table order derives from the foreign keys (ING-8, ING-9, ING-10).';

grant execute on function staging.promotion_blockers() to authenticated;
grant execute on function staging.promote_load(text[], text) to authenticated;

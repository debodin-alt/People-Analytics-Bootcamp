-- Make a partial load possible without abandoning referential integrity.
--
-- Found by running a promote for the first time. Staging only `employees`
-- and promoting failed immediately:
--
--   delete on employees violates foreign key compensation_events_employee_id_fkey
--   Key (employee_id)=(E10001) is still referenced from compensation_events
--
-- Whole-table replacement means deleting the parent, and every child table
-- not part of this upload still points at it. The load was legitimate —
-- refreshing the employee master without re-uploading two years of
-- compensation history is the normal case — but the delete is judged
-- statement by statement, so it never survives to the insert that would
-- have made it consistent again.
--
-- Two changes, and the second is the one that matters.
--
-- Every foreign key becomes DEFERRABLE INITIALLY IMMEDIATE, so promote_load
-- can defer them and be judged on the state it leaves behind rather than
-- the state it passes through. Behaviour is unchanged for every other
-- caller: initially immediate means constraints still fire per statement
-- unless something explicitly defers them.
--
-- That alone would turn a clear early failure into an obscure one at
-- commit: "key is still referenced" naming a constraint, at the end of a
-- long transaction, when the real problem is that the extract dropped
-- somebody who has compensation history. So promotion_blockers now says
-- that in advance, in a sentence, derived from the foreign keys rather
-- than from a hand-kept list of pairs.

do $$
declare r record;
begin
  for r in
    select n.nspname, cl.relname, con.conname
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class cl on cl.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = cl.relnamespace
    where n.nspname = 'public' and con.contype = 'f' and not con.condeferrable
  loop
    execute format('alter table %I.%I alter constraint %I deferrable initially immediate',
                   r.nspname, r.relname, r.conname);
  end loop;
end $$;

create or replace function staging.promotion_blockers()
returns table (blocker text, detail text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  r record;
  v_sql text;
  v_n integer;
begin
  perform metrics.require_capability('governance');

  -- 1. A dashboard account mapped to an employee the extract omits.
  --    app_users is not a staging table, so nothing else would catch it.
  if (select count(*) from staging.employees) > 0 then
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
  end if;

  -- 2. Existing rows that would be orphaned by this load.
  --
  --    For every foreign key whose parent is being replaced but whose
  --    child is not, check the child's current rows against the incoming
  --    parent keys. Anything unmatched would fail at commit; better to
  --    name the table and the count now. Derived from pg_constraint, so a
  --    new relationship is covered without editing this function.
  for r in
    select
      child.relname::text  as child_table,
      parent.relname::text as parent_table,
      ca.attname::text     as child_col,
      pa.attname::text     as parent_col
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class child  on child.oid  = con.conrelid
    join pg_catalog.pg_class parent on parent.oid = con.confrelid
    join pg_catalog.pg_namespace n  on n.oid = child.relnamespace
    join pg_catalog.pg_attribute ca on ca.attrelid = child.oid  and ca.attnum = con.conkey[1]
    join pg_catalog.pg_attribute pa on pa.attrelid = parent.oid and pa.attnum = con.confkey[1]
    join pg_catalog.pg_tables pstage
      on pstage.schemaname = 'staging' and pstage.tablename = parent.relname
    where n.nspname = 'public'
      and con.contype = 'f'
      and array_length(con.conkey, 1) = 1
      and child.relname <> parent.relname          -- self-refs are deferred, not orphaned
      and child.relname <> 'app_users'             -- reported by rule 1, with a better message
  loop
    -- Only a parent that is actually part of this load can orphan anything.
    execute format('select count(*) from staging.%I', r.parent_table) into v_n;
    continue when v_n = 0;

    -- A child that is itself being replaced is checked by validate_load's
    -- reference rule instead; this is about rows that will survive untouched.
    if exists (select 1 from pg_catalog.pg_tables
               where schemaname = 'staging' and tablename = r.child_table) then
      execute format('select count(*) from staging.%I', r.child_table) into v_n;
      continue when v_n > 0;
    end if;

    v_sql := format(
      'select count(*) from public.%I c
        where c.%I is not null
          and not exists (select 1 from staging.%I s where s.%I = c.%I)',
      r.child_table, r.child_col, r.parent_table, r.parent_col, r.child_col);
    execute v_sql into v_n;

    if v_n > 0 then
      return query select
        'existing rows would be orphaned'::text,
        format('%s has %s row%s referencing %s that the uploaded file does not contain. '
               || 'Include %s in this load, or add the missing %s to the extract.',
               r.child_table, v_n, case when v_n = 1 then '' else 's' end,
               r.parent_table, r.child_table, r.parent_table);
    end if;
  end loop;
end;
$$;

comment on function staging.promotion_blockers() is
  'What would break if this load were promoted, as opposed to rows that are themselves invalid: dashboard accounts mapped to an omitted employee, and existing rows in tables outside this load that reference parent keys the extract drops. Both would otherwise surface as a foreign key error at commit, naming a constraint rather than the problem. Derived from pg_constraint, so new relationships are covered without editing it.';

grant execute on function staging.promotion_blockers() to authenticated;

-- Validation for staged data (§4.3.3, ING-8).
--
-- Until now the ingestion path was three tables and a hope: a staging
-- schema, a data_loads audit table, and nothing in between. The first real
-- upload would have executed code nobody had ever run, against a company's
-- actual HR extract. This is the missing middle.
--
-- The design decision worth recording: validation is not a hand-written
-- list of rules. It asks production what it requires and checks the staged
-- rows against that. Public carries 174 NOT NULLs, 20 primary keys, 17
-- foreign keys and 21 CHECK constraints across 15 tables; transcribing
-- those into a parallel rulebook is both more work than deriving them and
-- guaranteed to drift the first time a column changes — and a validator
-- that has drifted from the schema it protects is worse than none, because
-- it reports success right up until the promote fails.
--
-- So the rule is: a row is valid if it would be accepted by the production
-- table. Postgres already knows the answer; this asks it in advance,
-- per row, so the failures come back as a list a person can act on rather
-- than as one aborted transaction naming a single constraint.
--
-- `_source_row` carries the row's position in the uploaded file, so a
-- failure reads "employees row 47" rather than pointing at a primary key
-- the uploader has never seen and cannot find in a spreadsheet.

alter table staging.employees                 add column if not exists _source_row integer;
alter table staging.compensation_events       add column if not exists _source_row integer;
alter table staging.performance_reviews       add column if not exists _source_row integer;
alter table staging.competency_scores         add column if not exists _source_row integer;
alter table staging.engagement_responses      add column if not exists _source_row integer;
alter table staging.engagement_response_scores add column if not exists _source_row integer;
alter table staging.engagement_questions      add column if not exists _source_row integer;
alter table staging.engagement_open_ended     add column if not exists _source_row integer;
alter table staging.requisitions              add column if not exists _source_row integer;
alter table staging.funnel_events             add column if not exists _source_row integer;
alter table staging.offers                    add column if not exists _source_row integer;
alter table staging.application_sources       add column if not exists _source_row integer;
alter table staging.recruiters                add column if not exists _source_row integer;
alter table staging.market_benchmarks         add column if not exists _source_row integer;
alter table staging.competency_framework      add column if not exists _source_row integer;

-- ---------------------------------------------------------------------
-- Load order, derived from the foreign keys rather than hardcoded.
--
-- Promotion replaces whole tables, so parents must be inserted before
-- children and children deleted before parents. Writing that order out by
-- hand works until someone adds a table and puts it in the wrong place —
-- at which point the failure is a foreign key violation during a promote,
-- i.e. at the worst possible moment. The graph already exists in
-- pg_constraint; walk it.
-- ---------------------------------------------------------------------

create or replace function staging.table_load_order()
returns table (table_name text, depth integer)
language sql stable security definer set search_path = ''
as $$
  with recursive
  edges as (
    -- child depends on parent
    select
      ct.relname::text as child,
      pt.relname::text as parent
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class ct on ct.oid = c.conrelid
    join pg_catalog.pg_class pt on pt.oid = c.confrelid
    join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
    where c.contype = 'f'
      and n.nspname = 'public'
      and ct.relname <> pt.relname   -- self-references impose no table order
  ),
  staged as (
    select tablename::text as t from pg_catalog.pg_tables where schemaname = 'staging'
  ),
  walk as (
    select s.t, 0 as depth
    from staged s
    where not exists (
      select 1 from edges e join staged p on p.t = e.parent where e.child = s.t
    )
    union all
    select e.child, w.depth + 1
    from walk w
    join edges e on e.parent = w.t
    join staged c on c.t = e.child
    where w.depth < 10   -- guard against a cycle rather than looping forever
  )
  select w.t, max(w.depth)::integer
  from walk w
  group by w.t
  order by 2, 1;
$$;

comment on function staging.table_load_order() is
  'Staging tables in dependency order, derived from public''s foreign keys. Insert ascending, delete descending. Derived rather than hardcoded so adding a table cannot silently produce a promote that violates a foreign key.';

-- ---------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------

create or replace function staging.validate_load(p_max_failures integer default 500)
returns table (
  table_name text,
  source_row integer,
  rule text,
  detail text
)
language plpgsql volatile security definer set search_path = ''
as $$
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
  delete from pg_temp._failures;

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
$$;

comment on function staging.validate_load(integer) is
  'Checks staged rows against the constraints production actually enforces — required columns, CHECK expressions, key duplicates and references — and returns the failures per row rather than aborting on the first. Derived from pg_catalog, so it cannot drift from the schema it protects. Foreign keys resolve against public and against the rest of the same load, so a manager and their reports can arrive together.';

grant execute on function staging.validate_load(integer) to authenticated;
grant execute on function staging.table_load_order() to authenticated;
grant usage on schema staging to authenticated;

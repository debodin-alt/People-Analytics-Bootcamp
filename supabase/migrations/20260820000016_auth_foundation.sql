-- Authentication and the role model.
--
-- DEPARTURE FROM THE COURSE PRD, DELIBERATE.
-- PRD Class 5 §4.1 drops password authentication and settles on
-- email-only sign-in, reasoning that meridiananalytics.com does not exist
-- so no verification mail could ever be delivered. That reasoning is
-- sound for a classroom running on synthetic people. It is not safe for
-- real company data: email-only sign-in means anyone who knows a
-- colleague's address can read that colleague's pay, performance rating
-- and flight risk. This build therefore uses real Supabase Auth
-- (verified credentials, real sessions) and maps authenticated users onto
-- the synthetic directory, rather than treating a typed-in address as
-- proof of identity.
--
-- ENFORCEMENT MODEL
-- Two layers, because people analytics has an awkward property: users
-- must see aggregates computed over rows they may not read individually.
-- A viewer sees "820 employees" without being able to list them.
--
--   1. Capability gate  — which MEASURES a role may call at all.
--   2. Row scope        — which EMPLOYEES a role may see individually,
--                         via visible_employee_ids(), enforced by RLS.
--
-- Aggregate measures stay SECURITY DEFINER (they must read across the
-- whole table to compute a company number) and are gated by capability.
-- Anything row-level is gated by RLS against visible_employee_ids().

-- ---------------------------------------------------------------------
-- 1. Who is this user?
-- ---------------------------------------------------------------------

create table public.app_users (
  auth_user_id uuid primary key references auth.users (id) on delete cascade,
  employee_id text references public.employees (employee_id),
  app_role text not null check (app_role in ('admin', 'executive', 'manager', 'viewer')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  notes text
);

comment on table public.app_users is
  'Maps an authenticated Supabase user onto the employee directory and an application role. A user with no row here has no access — absence is denial, not a default role.';

create index app_users_employee_idx on public.app_users (employee_id);

alter table public.app_users enable row level security;

-- A user may read their own mapping (the app needs it to render the nav);
-- nobody may write one through the API. Role assignment is an
-- administrative act performed against the database, not a self-service
-- endpoint — a user who could insert their own row could grant themselves
-- admin.
create policy app_users_read_self on public.app_users
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 2. Identity helpers
-- ---------------------------------------------------------------------

create function metrics.current_app_role()
returns text language sql stable security definer set search_path = ''
as $$
  select u.app_role from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active
  limit 1;
$$;

create function metrics.current_employee_id()
returns text language sql stable security definer set search_path = ''
as $$
  select u.employee_id from public.app_users u
  where u.auth_user_id = auth.uid() and u.is_active
  limit 1;
$$;

comment on function metrics.current_app_role() is
  'The active role of the calling user, or NULL if they have no app_users row. NULL means no access anywhere.';

-- ---------------------------------------------------------------------
-- 3. Row scope — the single definition of "which employees can this
--    person see individually". Everything row-level derives from here.
--    (This is the getVisibleEmployeeIds the Class 5 PRD names as one of
--    the functions its optimisation loop is forbidden from modifying.)
-- ---------------------------------------------------------------------

create function metrics.visible_employee_ids()
returns table (employee_id text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_role text := metrics.current_app_role();
  v_emp  text := metrics.current_employee_id();
begin
  if v_role in ('admin', 'executive') then
    return query select e.employee_id from public.employees e;

  elsif v_role = 'manager' then
    -- The manager's own reporting tree, themselves included. The depth
    -- guard is not optional: a cycle in manager_employee_id would loop
    -- forever, and real HR data grows cycles during reorgs even when
    -- clean data does not have them today.
    return query
      with recursive tree as (
        select e.employee_id, 1 as depth
        from public.employees e
        where e.employee_id = v_emp
        union all
        select e.employee_id, t.depth + 1
        from public.employees e
        join tree t on e.manager_employee_id = t.employee_id
        where t.depth < 20
      )
      select t.employee_id from tree t;

  elsif v_role = 'viewer' then
    -- Themselves only. A viewer gets company aggregates, not a directory.
    return query select v_emp where v_emp is not null;

  else
    return;  -- no role, no rows
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Capability model — kept in a table so the grid is inspectable and
--    changeable without editing function bodies.
-- ---------------------------------------------------------------------

create table metrics.role_capabilities (
  app_role text not null check (app_role in ('admin', 'executive', 'manager', 'viewer')),
  capability text not null,
  primary key (app_role, capability)
);

comment on table metrics.role_capabilities is
  'Which measure classes each role may call. company_aggregates = headline company numbers; dimension_cuts = breakdowns by function/location/level; compensation = pay measures; sensitive_attributes = flight risk and unadjusted pay equity; individual_detail = row-level employee data (further narrowed by visible_employee_ids); governance = admin surfaces.';

insert into metrics.role_capabilities (app_role, capability) values
  ('viewer',    'company_aggregates'),

  ('manager',   'company_aggregates'),
  ('manager',   'dimension_cuts'),
  ('manager',   'individual_detail'),   -- scoped to their tree by visible_employee_ids()

  ('executive', 'company_aggregates'),
  ('executive', 'dimension_cuts'),
  ('executive', 'compensation'),
  ('executive', 'sensitive_attributes'),

  ('admin',     'company_aggregates'),
  ('admin',     'dimension_cuts'),
  ('admin',     'compensation'),
  ('admin',     'sensitive_attributes'),
  ('admin',     'individual_detail'),
  ('admin',     'governance');

alter table metrics.role_capabilities enable row level security;

create function metrics.has_capability(p_capability text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from metrics.role_capabilities rc
    where rc.app_role = metrics.current_app_role()
      and rc.capability = p_capability
  );
$$;

-- Returns the caller's own role and capabilities so the UI can hide what
-- it must not offer. The UI hiding a control is convenience; the measure
-- refusing to compute is the actual control.
create function metrics.current_session_context()
returns table (app_role text, employee_id text, capabilities text[])
language sql stable security definer set search_path = ''
as $$
  select
    metrics.current_app_role(),
    metrics.current_employee_id(),
    coalesce(
      (select array_agg(rc.capability order by rc.capability)
       from metrics.role_capabilities rc
       where rc.app_role = metrics.current_app_role()),
      '{}'::text[]
    );
$$;

-- ---------------------------------------------------------------------
-- 5. RLS policies on the people-bearing tables (SEM-8).
--
--    The client still holds no direct table grants, so these are not the
--    live enforcement path today — the aggregate functions are. They are
--    written now so that the day anything IS granted table access, it is
--    scoped by construction rather than open by default, and so the
--    query layer needs no rewrite (PRD §2.2).
-- ---------------------------------------------------------------------

create policy employees_scoped_read on public.employees
  for select to authenticated
  using (employee_id in (select v.employee_id from metrics.visible_employee_ids() v));

create policy compensation_events_scoped_read on public.compensation_events
  for select to authenticated
  using (employee_id in (select v.employee_id from metrics.visible_employee_ids() v));

create policy performance_reviews_scoped_read on public.performance_reviews
  for select to authenticated
  using (employee_id in (select v.employee_id from metrics.visible_employee_ids() v));

create policy competency_scores_scoped_read on public.competency_scores
  for select to authenticated
  using (employee_id in (select v.employee_id from metrics.visible_employee_ids() v));

-- ---------------------------------------------------------------------
-- 6. Close the door on anonymous access.
--
--    Until now every measure was callable with the publishable key. That
--    was acceptable while the data was synthetic and the alternative was
--    no product at all; it is not acceptable now that a login exists.
-- ---------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'metrics'
  loop
    execute format('revoke all on function %s from anon', r.sig);
  end loop;
end $$;

grant execute on function metrics.current_app_role() to authenticated;
grant execute on function metrics.current_employee_id() to authenticated;
grant execute on function metrics.visible_employee_ids() to authenticated;
grant execute on function metrics.has_capability(text) to authenticated;
grant execute on function metrics.current_session_context() to authenticated;

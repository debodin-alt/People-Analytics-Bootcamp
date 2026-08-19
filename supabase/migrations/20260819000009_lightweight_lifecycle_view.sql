-- headcount_trend timed out (57014) in the browser: it joined a 12-row
-- month series against the *full* metrics.dim_employee view, which drags
-- in level_map + pay_zone_map + fx_rates + market_benchmarks on every one
-- of those 12 iterations even though it only needs hire_date and
-- termination_date. The CLI tests never caught this because a superuser
-- psql connection has no statement_timeout and isn't contending with five
-- other concurrent RPC calls the way the browser's pooled connection is.
--
-- Fix: a minimal view carrying only the lifecycle columns these three
-- functions actually use, plus indexes so the range predicate isn't a
-- sequential scan.

create index employees_hire_date_idx on public.employees (hire_date);
create index employees_termination_date_idx on public.employees (termination_date);

create view metrics.employee_lifecycle as
select employee_id, hire_date, termination_date, termination_type, employment_status, function
from public.employees;

grant select on metrics.employee_lifecycle to anon, authenticated;

create or replace function metrics.headcount_trend(p_months integer default 12)
returns table (period date, headcount integer)
language sql stable as $$
  with months as (
    select date_trunc('month', metrics.reporting_boundary())::date - (n || ' months')::interval as month_end
    from generate_series(0, p_months - 1) as n
  )
  select (m.month_end + interval '1 month' - interval '1 day')::date as period,
         count(e.employee_id)::integer as headcount
  from months m
  left join metrics.employee_lifecycle e
    on e.hire_date <= (m.month_end + interval '1 month' - interval '1 day')::date
   and (e.termination_date is null or e.termination_date > (m.month_end + interval '1 month' - interval '1 day')::date)
  group by m.month_end
  order by m.month_end;
$$;

create or replace function metrics.composition_by_function(p_status text default 'Active')
returns table (function text, headcount integer)
language sql stable as $$
  select e.function, count(*)::integer
  from metrics.employee_lifecycle e
  where e.employment_status = p_status
  group by e.function
  order by count(*) desc;
$$;

create or replace function metrics.attrition_by_type_ttm()
returns table (voluntary integer, involuntary integer)
language sql stable as $$
  select
    count(*) filter (where termination_type = 'Voluntary')::integer,
    count(*) filter (where termination_type = 'Involuntary')::integer
  from metrics.employee_lifecycle
  where termination_date between metrics.reporting_boundary() - interval '12 months' and metrics.reporting_boundary();
$$;

grant execute on function metrics.headcount_trend(integer) to anon, authenticated;
grant execute on function metrics.composition_by_function(text) to anon, authenticated;
grant execute on function metrics.attrition_by_type_ttm() to anon, authenticated;

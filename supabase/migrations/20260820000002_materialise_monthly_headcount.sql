-- Materialise the monthly headcount aggregate (NFR-2, SEM-6).
--
-- headcount_trend() recomputed a 12-month × 920-employee point-in-time
-- reconstruction on every page load: ~1.8s standalone, and it tipped over
-- the statement timeout once the Executive Overview fired it alongside
-- four other RPCs. The chart silently fell back to "No data" — the second
-- time this query has failed under real browser concurrency.
--
-- The range predicate (hire_date <= X AND (term_date IS NULL OR term_date > X))
-- is not sargable per month, so no index fixes it. The PRD's own answer is
-- to materialise it: "a page that cannot meet [300ms] gets a materialized
-- aggregate, not a spinner."
--
-- Computed once over the full history at refresh time, then read as a
-- simple ordered scan per request.

create materialized view metrics.mv_monthly_headcount as
with bounds as (
  select date_trunc('month', min(hire_date))::date as first_month,
         date_trunc('month', metrics.reporting_boundary())::date as last_month
  from public.employees
),
months as (
  select generate_series(b.first_month, b.last_month, interval '1 month')::date as month_start
  from bounds b
)
select
  (m.month_start + interval '1 month' - interval '1 day')::date as period,
  count(e.employee_id)::integer as headcount
from months m
left join public.employees e
  on e.hire_date <= (m.month_start + interval '1 month' - interval '1 day')::date
 and (e.termination_date is null
      or e.termination_date > (m.month_start + interval '1 month' - interval '1 day')::date)
group by m.month_start;

-- Unique index is required for REFRESH ... CONCURRENTLY (which avoids
-- locking readers out during a refresh).
create unique index mv_monthly_headcount_period_idx on metrics.mv_monthly_headcount (period);

comment on materialized view metrics.mv_monthly_headcount is
  'Point-in-time headcount at each month end, over the full history. Refresh via metrics.refresh_aggregates() at the end of every data load (ING-10).';

-- Reads the materialised rows instead of recomputing. Still SECURITY
-- DEFINER: the client has no direct access to the matview either.
create or replace function metrics.headcount_trend(p_months integer default 12)
returns table (period date, headcount integer)
language sql stable security definer set search_path = ''
as $$
  select period, headcount
  from (
    select period, headcount
    from metrics.mv_monthly_headcount
    where period <= metrics.reporting_boundary()
    order by period desc
    limit p_months
  ) recent
  order by period;
$$;

grant execute on function metrics.headcount_trend(integer) to anon, authenticated;

-- Materialised-view refresh belongs to the ingest completion path
-- (ING-10), not a manual step someone remembers to run.
create function metrics.refresh_aggregates()
returns void language plpgsql security definer set search_path = ''
as $$
begin
  refresh materialized view concurrently metrics.mv_monthly_headcount;
end;
$$;

comment on function metrics.refresh_aggregates() is
  'Refreshes every materialised aggregate. Called at the end of each data load, after promotion from staging.';

-- Deliberately NOT granted to anon/authenticated: refresh is an
-- ingestion-time operation, not a client capability.

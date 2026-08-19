-- Two bugs found wiring the Executive Overview page to real browser
-- traffic (as opposed to the CLI's privileged connection, which never
-- exercises RLS and so never caught this):
--
-- 1. headcount_trend/composition_by_function/attrition_by_type_ttm queried
--    public.employees directly. Plain functions run with the CALLER's
--    privileges for table access (only views get the "run as owner"
--    treatment), so under the anon key — which has no SELECT policy on
--    employees by design — these silently returned zero rows. Routed
--    through metrics.dim_employee instead, same as every working measure.
--
-- 2. Postgres numeric/bigint results serialize as JSON *strings* over
--    PostgREST (to avoid precision loss beyond a JS double), which broke
--    the charts' numeric axis math. Cast to integer/double precision
--    where full numeric precision was never needed anyway.

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
  left join metrics.dim_employee e
    on e.hire_date <= (m.month_end + interval '1 month' - interval '1 day')::date
   and (e.termination_date is null or e.termination_date > (m.month_end + interval '1 month' - interval '1 day')::date)
  group by m.month_end
  order by m.month_end;
$$;

create or replace function metrics.composition_by_function(p_status text default 'Active')
returns table (function text, headcount integer)
language sql stable as $$
  select e.function, count(*)::integer
  from metrics.dim_employee e
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
  from metrics.dim_employee
  where termination_date between metrics.reporting_boundary() - interval '12 months' and metrics.reporting_boundary();
$$;

-- return type changed (candidate_count bigint -> integer); CREATE OR
-- REPLACE cannot alter OUT-parameter types, so drop first.
drop function metrics.recruiting_funnel_stages();

create function metrics.recruiting_funnel_stages()
returns table (stage_order integer, stage_name text, candidate_count integer)
language sql stable as $$
  select stage_order, stage_name, sum(candidate_count)::integer
  from public.funnel_events
  group by stage_order, stage_name
  order by stage_order;
$$;

-- return type changed (mean_score numeric -> double precision, n bigint -> integer).
drop function metrics.engagement_by_category();

create function metrics.engagement_by_category()
returns table (category text, mean_score double precision, n integer)
language sql stable as $$
  select q.category, round(avg(s.score), 2)::double precision, count(*)::integer
  from public.engagement_response_scores s
  join public.engagement_questions q on q.question_id = s.question_id
  where q.category is not null and q.category <> 'Open-Ended'
  group by q.category
  having count(*) >= 5
  order by avg(s.score) asc;
$$;

grant execute on function metrics.headcount_trend(integer) to anon, authenticated;
grant execute on function metrics.composition_by_function(text) to anon, authenticated;
grant execute on function metrics.attrition_by_type_ttm() to anon, authenticated;
grant execute on function metrics.recruiting_funnel_stages() to anon, authenticated;
grant execute on function metrics.engagement_by_category() to anon, authenticated;

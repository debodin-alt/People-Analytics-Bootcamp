-- Make the remaining chart measures respect the filter context.
--
-- Until now, filtering to Engineering changed the KPI tiles while the
-- charts beside them kept showing company-wide figures. A page that
-- displays two different populations under one filter is worse than a
-- page that cannot filter at all — the PRD calls a disagreement between
-- surfaces a product failure (§1.3), and this was that failure happening
-- within a single screen.
--
-- Twenty chart measures already accepted filters and simply were not
-- being passed any; that is fixed in the client. Five needed the
-- arguments adding, and one of those — headcount_trend — needed its
-- underlying aggregate redesigned.
--
-- HEADCOUNT TREND: WHY THE AGGREGATE GAINS DIMENSIONS
-- Computing a filtered trend live takes ~10s (measured), so it cannot be
-- done per request. The aggregate is therefore pre-grouped by the
-- dimensions the filter bar offers, and a filtered trend becomes a SUM
-- over the relevant rows.
--
-- HEADCOUNT TREND: THE CAVEAT THAT MATTERS
-- dim_employee carries CURRENT attributes only — this build has no
-- point-in-time employee history (that arrives with employee_snapshots in
-- Class 3). So a trend filtered to Engineering means "headcount over time
-- among people who are in Engineering TODAY", not "Engineering headcount
-- over time". Someone who transferred in last month is counted in
-- Engineering across the whole window. That is a standard approximation
-- and it is labelled on the chart rather than left for a reader to
-- discover.
--
-- tenure_band is deliberately NOT supported for the trend. The other
-- attributes are approximations; tenure band is actively misleading,
-- because it is derived from tenure which changes continuously — filter
-- to "<1 year" and look back twelve months and every remaining person was
-- either under a year for the whole window or not yet hired. The measure
-- refuses that combination explicitly rather than returning a confident
-- wrong line.

drop function if exists metrics.headcount_trend(integer);
drop materialized view if exists metrics.mv_monthly_headcount;

create materialized view metrics.mv_monthly_headcount as
with emp as (
  select
    e.employee_id, e.hire_date, e.termination_date, e.function, e.office_location,
    case
      when e.career_level in ('P1','P2') then 'Entry / Mid IC'
      when e.career_level = 'P3' then 'Senior IC'
      when e.career_level in ('P4','P5','P6','P7') then 'Staff+ IC'
      when e.career_level = 'M3' then 'First-Line Manager'
      when e.career_level = 'M4' then 'Sr Manager'
      when e.career_level = 'M5' then 'Director'
      when e.career_level in ('M6','M7','M8') then 'VP+'
      else 'Unclassified'
    end as level_band
  from public.employees e
),
bounds as (
  select date_trunc('month', min(emp.hire_date))::date as first_month,
         date_trunc('month', metrics.workforce_boundary())::date as last_month
  from emp
),
months as (
  select generate_series(b.first_month, b.last_month, interval '1 month')::date as month_start
  from bounds b
)
select
  (m.month_start + interval '1 month' - interval '1 day')::date as period,
  emp.function, emp.office_location, emp.level_band,
  count(*)::integer as headcount
from months m
join emp
  on emp.hire_date <= (m.month_start + interval '1 month' - interval '1 day')::date
 and (emp.termination_date is null
      or emp.termination_date > (m.month_start + interval '1 month' - interval '1 day')::date)
group by 1, 2, 3, 4;

create unique index mv_monthly_headcount_key_idx
  on metrics.mv_monthly_headcount (period, function, office_location, level_band);

comment on materialized view metrics.mv_monthly_headcount is
  'Point-in-time headcount at each month end, pre-grouped by CURRENT function, office and level band so the trend can be filtered without a ~10s live recomputation. Attributes are current, not point-in-time: a filtered trend reads "among people who are in X today". Refresh via metrics.refresh_aggregates().';

create function metrics.headcount_trend(
  p_months integer default 12,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (period date, headcount integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  -- Refusing beats returning a confident wrong line. See header note.
  if p_tenure_band is not null and array_length(p_tenure_band, 1) > 0 then
    raise exception 'Headcount trend cannot be filtered by tenure band'
      using errcode = '22023',
            hint = 'Tenure band is derived from tenure, which changes over time, so applying it to a historical trend produces a misleading series. Clear the tenure filter to view the trend.';
  end if;

  return query
  select mv.period, sum(mv.headcount)::integer
  from metrics.mv_monthly_headcount mv
  where mv.period <= metrics.workforce_boundary()
    and (p_function is null or mv.function = any(p_function))
    and (p_location is null or mv.office_location = any(p_location))
    and (p_level_band is null or mv.level_band = any(p_level_band))
  group by mv.period
  order by mv.period desc
  limit p_months;
end;
$$;

comment on function metrics.headcount_trend(integer, text[], text[], text[], text[]) is
  'Point-in-time headcount per month end, from the mv_monthly_headcount aggregate (NFR-2). Filters apply to CURRENT attributes, so a filtered series reads "among people who are in X today" — this build has no point-in-time employee history. Refuses a tenure_band filter outright, since tenure changes over time and applying it to a historical series is misleading rather than merely approximate.';

-- ---- the remaining four ----------------------------------------------

drop function if exists metrics.composition_by_function(text);
create function metrics.composition_by_function(
  p_status text default 'Active',
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (function text, headcount integer)
language sql stable security definer set search_path = ''
as $$
  select e.function, count(*)::integer
  from metrics.dim_employee e
  where e.employment_status = p_status
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by e.function order by count(*) desc;
$$;

drop function if exists metrics.attrition_by_type_ttm();
create function metrics.attrition_by_type_ttm(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (voluntary integer, involuntary integer)
language sql stable security definer set search_path = ''
as $$
  select
    count(*) filter (where e.termination_type = 'Voluntary')::integer,
    count(*) filter (where e.termination_type = 'Involuntary')::integer
  from metrics.dim_employee e
  where e.termination_date between metrics.workforce_boundary() - interval '12 months'
                               and metrics.workforce_boundary()
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

drop function if exists metrics.engagement_by_category();
create function metrics.engagement_by_category(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (category text, mean_score double precision, n integer)
language sql stable security definer set search_path = ''
as $$
  select q.category, round(avg(s.score), 2)::double precision, count(*)::integer
  from public.engagement_response_scores s
  join public.engagement_questions q on q.question_id = s.question_id
  join public.engagement_responses r on r.response_id = s.response_id
  where q.category is not null and q.category <> 'Open-Ended'
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
    and (p_level_band is null or r.level_band = any(p_level_band))
    and (p_tenure_band is null or r.tenure_band = any(p_tenure_band))
  group by q.category
  having count(*) >= metrics.minimum_cell_size()
  order by avg(s.score) asc;
$$;

drop function if exists metrics.monthly_hires_exits(integer);
create function metrics.monthly_hires_exits(
  p_months integer default 12,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (period date, hires integer, exits integer, net_change integer)
language sql stable security definer set search_path = ''
as $$
  with months as (
    select date_trunc('month', metrics.workforce_boundary())::date
             - (n || ' months')::interval as month_start
    from generate_series(0, p_months - 1) as n
  ),
  scoped as (
    select e.hire_date, e.termination_date
    from metrics.dim_employee e
    where (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select
    (m.month_start + interval '1 month' - interval '1 day')::date,
    count(*) filter (where s.hire_date >= m.month_start
                       and s.hire_date < m.month_start + interval '1 month')::integer,
    count(*) filter (where s.termination_date >= m.month_start
                       and s.termination_date < m.month_start + interval '1 month')::integer,
    (count(*) filter (where s.hire_date >= m.month_start
                       and s.hire_date < m.month_start + interval '1 month')
     - count(*) filter (where s.termination_date >= m.month_start
                         and s.termination_date < m.month_start + interval '1 month'))::integer
  from months m
  left join scoped s
    on (s.hire_date >= m.month_start and s.hire_date < m.month_start + interval '1 month')
    or (s.termination_date >= m.month_start and s.termination_date < m.month_start + interval '1 month')
  group by m.month_start order by m.month_start;
$$;

comment on function metrics.composition_by_function(text, text[], text[], text[], text[]) is
  'Headcount by function for a given employment status, respecting the filter context.';
comment on function metrics.attrition_by_type_ttm(text[], text[], text[], text[]) is
  'Voluntary and involuntary termination counts in the trailing 12 months, as two separate figures. Never summed into a single attrition number (MET-3).';
comment on function metrics.engagement_by_category(text[], text[], text[], text[]) is
  'Mean survey score per question category, 1-5 Likert. Categories with fewer than 5 responses are excluded entirely.';
comment on function metrics.monthly_hires_exits(integer, text[], text[], text[], text[]) is
  'Hires, exits and net change per calendar month, keyed to workforce_boundary(). Opposing flows — never stacked into a combined total.';

grant execute on function metrics.headcount_trend(integer, text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.composition_by_function(text, text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.attrition_by_type_ttm(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.engagement_by_category(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.monthly_hires_exits(integer, text[], text[], text[], text[]) to authenticated;

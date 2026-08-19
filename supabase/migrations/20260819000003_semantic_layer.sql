-- Meridian People Analytics Platform — semantic layer (§4.4).
-- Every page, every chart and the Wizard query this schema. Nothing
-- computes a metric in application code (SEM-4). Views here run as the
-- view owner (not security_invoker), so they can read through the RLS
-- lockdown on employees/compensation_events/performance_reviews/
-- competency_scores while still excluding PII columns themselves —
-- that lockdown is enforced by never granting anon/authenticated direct
-- table access, not by the view's own security context.

create schema if not exists metrics;
grant usage on schema metrics to anon, authenticated;

-- ---------------------------------------------------------------------
-- Conformed dimensions (§4.4.1)
-- ---------------------------------------------------------------------

-- dim_employee resolves the two things that make every market comparison
-- wrong if skipped: the Apex level/tier mapping (MAP-1) and the currency
-- conversion (MAP-2). It also derives level_band and tenure_band, which
-- exist in the engagement survey's demographic cuts but not on the
-- employee master itself, so every page can filter on the same bands.
create view metrics.dim_employee as
select
  e.employee_id,
  e.employment_status,
  e.employment_type,
  e.hire_date,
  e.termination_date,
  e.termination_type,
  e.tenure_years,
  case
    when e.tenure_years < 1 then '<1 year'
    when e.tenure_years < 3 then '1-3 years'
    when e.tenure_years < 5 then '3-5 years'
    when e.tenure_years < 8 then '5-8 years'
    else '8+ years'
  end as tenure_band,
  e.career_track,
  e.career_level,
  case
    when e.career_level in ('P1', 'P2') then 'Entry / Mid IC'
    when e.career_level = 'P3' then 'Senior IC'
    when e.career_level in ('P4', 'P5', 'P6', 'P7') then 'Staff+ IC'
    when e.career_level = 'M3' then 'First-Line Manager'
    when e.career_level = 'M4' then 'Sr Manager'
    when e.career_level = 'M5' then 'Director'
    when e.career_level in ('M6', 'M7', 'M8') then 'VP+'
    else 'Unclassified'
  end as level_band,
  e.job_title,
  e.job_family,
  e.department,
  e.function,
  e.manager_employee_id,
  e.number_of_direct_reports,
  e.office_location,
  e.work_country,
  e.pay_zone,
  lm.apex_level,
  lm.apex_track,
  pzm.apex_tier,
  pzm.apex_tier_multiplier,
  e.currency,
  e.base_salary,
  round(e.base_salary * coalesce(fx.usd_rate, 1), 2) as base_salary_usd,
  e.salary_range_min,
  e.salary_range_mid,
  e.salary_range_max,
  e.compa_ratio,
  e.range_penetration,
  case when mb.p50_base_salary_usd_k is not null
    then round((e.base_salary * coalesce(fx.usd_rate, 1)) / (mb.p50_base_salary_usd_k * 1000), 4)
  end as market_position_p50,
  e.current_perf_rating,
  e.nine_box_placement,
  e.flight_risk_rating,
  e.latest_engagement_score,
  e.on_pip_flag,
  e.gender,
  e.race_ethnicity
from public.employees e
left join public.level_map lm on lm.meridian_career_level = e.career_level
left join public.pay_zone_map pzm on pzm.office_location = e.office_location and pzm.pay_zone = e.pay_zone
left join public.fx_rates fx on fx.currency = e.currency
left join public.market_benchmarks mb
  on mb.function = e.function
 and mb.track = lm.apex_track
 and mb.apex_level = lm.apex_level
 and mb.pay_zone = pzm.apex_tier;

-- Declared drill hierarchies (SEM-5) — the UI reads this, it does not
-- hardcode the level sequence.
create table metrics.hierarchy_definitions (
  hierarchy text not null,
  level_order integer not null,
  level_name text not null,
  primary key (hierarchy, level_order)
);

insert into metrics.hierarchy_definitions (hierarchy, level_order, level_name) values
  ('org', 1, 'function'), ('org', 2, 'job_family'), ('org', 3, 'career_level'), ('org', 4, 'employee'),
  ('geography', 1, 'region'), ('geography', 2, 'country'), ('geography', 3, 'office'), ('geography', 4, 'pay_zone'),
  ('time', 1, 'year'), ('time', 2, 'quarter'), ('time', 3, 'month');

grant select on metrics.dim_employee, metrics.hierarchy_definitions to anon, authenticated;

-- ---------------------------------------------------------------------
-- Reporting boundary (§2.3, ING-11) — derived from the data, never a
-- hardcoded constant, so the same code works on every refresh.
-- ---------------------------------------------------------------------

create function metrics.reporting_boundary()
returns date
language sql
stable
as $$
  select coalesce(
    greatest(
      (select max(event_date) from public.compensation_events),
      (select max(effective_date) from public.performance_reviews),
      (select max(close_date) from public.requisitions),
      (select max(response_date)::date from public.engagement_responses),
      (select max(loaded_at)::date from public.data_loads)
    ),
    current_date
  );
$$;

grant execute on function metrics.reporting_boundary() to anon, authenticated;

-- ---------------------------------------------------------------------
-- The typed metric result (mirrors MetricResult in lib/types.ts) — a raw
-- number never stands in for "no data"; every measure returns one of
-- these instead of a bare scalar.
-- ---------------------------------------------------------------------

create type metrics.metric_result as (
  status text,             -- 'value' | 'no_data' | 'unavailable' | 'suppressed' | 'error'
  value numeric,
  reason text,
  population_count integer
);

-- ---------------------------------------------------------------------
-- Measures (§5, SEM-2) — one implementation per definition. Every
-- measure accepts the same filter shape (SEM-3): function/location/
-- level_band/tenure_band arrays, NULL meaning "no filter applied".
-- ---------------------------------------------------------------------

create function metrics.active_headcount(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable as $$
  select case when count(*) = 0 then row('no_data', null, 'No employees match this filter.', 0)::metrics.metric_result
              else row('value', count(*), null, count(*))::metrics.metric_result
         end
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

-- Voluntary attrition rate TTM = voluntary terms TTM / average active headcount,
-- average = (start + end) / 2, per §5.
create function metrics.voluntary_attrition_rate_ttm(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable as $$
declare
  v_boundary date := metrics.reporting_boundary();
  v_window_start date := metrics.reporting_boundary() - interval '12 months';
  v_terms integer;
  v_start_hc integer;
  v_end_hc integer;
  v_avg_hc numeric;
begin
  select count(*) into v_terms
  from metrics.dim_employee e
  where e.termination_type = 'Voluntary'
    and e.termination_date between v_window_start and v_boundary
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  select count(*) into v_start_hc
  from metrics.dim_employee e
  where e.hire_date <= v_window_start
    and (e.termination_date is null or e.termination_date > v_window_start)
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  select count(*) into v_end_hc
  from metrics.dim_employee e
  where e.hire_date <= v_boundary
    and (e.termination_date is null or e.termination_date > v_boundary)
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  v_avg_hc := (v_start_hc + v_end_hc) / 2.0;

  if v_avg_hc = 0 then
    return row('no_data', null, 'No active headcount in this window for the current filter.', 0)::metrics.metric_result;
  end if;

  return row('value', round((v_terms / v_avg_hc) * 100, 1), null, v_terms)::metrics.metric_result;
end;
$$;

create function metrics.involuntary_attrition_count_ttm(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from metrics.dim_employee e
  where e.termination_type = 'Involuntary'
    and e.termination_date between metrics.reporting_boundary() - interval '12 months' and metrics.reporting_boundary()
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

create function metrics.median_compa_ratio(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable as $$
declare
  v_median numeric;
  v_n integer;
begin
  select percentile_cont(0.5) within group (order by e.compa_ratio), count(*)
  into v_median, v_n
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_n = 0 or v_median is null then
    return row('no_data', null, 'No active employees with compensation data in this filter.', 0)::metrics.metric_result;
  end if;

  return row('value', round(v_median, 2), null, v_n)::metrics.metric_result;
end;
$$;

create function metrics.elevated_flight_risk_count(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and e.flight_risk_rating = 'High'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

-- Engagement — two instruments, never blended (MET-2). Aggregate only,
-- min cell size enforced (§6.5, NFR-5), since engagement_responses is
-- structurally anonymous.
create function metrics.engagement_survey_mean(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable as $$
declare
  v_mean numeric;
  v_n integer;
begin
  select avg(s.score), count(distinct r.response_id)
  into v_mean, v_n
  from public.engagement_responses r
  join public.engagement_response_scores s on s.response_id = r.response_id
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
    and (p_level_band is null or r.level_band = any(p_level_band))
    and (p_tenure_band is null or r.tenure_band = any(p_tenure_band));

  if v_n is null or v_n = 0 then
    return row('no_data', null, 'No engagement survey responses in this filter.', 0)::metrics.metric_result;
  end if;
  if v_n < 5 then
    return row('suppressed', null, 'Fewer than 5 responses in this cut; suppressed to protect anonymity.', v_n)::metrics.metric_result;
  end if;

  return row('value', round(v_mean, 2), null, v_n)::metrics.metric_result;
end;
$$;

create function metrics.engagement_employee_mean(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable as $$
declare
  v_mean numeric;
  v_n integer;
begin
  select avg(e.latest_engagement_score), count(e.latest_engagement_score)
  into v_mean, v_n
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and e.latest_engagement_score is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_n is null or v_n = 0 then
    return row('no_data', null, 'No per-employee engagement scores loaded for this filter.', 0)::metrics.metric_result;
  end if;

  return row('value', round(v_mean, 2), null, v_n)::metrics.metric_result;
end;
$$;

create function metrics.open_requisitions_count(
  p_function text[] default null,
  p_location text[] default null
) returns metrics.metric_result
language sql stable as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from public.requisitions r
  where r.outcome = 'Open'
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));
$$;

-- ---------------------------------------------------------------------
-- Chart-data table functions — the Executive Overview grid (§6.1 Page 1).
-- ---------------------------------------------------------------------

-- Headcount trend: no monthly snapshot table exists in v0.1 (that lands
-- with Class 3's employee_snapshots), so headcount at each month end is
-- reconstructed from hire_date/termination_date, which is exact for a
-- point-in-time count.
create function metrics.headcount_trend(p_months integer default 12)
returns table (period date, headcount integer)
language sql stable as $$
  with months as (
    select date_trunc('month', metrics.reporting_boundary())::date - (n || ' months')::interval as month_end
    from generate_series(0, p_months - 1) as n
  )
  select (m.month_end + interval '1 month' - interval '1 day')::date as period,
         count(e.employee_id)::integer as headcount
  from months m
  left join public.employees e
    on e.hire_date <= (m.month_end + interval '1 month' - interval '1 day')::date
   and (e.termination_date is null or e.termination_date > (m.month_end + interval '1 month' - interval '1 day')::date)
  group by m.month_end
  order by m.month_end;
$$;

create function metrics.composition_by_function(p_status text default 'Active')
returns table (function text, headcount integer)
language sql stable as $$
  select e.function, count(*)::integer
  from public.employees e
  where e.employment_status = p_status
  group by e.function
  order by count(*) desc;
$$;

create function metrics.attrition_by_type_ttm()
returns table (voluntary integer, involuntary integer)
language sql stable as $$
  select
    count(*) filter (where termination_type = 'Voluntary')::integer,
    count(*) filter (where termination_type = 'Involuntary')::integer
  from public.employees
  where termination_date between metrics.reporting_boundary() - interval '12 months' and metrics.reporting_boundary();
$$;

create function metrics.recruiting_funnel_stages()
returns table (stage_order integer, stage_name text, candidate_count bigint)
language sql stable as $$
  select stage_order, stage_name, sum(candidate_count)
  from public.funnel_events
  group by stage_order, stage_name
  order by stage_order;
$$;

create function metrics.engagement_by_category()
returns table (category text, mean_score numeric, n bigint)
language sql stable as $$
  select q.category, round(avg(s.score), 2), count(*)
  from public.engagement_response_scores s
  join public.engagement_questions q on q.question_id = s.question_id
  where q.category is not null and q.category <> 'Open-Ended'
  group by q.category
  having count(*) >= 5
  order by avg(s.score) asc;
$$;

grant execute on all functions in schema metrics to anon, authenticated;
alter default privileges in schema metrics grant execute on functions to anon, authenticated;

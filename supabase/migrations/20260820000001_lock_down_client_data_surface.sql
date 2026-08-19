-- SECURITY FIX — close the client-side read surface.
--
-- THE DEFECT
-- The publishable ("anon") key ships inside the browser bundle and is
-- readable by anyone who opens devtools. It could read, in full:
--   metrics.dim_employee        920 people w/ salary, gender, race_ethnicity,
--                               compa_ratio, flight_risk_rating
--   metrics.employee_lifecycle  920 people w/ hire + termination dates
--   engagement_open_ended       886 free-text verbatims + demographics
--   engagement_responses/_scores per-response demographics and answers
--   recruiters                  12 named people + individual performance
--   requisitions                311 reqs incl. hiring_manager_id
--
-- ROOT CAUSE
-- RLS was enabled on the people-bearing tables, but metrics.dim_employee
-- and metrics.employee_lifecycle are plain views. A view executes with
-- its OWNER's privileges and evaluates RLS as the owner unless created
-- WITH (security_invoker = true). Granting anon SELECT on those views
-- therefore tunnelled straight through the RLS underneath. Separately,
-- several non-employee tables carried `using (true)` policies, which is
-- "allow the whole internet", not a policy.
--
-- Writes were never exposed: every policy was SELECT-only and RLS denies
-- unmatched commands (verified — INSERT returns 42501 and no row lands).
--
-- THE FIX
-- The client gets NO row-level access to any table containing people.
-- Its entire data surface becomes the aggregate metrics.* functions,
-- which are SECURITY DEFINER (so they can still read the base tables)
-- with a pinned empty search_path (so the definer's rights cannot be
-- hijacked by a shadowed object). Aggregates that expose a personal
-- attribute now enforce minimum cell size (SEM-9 / NFR-5).
--
-- This is deliberately stricter than "add RLS policies": until real
-- authentication exists there is no principal to write a policy against,
-- so the only honest posture is that the browser key can read aggregates
-- and nothing else. Per-role RLS lands with auth (PRD §4.4.5, SEM-8);
-- the query layer will not need rewriting when it does.

-- ---------------------------------------------------------------------
-- 1. Revoke every table-level privilege from the client roles
-- ---------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke all on all tables in schema metrics from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Supabase's default grants re-arm this for anything created later.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema metrics revoke all on tables from anon, authenticated;

-- Migration 3 auto-granted EXECUTE on every future metrics function.
-- That is a footgun: a new function would become public on creation.
-- New functions must now be granted explicitly, one at a time.
alter default privileges in schema metrics revoke execute on functions from anon, authenticated;
revoke all on all functions in schema metrics from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Drop the `using (true)` policies — they granted universal read
-- ---------------------------------------------------------------------

drop policy if exists application_sources_public_read on public.application_sources;
drop policy if exists competency_framework_public_read on public.competency_framework;
drop policy if exists data_loads_public_read on public.data_loads;
drop policy if exists engagement_open_ended_public_read on public.engagement_open_ended;
drop policy if exists engagement_questions_public_read on public.engagement_questions;
drop policy if exists engagement_response_scores_public_read on public.engagement_response_scores;
drop policy if exists engagement_responses_public_read on public.engagement_responses;
drop policy if exists funnel_events_public_read on public.funnel_events;
drop policy if exists fx_rates_public_read on public.fx_rates;
drop policy if exists level_map_public_read on public.level_map;
drop policy if exists market_benchmarks_public_read on public.market_benchmarks;
drop policy if exists offers_public_read on public.offers;
drop policy if exists pay_zone_map_public_read on public.pay_zone_map;
drop policy if exists recruiters_public_read on public.recruiters;
drop policy if exists requisitions_public_read on public.requisitions;

-- hierarchy_definitions is drill metadata (no people), but it sat in a
-- schema with RLS off. Enable it for consistency; reads go via function.
alter table metrics.hierarchy_definitions enable row level security;

-- ---------------------------------------------------------------------
-- 3. Minimum cell size — defined once, used by every sensitive measure
-- ---------------------------------------------------------------------

create function metrics.minimum_cell_size()
returns integer language sql immutable
set search_path = ''
as $$ select 5; $$;

comment on function metrics.minimum_cell_size() is
  'Minimum population below which any aggregate of a personal attribute is suppressed (SEM-9, NFR-5).';

-- ---------------------------------------------------------------------
-- 4. Re-declare every client-callable measure as SECURITY DEFINER,
--    with suppression where the aggregate exposes a personal attribute.
-- ---------------------------------------------------------------------

create or replace function metrics.reporting_boundary()
returns date language sql stable
security definer set search_path = ''
as $$
  select coalesce(
    greatest(
      (select max(termination_date) from public.employees),
      (select max(hire_date) from public.employees),
      (select max(event_date) from public.compensation_events),
      (select max(effective_date) from public.performance_reviews),
      (select max(close_date) from public.requisitions),
      (select max(response_date)::date from public.engagement_responses)
    ),
    current_date
  );
$$;

-- Headcount is org structure, not a personal attribute, and small real
-- units exist (Executive = 1). Not suppressed; the residual differencing
-- risk this leaves open is documented rather than papered over.
create or replace function metrics.active_headcount(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  select case when count(*) = 0
    then row('no_data', null, 'No employees match this filter.', 0)::metrics.metric_result
    else row('value', count(*), null, count(*))::metrics.metric_result end
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

create or replace function metrics.voluntary_attrition_rate_ttm(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_boundary date := metrics.reporting_boundary();
  v_window_start date := metrics.reporting_boundary() - interval '12 months';
  v_terms integer; v_start_hc integer; v_end_hc integer; v_avg_hc numeric;
begin
  select count(*) into v_terms from metrics.dim_employee e
  where e.termination_type = 'Voluntary'
    and e.termination_date between v_window_start and v_boundary
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  select count(*) into v_start_hc from metrics.dim_employee e
  where e.hire_date <= v_window_start
    and (e.termination_date is null or e.termination_date > v_window_start)
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  select count(*) into v_end_hc from metrics.dim_employee e
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
  -- A rate over a handful of people discloses those individuals' outcomes.
  if v_avg_hc < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Population below the disclosure threshold; suppressed to protect anonymity.',
      v_avg_hc::integer)::metrics.metric_result;
  end if;

  return row('value', round((v_terms / v_avg_hc) * 100, 1), null, v_terms)::metrics.metric_result;
end;
$$;

create or replace function metrics.involuntary_attrition_count_ttm(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_pop integer; v_count integer;
begin
  select count(*) into v_pop from metrics.dim_employee e
  where (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_pop < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Population below the disclosure threshold; suppressed to protect anonymity.',
      v_pop)::metrics.metric_result;
  end if;

  select count(*) into v_count from metrics.dim_employee e
  where e.termination_type = 'Involuntary'
    and e.termination_date between metrics.reporting_boundary() - interval '12 months'
                               and metrics.reporting_boundary()
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  return row('value', v_count, null, v_count)::metrics.metric_result;
end;
$$;

create or replace function metrics.median_compa_ratio(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
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
  -- A median over n<5 is a near-direct read of an individual's pay position.
  if v_n < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.',
      v_n)::metrics.metric_result;
  end if;

  return row('value', round(v_median, 2), null, v_n)::metrics.metric_result;
end;
$$;

create or replace function metrics.elevated_flight_risk_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_pop integer; v_count integer;
begin
  -- Suppress on the DENOMINATOR: "1 of 2 people here is a flight risk"
  -- identifies a person even though the reported figure is a count.
  select count(*) into v_pop from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_pop = 0 then
    return row('no_data', null, 'No active employees match this filter.', 0)::metrics.metric_result;
  end if;
  if v_pop < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 employees in this cut; suppressed to protect anonymity.',
      v_pop)::metrics.metric_result;
  end if;

  select count(*) into v_count from metrics.dim_employee e
  where e.employment_status = 'Active' and e.flight_risk_rating = 'High'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  return row('value', v_count, null, v_count)::metrics.metric_result;
end;
$$;

create or replace function metrics.engagement_survey_mean(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_mean numeric; v_n integer;
begin
  select avg(s.score), count(distinct r.response_id) into v_mean, v_n
  from public.engagement_responses r
  join public.engagement_response_scores s on s.response_id = r.response_id
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
    and (p_level_band is null or r.level_band = any(p_level_band))
    and (p_tenure_band is null or r.tenure_band = any(p_tenure_band));

  if v_n is null or v_n = 0 then
    return row('no_data', null, 'No engagement survey responses in this filter.', 0)::metrics.metric_result;
  end if;
  if v_n < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 responses in this cut; suppressed to protect anonymity.',
      v_n)::metrics.metric_result;
  end if;

  return row('value', round(v_mean, 2), null, v_n)::metrics.metric_result;
end;
$$;

create or replace function metrics.engagement_employee_mean(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_mean numeric; v_n integer;
begin
  select avg(e.latest_engagement_score), count(e.latest_engagement_score)
  into v_mean, v_n
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.latest_engagement_score is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_n is null or v_n = 0 then
    return row('no_data', null, 'No per-employee engagement scores loaded for this filter.', 0)::metrics.metric_result;
  end if;
  if v_n < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 employees in this cut; suppressed to protect anonymity.',
      v_n)::metrics.metric_result;
  end if;

  return row('value', round(v_mean, 2), null, v_n)::metrics.metric_result;
end;
$$;

create or replace function metrics.open_requisitions_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from public.requisitions r
  where r.outcome = 'Open'
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));
$$;

create or replace function metrics.headcount_trend(p_months integer default 12)
returns table (period date, headcount integer)
language sql stable security definer set search_path = ''
as $$
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
  group by m.month_end order by m.month_end;
$$;

create or replace function metrics.composition_by_function(p_status text default 'Active')
returns table (function text, headcount integer)
language sql stable security definer set search_path = ''
as $$
  select e.function, count(*)::integer
  from metrics.employee_lifecycle e
  where e.employment_status = p_status
  group by e.function order by count(*) desc;
$$;

create or replace function metrics.attrition_by_type_ttm()
returns table (voluntary integer, involuntary integer)
language sql stable security definer set search_path = ''
as $$
  select count(*) filter (where termination_type = 'Voluntary')::integer,
         count(*) filter (where termination_type = 'Involuntary')::integer
  from metrics.employee_lifecycle
  where termination_date between metrics.reporting_boundary() - interval '12 months'
                             and metrics.reporting_boundary();
$$;

create or replace function metrics.recruiting_funnel_stages()
returns table (stage_order integer, stage_name text, candidate_count integer)
language sql stable security definer set search_path = ''
as $$
  select stage_order, stage_name, sum(candidate_count)::integer
  from public.funnel_events
  group by stage_order, stage_name order by stage_order;
$$;

create or replace function metrics.engagement_by_category()
returns table (category text, mean_score double precision, n integer)
language sql stable security definer set search_path = ''
as $$
  select q.category, round(avg(s.score), 2)::double precision, count(*)::integer
  from public.engagement_response_scores s
  join public.engagement_questions q on q.question_id = s.question_id
  where q.category is not null and q.category <> 'Open-Ended'
  group by q.category
  having count(*) >= metrics.minimum_cell_size()
  order by avg(s.score) asc;
$$;

-- Replaces the client's direct SELECT on data_loads: exposes only the
-- two fields the freshness indicator needs, not file names or row counts.
create function metrics.data_freshness()
returns table (data_load_id text, loaded_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select data_load_id, loaded_at
  from public.data_loads order by loaded_at desc limit 1;
$$;

-- Drill metadata, exposed as a function so no table grant is needed.
create function metrics.drill_hierarchies()
returns table (hierarchy text, level_order integer, level_name text)
language sql stable security definer set search_path = ''
as $$
  select hierarchy, level_order, level_name
  from metrics.hierarchy_definitions order by hierarchy, level_order;
$$;

-- ---------------------------------------------------------------------
-- 5. Grant EXECUTE explicitly — this list is now the complete public API
-- ---------------------------------------------------------------------

grant execute on function metrics.reporting_boundary() to anon, authenticated;
grant execute on function metrics.minimum_cell_size() to anon, authenticated;
grant execute on function metrics.active_headcount(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.voluntary_attrition_rate_ttm(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.involuntary_attrition_count_ttm(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.median_compa_ratio(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.elevated_flight_risk_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.engagement_survey_mean(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.engagement_employee_mean(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.open_requisitions_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.headcount_trend(integer) to anon, authenticated;
grant execute on function metrics.composition_by_function(text) to anon, authenticated;
grant execute on function metrics.attrition_by_type_ttm() to anon, authenticated;
grant execute on function metrics.recruiting_funnel_stages() to anon, authenticated;
grant execute on function metrics.engagement_by_category() to anon, authenticated;
grant execute on function metrics.data_freshness() to anon, authenticated;
grant execute on function metrics.drill_hierarchies() to anon, authenticated;

comment on schema metrics is
  'Client-facing API. Aggregate functions only — no row-level access to any table containing people. Per-role RLS lands with authentication (PRD SEM-8).';

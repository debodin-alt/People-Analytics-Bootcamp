-- Workforce page measures (PRD §6.1 Page 2).
--
-- headcount_by_dimension is deliberately one function taking a dimension
-- name rather than six near-identical functions, per "define once, use
-- everywhere" (§1.3). The dimension is resolved through a CASE over a
-- fixed whitelist — never string-interpolated into dynamic SQL — so the
-- parameter cannot widen the query beyond the columns named here.

create function metrics.headcount_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, headcount integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_dimension not in ('function','career_level','level_band','office_location',
                         'work_arrangement','tenure_band','career_track','job_family') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location, work_arrangement, tenure_band, career_track, job_family';
  end if;

  return query
  select
    case p_dimension
      when 'function'         then e.function
      when 'career_level'     then e.career_level
      when 'level_band'       then e.level_band
      when 'office_location'  then e.office_location
      when 'work_arrangement' then e.work_arrangement
      when 'tenure_band'      then e.tenure_band
      when 'career_track'     then e.career_track
      when 'job_family'       then e.job_family
    end as label,
    count(*)::integer
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by 1
  order by 2 desc;
end;
$$;

-- Span-of-control buckets. PRD §5 defines the population as employees
-- with number_of_direct_reports > 0, and calls out "manager debt" —
-- exactly one direct report — as its own cut.
create function metrics.span_of_control_distribution(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (band text, band_order integer, managers integer)
language sql stable security definer set search_path = ''
as $$
  with mgr as (
    select e.number_of_direct_reports as n
    from metrics.dim_employee e
    where e.employment_status = 'Active'
      and e.number_of_direct_reports > 0
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select b.band, b.band_order, count(mgr.n)::integer
  from (values
    ('1 (manager debt)', 1, 1, 1),
    ('2-3',             2, 2, 3),
    ('4-6',             3, 4, 6),
    ('7-9',             4, 7, 9),
    ('10-12',           5, 10, 12),
    ('13+',             6, 13, 2147483647)
  ) as b(band, band_order, lo, hi)
  left join mgr on mgr.n between b.lo and b.hi
  group by b.band, b.band_order
  order by b.band_order;
$$;

create function metrics.manager_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.number_of_direct_reports > 0
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

-- Managers carrying exactly one direct report — an org-design smell the
-- PRD names explicitly rather than leaving to be inferred.
create function metrics.manager_debt_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.number_of_direct_reports = 1
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

create function metrics.median_span_of_control(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
begin
  select percentile_cont(0.5) within group (order by e.number_of_direct_reports), count(*)
  into v_median, v_n
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.number_of_direct_reports > 0
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_n = 0 or v_median is null then
    return row('no_data', null, 'No managers match this filter.', 0)::metrics.metric_result;
  end if;
  return row('value', round(v_median, 1), null, v_n)::metrics.metric_result;
end;
$$;

-- First-year population: the cohort most exposed to early attrition, and
-- the one the PRD asks to be called out on the tenure profile.
create function metrics.first_year_population(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.tenure_years < 1
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));
$$;

-- Monthly hires, exits and net change. Keyed to workforce_boundary() so
-- it cannot drift against the rest of the workforce page.
create function metrics.monthly_hires_exits(p_months integer default 12)
returns table (period date, hires integer, exits integer, net_change integer)
language sql stable security definer set search_path = ''
as $$
  with months as (
    select date_trunc('month', metrics.workforce_boundary())::date
             - (n || ' months')::interval as month_start
    from generate_series(0, p_months - 1) as n
  )
  select
    (m.month_start + interval '1 month' - interval '1 day')::date as period,
    count(*) filter (where h.hire_date >= m.month_start
                       and h.hire_date < m.month_start + interval '1 month')::integer as hires,
    count(*) filter (where h.termination_date >= m.month_start
                       and h.termination_date < m.month_start + interval '1 month')::integer as exits,
    (count(*) filter (where h.hire_date >= m.month_start
                       and h.hire_date < m.month_start + interval '1 month')
     - count(*) filter (where h.termination_date >= m.month_start
                         and h.termination_date < m.month_start + interval '1 month'))::integer as net_change
  from months m
  left join metrics.employee_lifecycle h
    on (h.hire_date >= m.month_start and h.hire_date < m.month_start + interval '1 month')
    or (h.termination_date >= m.month_start and h.termination_date < m.month_start + interval '1 month')
  group by m.month_start
  order by m.month_start;
$$;

grant execute on function metrics.headcount_by_dimension(text, text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.span_of_control_distribution(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.manager_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.manager_debt_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.median_span_of_control(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.first_year_population(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.monthly_hires_exits(integer) to anon, authenticated;

-- Gate measures by capability.
--
-- Being authenticated is not the same as being entitled. A viewer may see
-- that the company employs 820 people; they may not see the median
-- compa-ratio, an unadjusted pay comparison by gender, or who is flagged
-- a flight risk.
--
-- Two refusal styles, chosen for how each surface reads:
--   * Scalar measures return status 'unavailable' — the KPI tile renders
--     "N/A" rather than an error, which is what MetricResultStatus's
--     'unavailable' exists for.
--   * Table (chart) functions raise 42501 — a chart cannot express
--     "withheld" in its data, and returning an empty set would read as
--     "no such people", which is a different and misleading claim.
--
-- The UI also hides pages a role cannot use. That is convenience; THIS is
-- the control. A hidden nav item is not a permission model.

create function metrics.require_capability(p_capability text)
returns void language plpgsql stable security definer set search_path = ''
as $$
begin
  if not metrics.has_capability(p_capability) then
    raise exception 'This measure is not available for your role'
      using errcode = '42501', hint = 'Requires capability: ' || p_capability;
  end if;
end;
$$;

grant execute on function metrics.require_capability(text) to authenticated;

-- ---- compensation ---------------------------------------------------

create or replace function metrics.median_compa_ratio(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
begin
  if not metrics.has_capability('compensation') then
    return row('unavailable', null, 'Compensation measures are not available for your role.', null)::metrics.metric_result;
  end if;

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
  if v_n < metrics.minimum_cell_size() then
    return row('suppressed', null, 'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.', v_n)::metrics.metric_result;
  end if;
  return row('value', round(v_median, 2), null, v_n)::metrics.metric_result;
end;
$$;

create or replace function metrics.below_090_compa_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_pop integer; v_count integer;
begin
  if not metrics.has_capability('compensation') then
    return row('unavailable', null, 'Compensation measures are not available for your role.', null)::metrics.metric_result;
  end if;

  select count(*) into v_pop from metrics.dim_employee e
  where e.employment_status = 'Active' and e.compa_ratio is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_pop = 0 then
    return row('no_data', null, 'No compensation data for this filter.', 0)::metrics.metric_result;
  end if;
  if v_pop < metrics.minimum_cell_size() then
    return row('suppressed', null, 'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.', v_pop)::metrics.metric_result;
  end if;

  select count(*) into v_count from metrics.dim_employee e
  where e.employment_status = 'Active' and e.compa_ratio < 0.90
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  return row('value', v_count, null, v_count)::metrics.metric_result;
end;
$$;

create or replace function metrics.median_range_penetration(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
begin
  if not metrics.has_capability('compensation') then
    return row('unavailable', null, 'Compensation measures are not available for your role.', null)::metrics.metric_result;
  end if;

  select percentile_cont(0.5) within group (order by e.range_penetration), count(*)
  into v_median, v_n
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.range_penetration is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_n = 0 or v_median is null then
    return row('no_data', null, 'No range penetration data for this filter.', 0)::metrics.metric_result;
  end if;
  if v_n < metrics.minimum_cell_size() then
    return row('suppressed', null, 'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.', v_n)::metrics.metric_result;
  end if;
  return row('value', round(v_median * 100, 1), null, v_n)::metrics.metric_result;
end;
$$;

-- ---- sensitive attributes -------------------------------------------

create or replace function metrics.elevated_flight_risk_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_pop integer; v_count integer;
begin
  if not metrics.has_capability('sensitive_attributes') then
    return row('unavailable', null, 'Flight-risk indicators are not available for your role.', null)::metrics.metric_result;
  end if;

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
    return row('suppressed', null, 'Fewer than 5 employees in this cut; suppressed to protect anonymity.', v_pop)::metrics.metric_result;
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

-- ---- table functions: raise rather than return an empty set ----------

create or replace function metrics.compa_ratio_distribution(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (band text, band_order integer, employees integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('compensation');
  return query
  with pop as (
    select e.compa_ratio as cr
    from metrics.dim_employee e
    where e.employment_status = 'Active' and e.compa_ratio is not null
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select b.band, b.band_order, count(p.cr)::integer
  from (values
    ('< 0.80',1,-1.0,0.80),('0.80-0.90',2,0.80,0.90),('0.90-0.95',3,0.90,0.95),
    ('0.95-1.00',4,0.95,1.00),('1.00-1.05',5,1.00,1.05),('1.05-1.10',6,1.05,1.10),
    ('1.10-1.20',7,1.10,1.20),('1.20+',8,1.20,99.0)
  ) as b(band, band_order, lo, hi)
  left join pop p on p.cr >= b.lo and p.cr < b.hi
  group by b.band, b.band_order
  order by b.band_order;
end;
$$;

create or replace function metrics.pay_position_by_gender(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (gender text, median_compa double precision, employees integer, suppressed boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('sensitive_attributes');
  return query
  select
    e.gender,
    case when count(*) >= metrics.minimum_cell_size()
      then round(percentile_cont(0.5) within group (order by e.compa_ratio)::numeric, 3)::double precision end,
    count(*)::integer,
    (count(*) < metrics.minimum_cell_size())
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.compa_ratio is not null and e.gender is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by e.gender
  order by count(*) desc;
end;
$$;

-- ---- dimension cuts --------------------------------------------------
-- Guards prepended; bodies otherwise unchanged.

create or replace function metrics.headcount_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, headcount integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('dimension_cuts');
  if p_dimension not in ('function','career_level','level_band','office_location',
                         'work_arrangement','tenure_band','career_track','job_family') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location, work_arrangement, tenure_band, career_track, job_family';
  end if;

  return query
  select
    case p_dimension
      when 'function' then e.function when 'career_level' then e.career_level
      when 'level_band' then e.level_band when 'office_location' then e.office_location
      when 'work_arrangement' then e.work_arrangement when 'tenure_band' then e.tenure_band
      when 'career_track' then e.career_track when 'job_family' then e.job_family
    end as label,
    count(*)::integer
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by 1 order by 2 desc;
end;
$$;

create or replace function metrics.compa_ratio_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, median_compa double precision, employees integer, suppressed boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('compensation');
  if p_dimension not in ('function','career_level','level_band','office_location') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location';
  end if;

  return query
  with scoped as (
    select
      case p_dimension
        when 'function' then e.function when 'career_level' then e.career_level
        when 'level_band' then e.level_band when 'office_location' then e.office_location
      end as lbl,
      e.compa_ratio
    from metrics.dim_employee e
    where e.employment_status = 'Active' and e.compa_ratio is not null
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select
    s.lbl,
    case when count(*) >= metrics.minimum_cell_size()
      then round(percentile_cont(0.5) within group (order by s.compa_ratio)::numeric, 3)::double precision end,
    count(*)::integer,
    (count(*) < metrics.minimum_cell_size())
  from scoped s where s.lbl is not null
  group by s.lbl order by 2 desc nulls last;
end;
$$;

grant execute on function metrics.median_compa_ratio(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.below_090_compa_count(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.median_range_penetration(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.elevated_flight_risk_count(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.compa_ratio_distribution(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.pay_position_by_gender(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.headcount_by_dimension(text, text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.compa_ratio_by_dimension(text, text[], text[], text[], text[]) to authenticated;

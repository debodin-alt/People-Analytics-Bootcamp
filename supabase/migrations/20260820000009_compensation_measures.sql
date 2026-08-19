-- Compensation page measures (PRD §6.1 Page 4).

-- Compa-ratio distribution, banded to diverge around 1.00 (§10.3: a
-- diverging measure gets a diverging form with a neutral midpoint, never
-- a sequential ramp).
create function metrics.compa_ratio_distribution(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (band text, band_order integer, employees integer)
language sql stable security definer set search_path = ''
as $$
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
    ('< 0.80',      1, -1.0,  0.80),
    ('0.80-0.90',   2, 0.80,  0.90),
    ('0.90-0.95',   3, 0.90,  0.95),
    ('0.95-1.00',   4, 0.95,  1.00),
    ('1.00-1.05',   5, 1.00,  1.05),
    ('1.05-1.10',   6, 1.05,  1.10),
    ('1.10-1.20',   7, 1.10,  1.20),
    ('1.20+',       8, 1.20,  99.0)
  ) as b(band, band_order, lo, hi)
  left join pop p on p.cr >= b.lo and p.cr < b.hi
  group by b.band, b.band_order
  order by b.band_order;
$$;

-- Employees paid below 0.90 compa-ratio — the population the PRD calls
-- out explicitly, and the one a market-adjustment budget targets.
create function metrics.below_090_compa_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_pop integer; v_count integer;
begin
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
    return row('suppressed', null,
      'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.',
      v_pop)::metrics.metric_result;
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

create function metrics.median_range_penetration(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
begin
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
    return row('suppressed', null,
      'Fewer than 5 employees in this cut; suppressed to protect pay confidentiality.',
      v_n)::metrics.metric_result;
  end if;
  return row('value', round(v_median * 100, 1), null, v_n)::metrics.metric_result;
end;
$$;

-- Median compa-ratio by cut. Suppressed per cut, not just overall — an
-- unsuppressed small cut is exactly how an aggregate leaks an individual.
create function metrics.compa_ratio_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, median_compa double precision, employees integer, suppressed boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_dimension not in ('function','career_level','level_band','office_location') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location';
  end if;

  return query
  with scoped as (
    select
      case p_dimension
        when 'function'        then e.function
        when 'career_level'    then e.career_level
        when 'level_band'      then e.level_band
        when 'office_location' then e.office_location
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
      then round(percentile_cont(0.5) within group (order by s.compa_ratio)::numeric, 3)::double precision
    end,
    count(*)::integer,
    (count(*) < metrics.minimum_cell_size())
  from scoped s
  where s.lbl is not null
  group by s.lbl
  order by 2 desc nulls last;
end;
$$;

-- Unadjusted pay-position comparison by gender.
--
-- This is deliberately compa-ratio, not raw salary: compa-ratio is
-- already normalised against each employee's own salary range, so it is
-- comparable across levels and currencies without the FX conversion raw
-- salary would require (MAP-2). It is still UNADJUSTED — it does not
-- control for level, function, location or tenure, so a gap here is a
-- prompt to investigate, never evidence of discrimination. The UI must
-- carry that caveat; see the Methodology page.
create function metrics.pay_position_by_gender(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (gender text, median_compa double precision, employees integer, suppressed boolean)
language sql stable security definer set search_path = ''
as $$
  select
    e.gender,
    case when count(*) >= metrics.minimum_cell_size()
      then round(percentile_cont(0.5) within group (order by e.compa_ratio)::numeric, 3)::double precision
    end,
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
$$;

grant execute on function metrics.compa_ratio_distribution(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.below_090_compa_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.median_range_penetration(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.compa_ratio_by_dimension(text, text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.pay_position_by_gender(text[], text[], text[], text[]) to anon, authenticated;

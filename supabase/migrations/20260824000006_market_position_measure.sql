-- Market position measure (PRD §5: base_salary_usd ÷ ACI P50 for the
-- mapped function × apex level × tier).
--
-- Listed as a v0.1 metric but never surfaced, which is precisely why the
-- M8 mismapping stayed invisible for so long: a wrong number nobody
-- displays raises no complaints. A measure that nothing calls is not a
-- measure that works.
--
-- Reports coverage alongside the value. "Median market position 1.02" is
-- a different claim depending on whether it covers 90% of the filtered
-- population or 30%, and 279 active employees sit in functions ACI does
-- not publish at all — so coverage is part of the answer, not a footnote.

create function metrics.median_market_position(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_with integer; v_total integer;
begin
  if not metrics.has_capability('compensation') then
    return row('unavailable', null, 'Compensation measures are not available for your role.', null)::metrics.metric_result;
  end if;

  select
    percentile_cont(0.5) within group (order by e.market_position_p50)
      filter (where e.market_position_p50 is not null),
    count(*) filter (where e.market_position_p50 is not null),
    count(*)
  into v_median, v_with, v_total
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_total = 0 then
    return row('no_data', null, 'No active employees in this filter.', 0)::metrics.metric_result;
  end if;

  -- No benchmark for anyone in this cut. Distinct from "no data": the
  -- people exist, the published benchmark does not.
  if v_with = 0 then
    return row('unavailable', null,
      'No published market benchmark covers this population — the Apex survey does not publish these functions or levels.',
      v_total)::metrics.metric_result;
  end if;

  if v_with < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 benchmarked employees in this cut; suppressed to protect pay confidentiality.',
      v_with)::metrics.metric_result;
  end if;

  return row('value', round(v_median, 3),
    format('Covers %s of %s employees (%s%%); the remainder sit in functions or levels the benchmark does not publish.',
           v_with, v_total, round(100.0 * v_with / v_total, 0)),
    v_with)::metrics.metric_result;
end;
$$;

grant execute on function metrics.median_market_position(text[], text[], text[], text[]) to authenticated;

comment on function metrics.median_market_position(text[], text[], text[], text[]) is
  'Median of base_salary_usd / ACI P50 for the mapped function x apex level x tier (PRD §5). Resolves through level_map and pay_zone_map (MAP-1) and converts currency via fx_rates (MAP-2). Returns `unavailable` — never a fallback figure — where no benchmark is published, including M8, which sits above the Apex ladder''s top rung. Reports coverage in the reason, because a median over 30% of a population is a different claim from one over 90%.';

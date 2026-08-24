-- Fix: headcount_trend returned its series newest-first.
--
-- Taking the most recent N months needs `order by period desc limit N`,
-- but that ordering then leaked into the result, so the chart drew time
-- running right-to-left (2026-03 on the left, 2025-04 on the right).
-- Every value was correct and the shape was reversed, which is the kind
-- of defect a reader is most likely to misread as a real trend.
--
-- The LIMIT ordering now lives in a subquery and the outer select
-- re-sorts ascending, so "most recent 12" and "oldest first" stop
-- fighting each other.

create or replace function metrics.headcount_trend(
  p_months integer default 12,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (period date, headcount integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_tenure_band is not null and array_length(p_tenure_band, 1) > 0 then
    raise exception 'Headcount trend cannot be filtered by tenure band'
      using errcode = '22023',
            hint = 'Tenure band is derived from tenure, which changes over time, so applying it to a historical trend produces a misleading series. Clear the tenure filter to view the trend.';
  end if;

  return query
  select recent.period, recent.headcount
  from (
    select mv.period, sum(mv.headcount)::integer as headcount
    from metrics.mv_monthly_headcount mv
    where mv.period <= metrics.workforce_boundary()
      and (p_function is null or mv.function = any(p_function))
      and (p_location is null or mv.office_location = any(p_location))
      and (p_level_band is null or mv.level_band = any(p_level_band))
    group by mv.period
    order by mv.period desc
    limit p_months
  ) recent
  order by recent.period;
end;
$$;

grant execute on function metrics.headcount_trend(integer, text[], text[], text[], text[]) to authenticated;

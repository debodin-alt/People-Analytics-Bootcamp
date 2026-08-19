-- Attrition & Retention page measures (PRD §6.1 Page 3).
--
-- Voluntary, involuntary and regrettable stay three separate numbers
-- throughout (MET-3). No function here returns a blended "attrition"
-- figure, because once one exists someone will chart it.

-- Regrettable attrition (§5): a voluntary leaver who was performing well.
-- The definition spans two sources — the rating carried on the employee
-- record, and the talent designation from their most recent review — so
-- both are checked. Verified values: ratings 'Exceeded Expectations' /
-- 'Significantly Exceeded Expectations'; designations 'Top Talent' /
-- 'Strong Performer'.
create function metrics.regrettable_attrition_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable security definer set search_path = ''
as $$
  with latest_review as (
    select distinct on (pr.employee_id) pr.employee_id, pr.talent_designation
    from public.performance_reviews pr
    where pr.talent_designation is not null
    order by pr.employee_id, pr.effective_date desc
  ),
  regrettable as (
    select e.employee_id
    from metrics.dim_employee e
    left join latest_review lr on lr.employee_id = e.employee_id
    where e.termination_type = 'Voluntary'
      and e.termination_date between metrics.workforce_boundary() - interval '12 months'
                                 and metrics.workforce_boundary()
      and (
        e.current_perf_rating in ('Exceeded Expectations', 'Significantly Exceeded Expectations')
        or lr.talent_designation in ('Top Talent', 'Strong Performer')
      )
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select row('value', count(*), null, count(*))::metrics.metric_result from regrettable;
$$;

-- Attrition by cut. Returns counts AND a rate: "which functions lose
-- people fastest" is a rate question, and a raw count just re-ranks by
-- headcount. Denominator is average headcount over the window, matching
-- voluntary_attrition_rate_ttm so the page cannot disagree with itself.
create function metrics.attrition_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, voluntary integer, involuntary integer,
                 avg_headcount double precision, voluntary_rate double precision)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_boundary date := metrics.workforce_boundary();
  v_start date := metrics.workforce_boundary() - interval '12 months';
begin
  if p_dimension not in ('function','career_level','level_band','office_location','tenure_band') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location, tenure_band';
  end if;

  return query
  with scoped as (
    select
      case p_dimension
        when 'function'        then e.function
        when 'career_level'    then e.career_level
        when 'level_band'      then e.level_band
        when 'office_location' then e.office_location
        when 'tenure_band'     then e.tenure_band
      end as lbl,
      e.termination_type, e.termination_date, e.hire_date
    from metrics.dim_employee e
    where (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  )
  select
    s.lbl,
    count(*) filter (where s.termination_type = 'Voluntary'
                      and s.termination_date between v_start and v_boundary)::integer,
    count(*) filter (where s.termination_type = 'Involuntary'
                      and s.termination_date between v_start and v_boundary)::integer,
    ((count(*) filter (where s.hire_date <= v_start
                        and (s.termination_date is null or s.termination_date > v_start))
      + count(*) filter (where s.hire_date <= v_boundary
                          and (s.termination_date is null or s.termination_date > v_boundary))
     ) / 2.0)::double precision as avg_hc,
    case when (count(*) filter (where s.hire_date <= v_start
                                 and (s.termination_date is null or s.termination_date > v_start))
               + count(*) filter (where s.hire_date <= v_boundary
                                   and (s.termination_date is null or s.termination_date > v_boundary))
              ) = 0 then null
         else round((count(*) filter (where s.termination_type = 'Voluntary'
                                       and s.termination_date between v_start and v_boundary)
                     / ((count(*) filter (where s.hire_date <= v_start
                                           and (s.termination_date is null or s.termination_date > v_start))
                         + count(*) filter (where s.hire_date <= v_boundary
                                             and (s.termination_date is null or s.termination_date > v_boundary))
                        ) / 2.0)) * 100, 1)::double precision
    end
  from scoped s
  where s.lbl is not null
  group by s.lbl
  order by 2 desc;
end;
$$;

-- Stated leaving reasons, voluntary only. Involuntary reasons
-- (Performance, Misconduct, Restructure) are a different question and are
-- deliberately not blended in here.
create function metrics.attrition_reasons(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (reason text, leavers integer)
language sql stable security definer set search_path = ''
as $$
  select e.termination_reason, count(*)::integer
  from metrics.dim_employee e
  where e.termination_type = 'Voluntary'
    and e.termination_reason is not null
    and e.termination_date between metrics.workforce_boundary() - interval '12 months'
                               and metrics.workforce_boundary()
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by e.termination_reason
  order by count(*) desc;
$$;

-- Tenure hazard: at what tenure do people leave? Banded on tenure AT EXIT
-- (termination_date - hire_date), not on the tenure_band carried in the
-- dimension — for a leaver those can differ, and the curve is meaningless
-- if it bands people by anything other than their tenure when they left.
create function metrics.tenure_hazard(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null
) returns table (band text, band_order integer, leavers integer)
language sql stable security definer set search_path = ''
as $$
  with exits as (
    select ((e.termination_date - e.hire_date) / 365.25) as tenure_at_exit
    from metrics.dim_employee e
    where e.termination_type = 'Voluntary'
      and e.termination_date is not null
      and e.termination_date between metrics.workforce_boundary() - interval '12 months'
                                 and metrics.workforce_boundary()
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
  )
  select b.band, b.band_order, count(x.tenure_at_exit)::integer
  from (values
    ('<1 year',   1, 0.0,  1.0),
    ('1-3 years', 2, 1.0,  3.0),
    ('3-5 years', 3, 3.0,  5.0),
    ('5-8 years', 4, 5.0,  8.0),
    ('8+ years',  5, 8.0,  1000.0)
  ) as b(band, band_order, lo, hi)
  left join exits x on x.tenure_at_exit >= b.lo and x.tenure_at_exit < b.hi
  group by b.band, b.band_order
  order by b.band_order;
$$;

grant execute on function metrics.regrettable_attrition_count(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.attrition_by_dimension(text, text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.attrition_reasons(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.tenure_hazard(text[], text[], text[]) to anon, authenticated;

-- NOT built here: attrition grouped by manager_employee_id (PRD §8.2).
-- It is sound analysis, but "which manager loses the most people" is
-- individual performance data about that manager, and with no
-- authentication yet it would be world-readable through the browser key.
-- It belongs behind the role gate, alongside the other governance
-- surfaces, not on a public page.

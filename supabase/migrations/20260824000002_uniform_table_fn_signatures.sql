-- Normalise every chart measure to the standard 4-argument filter
-- signature (SEM-3).
--
-- The recruiting chart functions took (p_function, p_location) and
-- tenure_hazard took three arguments, while everything else took four.
-- That is the same mismatch that silently blanked three recruiting KPI
-- tiles earlier: the client calls every measure through one hook, so a
-- non-standard arity is not a smaller API, it is a measure the client
-- cannot call.
--
-- Arguments that do not apply are accepted and ignored — a requisition
-- has no level band or tenure band. One calling convention across the
-- whole semantic layer is worth more than each function advertising
-- exactly its own dimensions, because the alternative is a client that
-- must remember which measure takes which arguments.

drop function if exists metrics.requisition_status_counts(text[], text[]);
create function metrics.requisition_status_counts(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (outcome text, requisitions integer)
language sql stable security definer set search_path = ''
as $$
  select r.outcome, count(*)::integer
  from public.requisitions r
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
  group by r.outcome order by count(*) desc;
$$;

drop function if exists metrics.open_requisition_aging(text[], text[]);
create function metrics.open_requisition_aging(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (band text, band_order integer, requisitions integer)
language sql stable security definer set search_path = ''
as $$
  with open_reqs as (
    select (metrics.recruiting_boundary() - r.open_date) as days_open
    from public.requisitions r
    where r.outcome = 'Open'
      and (p_function is null or r.function = any(p_function))
      and (p_location is null or r.office_location = any(p_location))
  )
  select b.band, b.band_order, count(o.days_open)::integer
  from (values
    ('0-30 days',1,0,30),('31-60 days',2,31,60),('61-90 days',3,61,90),
    ('91-120 days',4,91,120),('120+ days',5,121,100000)
  ) as b(band, band_order, lo, hi)
  left join open_reqs o on o.days_open between b.lo and b.hi
  group by b.band, b.band_order order by b.band_order;
$$;

drop function if exists metrics.time_to_fill_by_dimension(text, text[], text[]);
create function metrics.time_to_fill_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, median_ttf double precision, reqs_filled integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_dimension not in ('function','level','office_location') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, level, office_location';
  end if;
  return query
  select
    case p_dimension
      when 'function' then r.function when 'level' then r.level
      when 'office_location' then r.office_location end,
    round(percentile_cont(0.5) within group (order by r.time_to_fill_days)::numeric, 0)::double precision,
    count(*)::integer
  from public.requisitions r
  where r.outcome in ('Filled', 'Filled (Internal Transfer)')
    and r.time_to_fill_days is not null
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
  group by 1 order by 2 desc;
end;
$$;

drop function if exists metrics.offer_decline_reasons(text[], text[]);
create function metrics.offer_decline_reasons(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (reason text, declines integer)
language sql stable security definer set search_path = ''
as $$
  select o.decline_reason, count(*)::integer
  from public.offers o
  where o.outcome = 'Declined' and o.decline_reason is not null
    and (p_function is null or o.function = any(p_function))
    and (p_location is null or o.office_location = any(p_location))
  group by o.decline_reason order by count(*) desc;
$$;

drop function if exists metrics.applications_by_source(text[], text[]);
create function metrics.applications_by_source(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (source text, applications integer)
language sql stable security definer set search_path = ''
as $$
  select a.source, sum(a.applications)::integer
  from public.application_sources a
  where (p_function is null or a.function = any(p_function))
    and (p_location is null or a.office_location = any(p_location))
  group by a.source order by sum(a.applications) desc;
$$;

drop function if exists metrics.funnel_with_conversion(text[], text[]);
create function metrics.funnel_with_conversion(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (stage_order integer, stage_name text, candidates integer, conversion_from_prev double precision)
language sql stable security definer set search_path = ''
as $$
  with stages as (
    select f.stage_order, f.stage_name, sum(f.candidate_count)::integer as candidates
    from public.funnel_events f
    where (p_function is null or f.function = any(p_function))
      and (p_location is null or f.office_location = any(p_location))
    group by f.stage_order, f.stage_name
  )
  select s.stage_order, s.stage_name, s.candidates,
    case when lag(s.candidates) over (order by s.stage_order) > 0
      then round((s.candidates::numeric / lag(s.candidates) over (order by s.stage_order)) * 100, 1)::double precision
    end
  from stages s order by s.stage_order;
$$;

drop function if exists metrics.tenure_hazard(text[], text[], text[]);
create function metrics.tenure_hazard(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
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
    ('<1 year',1,0.0,1.0),('1-3 years',2,1.0,3.0),('3-5 years',3,3.0,5.0),
    ('5-8 years',4,5.0,8.0),('8+ years',5,8.0,1000.0)
  ) as b(band, band_order, lo, hi)
  left join exits x on x.tenure_at_exit >= b.lo and x.tenure_at_exit < b.hi
  group by b.band, b.band_order order by b.band_order;
$$;

comment on function metrics.requisition_status_counts(text[], text[], text[], text[]) is
  'Requisitions by outcome. Open, On Hold and Cancelled are three different states and are reported separately, never rolled together. level_band and tenure_band accepted and ignored — a requisition has neither.';
comment on function metrics.open_requisition_aging(text[], text[], text[], text[]) is
  'Open requisitions banded by days open, aged against recruiting_boundary() rather than today''s date.';
comment on function metrics.time_to_fill_by_dimension(text, text[], text[], text[], text[]) is
  'Median days to fill per cut, filled requisitions only. Target 60 days for IC roles.';
comment on function metrics.offer_decline_reasons(text[], text[], text[], text[]) is
  'Stated reasons across declined offers.';
comment on function metrics.applications_by_source(text[], text[], text[], text[]) is
  'Applications by sourcing channel. Application volume, not hires.';
comment on function metrics.funnel_with_conversion(text[], text[], text[], text[]) is
  'Six-stage recruiting funnel with stage-to-stage conversion. Stage bars, never a trapezoid (§10.11).';
comment on function metrics.tenure_hazard(text[], text[], text[], text[]) is
  'Voluntary exits banded by tenure AT EXIT, computed from termination_date - hire_date rather than the current tenure band, which differs for a leaver. tenure_band filter accepted and ignored: filtering exits by current tenure band would contradict the banding the measure performs.';

grant execute on function metrics.requisition_status_counts(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.open_requisition_aging(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.time_to_fill_by_dimension(text, text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.offer_decline_reasons(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.applications_by_source(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.funnel_with_conversion(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.tenure_hazard(text[], text[], text[], text[]) to authenticated;

-- Recruiting page measures (PRD §6.1 Page 5).
--
-- These key off recruiting_boundary(), NOT workforce_boundary(). That
-- separation is the whole point of the domain split: recruiting data runs
-- two weeks later than the workforce extract in this load, and each
-- domain must age against its own vintage.
--
-- Requisition outcomes are reported separately throughout — Open (36),
-- On Hold (22) and Cancelled (31) are three different states of the world
-- and the PRD is explicit that they are never rolled together.

create function metrics.requisition_status_counts(
  p_function text[] default null, p_location text[] default null
) returns table (outcome text, requisitions integer)
language sql stable security definer set search_path = ''
as $$
  select r.outcome, count(*)::integer
  from public.requisitions r
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
  group by r.outcome
  order by count(*) desc;
$$;

-- Aging of currently-open reqs, measured against the recruiting boundary
-- rather than today's date (A11 boundary drift: "how long has this been
-- open" must age from the data, not the wall clock).
create function metrics.open_requisition_aging(
  p_function text[] default null, p_location text[] default null
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
    ('0-30 days',   1, 0,   30),
    ('31-60 days',  2, 31,  60),
    ('61-90 days',  3, 61,  90),
    ('91-120 days', 4, 91,  120),
    ('120+ days',   5, 121, 100000)
  ) as b(band, band_order, lo, hi)
  left join open_reqs o on o.days_open between b.lo and b.hi
  group by b.band, b.band_order
  order by b.band_order;
$$;

-- Filled reqs only: an open req has no time-to-fill, and including
-- unfilled ones as zero would flatter the measure badly.
create function metrics.median_time_to_fill(
  p_function text[] default null, p_location text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_median numeric; v_n integer;
begin
  select percentile_cont(0.5) within group (order by r.time_to_fill_days), count(*)
  into v_median, v_n
  from public.requisitions r
  where r.outcome in ('Filled', 'Filled (Internal Transfer)')
    and r.time_to_fill_days is not null
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));

  if v_n = 0 or v_median is null then
    return row('no_data', null, 'No filled requisitions in this filter.', 0)::metrics.metric_result;
  end if;
  return row('value', round(v_median, 0), null, v_n)::metrics.metric_result;
end;
$$;

create function metrics.time_to_fill_by_dimension(
  p_dimension text,
  p_function text[] default null, p_location text[] default null
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
      when 'function'        then r.function
      when 'level'           then r.level
      when 'office_location' then r.office_location
    end as lbl,
    round(percentile_cont(0.5) within group (order by r.time_to_fill_days)::numeric, 0)::double precision,
    count(*)::integer
  from public.requisitions r
  where r.outcome in ('Filled', 'Filled (Internal Transfer)')
    and r.time_to_fill_days is not null
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
  group by 1
  order by 2 desc;
end;
$$;

-- offers_accepted / offers_made per PRD §5. Computed from the requisition
-- rollup rather than the offers table: the offers table counts every
-- offer including repeats on the same req, which answers a different
-- question than "did our first offer land".
create function metrics.first_offer_acceptance_rate(
  p_function text[] default null, p_location text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_made integer; v_accepted integer;
begin
  select coalesce(sum(r.offers_made), 0), coalesce(sum(r.offers_accepted), 0)
  into v_made, v_accepted
  from public.requisitions r
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));

  if v_made = 0 then
    return row('no_data', null, 'No offers made in this filter.', 0)::metrics.metric_result;
  end if;
  return row('value', round((v_accepted::numeric / v_made) * 100, 1), null, v_made)::metrics.metric_result;
end;
$$;

create function metrics.offer_decline_reasons(
  p_function text[] default null, p_location text[] default null
) returns table (reason text, declines integer)
language sql stable security definer set search_path = ''
as $$
  select o.decline_reason, count(*)::integer
  from public.offers o
  where o.outcome = 'Declined' and o.decline_reason is not null
    and (p_function is null or o.function = any(p_function))
    and (p_location is null or o.office_location = any(p_location))
  group by o.decline_reason
  order by count(*) desc;
$$;

create function metrics.applications_by_source(
  p_function text[] default null, p_location text[] default null
) returns table (source text, applications integer)
language sql stable security definer set search_path = ''
as $$
  select a.source, sum(a.applications)::integer
  from public.application_sources a
  where (p_function is null or a.function = any(p_function))
    and (p_location is null or a.office_location = any(p_location))
  group by a.source
  order by sum(a.applications) desc;
$$;

-- Six-stage funnel with stage-to-stage conversion. Drawn as stage bars,
-- never a trapezoid — a trapezoid lies about proportion (§10.3, §10.11).
create function metrics.funnel_with_conversion(
  p_function text[] default null, p_location text[] default null
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
  select
    s.stage_order, s.stage_name, s.candidates,
    case when lag(s.candidates) over (order by s.stage_order) > 0
      then round((s.candidates::numeric / lag(s.candidates) over (order by s.stage_order)) * 100, 1)::double precision
    end
  from stages s
  order by s.stage_order;
$$;

grant execute on function metrics.requisition_status_counts(text[], text[]) to anon, authenticated;
grant execute on function metrics.open_requisition_aging(text[], text[]) to anon, authenticated;
grant execute on function metrics.median_time_to_fill(text[], text[]) to anon, authenticated;
grant execute on function metrics.time_to_fill_by_dimension(text, text[], text[]) to anon, authenticated;
grant execute on function metrics.first_offer_acceptance_rate(text[], text[]) to anon, authenticated;
grant execute on function metrics.offer_decline_reasons(text[], text[]) to anon, authenticated;
grant execute on function metrics.applications_by_source(text[], text[]) to anon, authenticated;
grant execute on function metrics.funnel_with_conversion(text[], text[]) to anon, authenticated;

-- NOT built here: recruiter productivity (PRD §6.1 Page 5). The source
-- table carries recruiter_name and per-recruiter fill rates — individual
-- performance data about twelve named people, which would be
-- world-readable through the browser key until authentication exists.
-- Same reasoning as manager-level attrition; both belong behind the role
-- gate.

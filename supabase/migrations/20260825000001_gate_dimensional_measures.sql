-- Gate the remaining dimensional measures on `dimension_cuts`.
--
-- Found by pointing the Wizard at the semantic layer as a viewer. A viewer
-- holds exactly one capability, `company_aggregates`, and the dashboard hides
-- every breakdown page from them — yet asking the Wizard to "break down
-- headcount by function" returned a full 14-row cut, because only
-- headcount_by_dimension actually refused. Six other dimensional measures
-- answered a role that should not see them.
--
-- This predates the Wizard: any authenticated user could always have called
-- these directly over PostgREST. What the Wizard changes is that doing so is
-- now routine and conversational, which is exactly why this platform's rule
-- is that UI hiding is convenience and the measures refusing is the control.
-- Seven measures were relying on the convenience.
--
-- Only viewers lose anything — manager, executive and admin all hold
-- dimension_cuts, and viewers were already barred from the pages these feed.
--
-- Mechanics differ by language, and conflating the two is a real hazard: an
-- earlier attempt wrapped every body in RETURN QUERY, which silently produced
-- `return query declare ... begin` for the functions that were already
-- plpgsql. So:
--   language sql     -> re-declared as plpgsql, original query returned via
--                       RETURN QUERY behind the gate.
--   language plpgsql -> gate inserted after the existing top-level BEGIN,
--                       body otherwise untouched.
-- Every body comes from pg_get_functiondef; none is retyped.


create or replace function metrics.applications_by_source(p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(source text, applications integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
    select a.source, sum(a.applications)::integer
      from public.application_sources a
      where (p_function is null or a.function = any(p_function))
        and (p_location is null or a.office_location = any(p_location))
      group by a.source order by sum(a.applications) desc;
end
$fn$;

create or replace function metrics.attrition_by_dimension(p_dimension text, p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(label text, voluntary integer, involuntary integer, avg_headcount double precision, voluntary_rate double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
declare
  v_boundary date := metrics.workforce_boundary();
  v_start date := metrics.workforce_boundary() - interval '12 months';
begin
  perform metrics.require_capability('dimension_cuts');
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
end
$fn$;

create or replace function metrics.composition_by_function(p_status text DEFAULT 'Active'::text, p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(function text, headcount integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
    select e.function, count(*)::integer
      from metrics.dim_employee e
      where e.employment_status = p_status
        and (p_function is null or e.function = any(p_function))
        and (p_location is null or e.office_location = any(p_location))
        and (p_level_band is null or e.level_band = any(p_level_band))
        and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
      group by e.function order by count(*) desc;
end
$fn$;

create or replace function metrics.engagement_by_category(p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(category text, mean_score double precision, n integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
    select q.category, round(avg(s.score), 2)::double precision, count(*)::integer
      from public.engagement_response_scores s
      join public.engagement_questions q on q.question_id = s.question_id
      join public.engagement_responses r on r.response_id = s.response_id
      where q.category is not null and q.category <> 'Open-Ended'
        and (p_function is null or r.function = any(p_function))
        and (p_location is null or r.office_location = any(p_location))
        and (p_level_band is null or r.level_band = any(p_level_band))
        and (p_tenure_band is null or r.tenure_band = any(p_tenure_band))
      group by q.category
      having count(*) >= metrics.minimum_cell_size()
      order by avg(s.score) asc;
end
$fn$;

create or replace function metrics.engagement_by_cohort(p_dimension text, p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(label text, mean_score double precision, respondents integer, suppressed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
  if p_dimension not in ('function','department','level_band','tenure_band','office_location') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, department, level_band, tenure_band, office_location';
  end if;

  return query
  with scoped as (
    select
      case p_dimension
        when 'function'        then r.function
        when 'department'      then r.department
        when 'level_band'      then r.level_band
        when 'tenure_band'     then r.tenure_band
        when 'office_location' then r.office_location
      end as lbl,
      r.response_id, s.score
    from public.engagement_responses r
    join public.engagement_response_scores s on s.response_id = r.response_id
    where (p_function is null or r.function = any(p_function))
      and (p_location is null or r.office_location = any(p_location))
      and (p_level_band is null or r.level_band = any(p_level_band))
      and (p_tenure_band is null or r.tenure_band = any(p_tenure_band))
  )
  select
    sc.lbl,
    case when count(distinct sc.response_id) >= metrics.minimum_cell_size()
      then round(avg(sc.score), 2)::double precision
    end,
    count(distinct sc.response_id)::integer,
    (count(distinct sc.response_id) < metrics.minimum_cell_size())
  from scoped sc
  where sc.lbl is not null
  group by sc.lbl
  order by 2 asc nulls last;  -- worst-scoring cohorts first: the PRD asks
                              -- for cohorts below the mean surfaced, not buried
end
$fn$;

create or replace function metrics.span_of_control_distribution(p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(band text, band_order integer, managers integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
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
end
$fn$;

create or replace function metrics.time_to_fill_by_dimension(p_dimension text, p_function text[] DEFAULT NULL::text[], p_location text[] DEFAULT NULL::text[], p_level_band text[] DEFAULT NULL::text[], p_tenure_band text[] DEFAULT NULL::text[])
 RETURNS TABLE(label text, median_ttf double precision, reqs_filled integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $fn$
begin
  perform metrics.require_capability('dimension_cuts');
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
end
$fn$;

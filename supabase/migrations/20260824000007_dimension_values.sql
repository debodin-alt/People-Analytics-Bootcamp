-- The vocabulary of each conformed dimension, read from the data.
--
-- Until now this list lived only in src/lib/constants.ts, hand-transcribed
-- from the Meridian workbook. That is survivable for a fixed synthetic
-- dataset and indefensible for a real one: the day a company adds a
-- function or renames an office, the filter bar keeps offering the old
-- vocabulary and nobody finds out until a filter silently matches nothing.
--
-- The Wizard forces the issue. A model composing filters needs to know
-- that the value is 'Data & Analytics' and not 'Data Analytics' or
-- 'Analytics'; guessing produces a confident answer over an empty
-- population, which is the single worst failure mode this platform has.
-- So the vocabulary becomes a measure like everything else.
--
-- Ordering is deliberate per dimension. Tenure and level bands are ordinal
-- — alphabetising them puts '<1 year' after '8+ years' and destroys the
-- sequence — so they sort by their declared order, not their labels.

create function metrics.dimension_values(p_dimension text)
returns table (value text, employee_count integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_dimension not in ('function','career_level','level_band','office_location',
                         'work_arrangement','tenure_band','career_track','job_family') then
    raise exception 'Unknown dimension: %', p_dimension
      using hint = 'Allowed: function, career_level, level_band, office_location, work_arrangement, tenure_band, career_track, job_family';
  end if;

  return query
  with labelled as (
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
      end as v
    from metrics.dim_employee e
    where e.employment_status = 'Active'
  )
  select
    l.v::text,
    count(*)::integer
  from labelled l
  where l.v is not null
  group by l.v
  order by
    -- Ordinal dimensions keep their real sequence; everything else sorts
    -- by size, so the model sees the dominant values first.
    case p_dimension
      when 'tenure_band' then array_position(
        array['<1 year','1-3 years','3-5 years','5-8 years','8+ years'], l.v)
      when 'level_band' then array_position(
        array['Entry / Mid IC','Senior IC','Staff+ IC','First-Line Manager',
              'Sr Manager','Director','VP+'], l.v)
      when 'career_level' then array_position(
        array['P1','P2','P3','P4','P5','P6','P7',
              'M3','M4','M5','M6','M7','M8'], l.v)
    end nulls last,
    count(*) desc,
    l.v;
end;
$$;

grant execute on function metrics.dimension_values(text) to authenticated;

comment on function metrics.dimension_values(text) is
  'The distinct active-population values of a conformed dimension, with counts, ordered by declared sequence for ordinal dimensions and by size otherwise. The single source of the filter vocabulary — the UI filter bar and the Wizard both read it, so neither can offer a value the data no longer contains.';

-- Structural metadata, not a measure: it belongs beside drill_hierarchies
-- in the exclusion list rather than on the Methodology page, which
-- documents numbers.
create or replace function metrics.metric_catalog()
returns table (
  measure text,
  arguments text,
  returns_metric_result boolean,
  definition text
)
language sql stable security definer set search_path = ''
as $$
  select
    p.proname::text,
    pg_catalog.pg_get_function_arguments(p.oid)::text,
    (pg_catalog.pg_get_function_result(p.oid) = 'metrics.metric_result'),
    coalesce(d.description, '')::text
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  left join pg_catalog.pg_description d on d.objoid = p.oid
  where n.nspname = 'metrics'
    and p.proname not in (
      -- catalog and refresh plumbing
      'metric_catalog', 'refresh_aggregates', 'minimum_cell_size',
      -- freshness and structural metadata, not measures
      'data_freshness', 'data_vintage', 'drill_hierarchies', 'dimension_values',
      -- identity, capability and row-scope plumbing
      'current_app_role', 'current_employee_id', 'current_session_context',
      'has_capability', 'require_capability', 'visible_employee_ids'
    )
  order by p.proname;
$$;

grant execute on function metrics.metric_catalog() to authenticated;

-- dimension_values was left out of 20260825000001's capability sweep.
--
-- Same defect class as the seven measures gated there: a viewer holds only
-- `company_aggregates`, but dimension_values answered anyway, handing back
-- a full active-population breakdown (with counts) by function, level,
-- location, tenure, career track or job family for any authenticated
-- caller. Found in a security review ahead of a real-data pilot, not by
-- the Wizard this time — but the fix and the reasoning are identical to
-- 20260825000001's: UI hiding is convenience, the measure refusing is the
-- control, and this one was still relying on the convenience.

create or replace function metrics.dimension_values(p_dimension text)
returns table (value text, employee_count integer)
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

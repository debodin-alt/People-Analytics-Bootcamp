-- Engagement page measures (PRD §6.1 Page 6).
--
-- engagement_responses carries NO employee key — anonymity is structural,
-- not a policy layered on top (NFR-6). These measures therefore aggregate
-- only, and every cohort cut enforces minimum cell size: with 720
-- responses across function x level x tenure x location, narrow cuts
-- reach single respondents quickly, and a mean over one respondent IS
-- that respondent's answers.
--
-- MET-2 is a hard constraint on how the page presents these: the survey
-- (1-5 Likert, aggregate) and the per-employee score (0-10) are DIFFERENT
-- INSTRUMENTS. They are never averaged together and never share an axis.

create function metrics.engagement_by_cohort(
  p_dimension text,
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (label text, mean_score double precision, respondents integer, suppressed boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
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
end;
$$;

-- Open-ended theme frequency. Returns theme CODES and counts only — never
-- response_text. The verbatims carry function, level band, tenure band
-- and location alongside free text, which in combination re-identifies
-- people; the themes are the analysable artefact, the raw text is not
-- something a dashboard should hand out.
create function metrics.engagement_theme_frequency(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (theme_code text, mentions integer, suppressed boolean)
language sql stable security definer set search_path = ''
as $$
  select
    o.theme_code,
    count(*)::integer,
    (count(*) < metrics.minimum_cell_size())
  from public.engagement_open_ended o
  where (p_function is null or o.function = any(p_function))
    and (p_location is null or o.office_location = any(p_location))
    and (p_level_band is null or o.level_band = any(p_level_band))
    and (p_tenure_band is null or o.tenure_band = any(p_tenure_band))
  group by o.theme_code
  having count(*) >= metrics.minimum_cell_size()
  order by count(*) desc;
$$;

-- Survey participation: responses against active headcount. Approximate
-- by construction — the survey is anonymous, so responses cannot be
-- matched to the roster, and the denominator is headcount at the current
-- boundary rather than at survey close.
create function metrics.survey_participation_rate(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_responses integer; v_headcount integer;
begin
  select count(*) into v_responses
  from public.engagement_responses r
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location))
    and (p_level_band is null or r.level_band = any(p_level_band))
    and (p_tenure_band is null or r.tenure_band = any(p_tenure_band));

  select count(*) into v_headcount
  from metrics.dim_employee e
  where e.employment_status = 'Active'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_headcount = 0 then
    return row('no_data', null, 'No active employees in this filter.', 0)::metrics.metric_result;
  end if;
  if v_responses < metrics.minimum_cell_size() then
    return row('suppressed', null,
      'Fewer than 5 responses in this cut; suppressed to protect anonymity.',
      v_responses)::metrics.metric_result;
  end if;
  return row('value', round((v_responses::numeric / v_headcount) * 100, 1), null, v_responses)::metrics.metric_result;
end;
$$;

grant execute on function metrics.engagement_by_cohort(text, text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.engagement_theme_frequency(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.survey_participation_rate(text[], text[], text[], text[]) to anon, authenticated;

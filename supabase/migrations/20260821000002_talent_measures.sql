-- Talent & Performance page measures (PRD §6.1 Page 7).
--
-- Filed as Day 3 in the PRD's build column, but the underlying data is
-- fully loaded and the page was sitting in the nav as a dead link, which
-- is worse than either building it or hiding it.
--
-- Rating distribution is computed over ANNUAL reviews only. The table
-- also holds 90-Day and other review types on a different rating basis;
-- mixing them would move the distribution without any change in
-- performance, and the PRD's own reference figures are annual-only
-- (3,149 reviews).
--
-- All measures gated on dimension_cuts and suppressed below minimum cell
-- size: a rating distribution over three people discloses those people's
-- ratings.

-- Ratings are inherently ordered, so the order travels with the data
-- rather than being reconstructed in each caller (§10.5).
create function metrics.rating_distribution(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (rating text, rating_order integer, reviews integer, pct double precision, suppressed boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare v_total integer;
begin
  perform metrics.require_capability('dimension_cuts');

  select count(*) into v_total
  from public.performance_reviews pr
  join metrics.dim_employee e on e.employee_id = pr.employee_id
  where pr.review_type = 'Annual'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  return query
  select r.rating, r.rating_order,
         count(pr.review_id)::integer,
         case when v_total >= metrics.minimum_cell_size()
           then round(100.0 * count(pr.review_id) / nullif(v_total, 0), 1)::double precision end,
         (v_total < metrics.minimum_cell_size())
  from (values
    ('Did Not Meet', 1), ('Partially Met Expectations', 2), ('Met Expectations', 3),
    ('Exceeded Expectations', 4), ('Significantly Exceeded Expectations', 5)
  ) as r(rating, rating_order)
  left join (
    select pr2.review_id, pr2.final_rating
    from public.performance_reviews pr2
    join metrics.dim_employee e on e.employee_id = pr2.employee_id
    where pr2.review_type = 'Annual'
      and (p_function is null or e.function = any(p_function))
      and (p_location is null or e.office_location = any(p_location))
      and (p_level_band is null or e.level_band = any(p_level_band))
      and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  ) pr on pr.final_rating = r.rating
  group by r.rating, r.rating_order
  order by r.rating_order;
end;
$$;

-- Share of annual reviews whose rating moved in calibration. A high rate
-- is not automatically bad — calibration exists to move ratings — but a
-- rate near zero suggests calibration is ceremonial.
create function metrics.calibration_adjustment_rate(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_total integer; v_adjusted integer;
begin
  if not metrics.has_capability('dimension_cuts') then
    return row('unavailable', null, 'Performance measures are not available for your role.', null)::metrics.metric_result;
  end if;

  select count(*), count(*) filter (where pr.calibration_adjusted = 'Yes')
  into v_total, v_adjusted
  from public.performance_reviews pr
  join metrics.dim_employee e on e.employee_id = pr.employee_id
  where pr.review_type = 'Annual'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_total = 0 then
    return row('no_data', null, 'No annual reviews in this filter.', 0)::metrics.metric_result;
  end if;
  if v_total < metrics.minimum_cell_size() then
    return row('suppressed', null, 'Fewer than 5 reviews in this cut; suppressed to protect confidentiality.', v_total)::metrics.metric_result;
  end if;
  return row('value', round((v_adjusted::numeric / v_total) * 100, 1), null, v_total)::metrics.metric_result;
end;
$$;

-- Promotion pipeline. 'Approved Not Effective' is its own outcome and is
-- deliberately not folded into either promoted or declined: an approval
-- that never took effect is the interesting case, and merging it in
-- either direction hides it.
create function metrics.promotion_pipeline(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (outcome text, reviews integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
  select pr.promotion_outcome, count(*)::integer
  from public.performance_reviews pr
  join metrics.dim_employee e on e.employee_id = pr.employee_id
  where pr.promotion_outcome is not null and pr.promotion_outcome <> 'N/A'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by pr.promotion_outcome
  having count(*) >= metrics.minimum_cell_size()
  order by count(*) desc;
end;
$$;

create function metrics.promotion_recommended_count(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_count integer;
begin
  if not metrics.has_capability('dimension_cuts') then
    return row('unavailable', null, 'Performance measures are not available for your role.', null)::metrics.metric_result;
  end if;

  select count(*) into v_count
  from public.performance_reviews pr
  join metrics.dim_employee e on e.employee_id = pr.employee_id
  where pr.promotion_recommended = 'Yes'
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band));

  if v_count < metrics.minimum_cell_size() then
    return row('suppressed', null, 'Fewer than 5 in this cut; suppressed to protect confidentiality.', v_count)::metrics.metric_result;
  end if;
  return row('value', v_count, null, v_count)::metrics.metric_result;
end;
$$;

create function metrics.competency_means(
  p_competency_type text default 'Universal',
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (competency_id text, competency_name text, mean_score double precision, scores integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('dimension_cuts');
  if p_competency_type not in ('Universal', 'Leadership', 'Functional') then
    raise exception 'Unknown competency type: %', p_competency_type
      using hint = 'Allowed: Universal, Leadership, Functional';
  end if;

  return query
  select cs.competency_id, cs.competency_name,
         round(avg(cs.score), 2)::double precision, count(*)::integer
  from public.competency_scores cs
  join metrics.dim_employee e on e.employee_id = cs.employee_id
  where cs.competency_type = p_competency_type
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by cs.competency_id, cs.competency_name
  having count(*) >= metrics.minimum_cell_size()
  order by avg(cs.score) asc;
end;
$$;

create function metrics.nine_box_distribution(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns table (placement text, employees integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform metrics.require_capability('dimension_cuts');
  return query
  select e.nine_box_placement, count(*)::integer
  from metrics.dim_employee e
  where e.employment_status = 'Active' and e.nine_box_placement is not null
    and (p_function is null or e.function = any(p_function))
    and (p_location is null or e.office_location = any(p_location))
    and (p_level_band is null or e.level_band = any(p_level_band))
    and (p_tenure_band is null or e.tenure_band = any(p_tenure_band))
  group by e.nine_box_placement
  having count(*) >= metrics.minimum_cell_size()
  order by e.nine_box_placement;
end;
$$;

grant execute on function metrics.rating_distribution(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.calibration_adjustment_rate(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.promotion_pipeline(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.promotion_recommended_count(text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.competency_means(text, text[], text[], text[], text[]) to authenticated;
grant execute on function metrics.nine_box_distribution(text[], text[], text[], text[]) to authenticated;

comment on function metrics.rating_distribution(text[], text[], text[], text[]) is
  'Final-rating distribution across ANNUAL reviews only — 90-Day and other review types use a different basis and mixing them would move the distribution without any change in performance. PRD §8.2 reference: 3% Did Not Meet, 13% Partially Met, 49% Met, 26% Exceeded, 9% Significantly Exceeded across 3,149 annual reviews.';
comment on function metrics.calibration_adjustment_rate(text[], text[], text[], text[]) is
  'Share of annual reviews whose rating moved in calibration. PRD §8.1 reference: 485 of 3,149 = 15%. A high rate is not inherently bad — calibration exists to move ratings — but a rate near zero suggests the process is ceremonial.';
comment on function metrics.promotion_pipeline(text[], text[], text[], text[]) is
  'Promotion outcomes. PRD §8.2 reference: 312 recommended, 170 promoted, 75 Approved Not Effective. The Approved-Not-Effective outcome is kept separate rather than folded into promoted or declined — an approval that never took effect is the interesting case, and merging it hides it.';
comment on function metrics.promotion_recommended_count(text[], text[], text[], text[]) is
  'Reviews recommending promotion. PRD §8.2 reference: 312.';
comment on function metrics.competency_means(text, text[], text[], text[], text[]) is
  'Mean competency score by competency, for one competency type. PRD §8.2 reference: U03 "Communicates with Clarity" is the lowest universal at 3.27.';
comment on function metrics.nine_box_distribution(text[], text[], text[], text[]) is
  'Active employees by nine-box placement. Placements with fewer than 5 employees are withheld.';

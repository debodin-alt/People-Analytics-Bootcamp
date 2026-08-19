-- Give the recruiting scalar measures the standard 4-argument filter
-- signature (SEM-3: "every measure accepts the standard filter-context
-- object").
--
-- median_time_to_fill, offer_acceptance_rate and first_offer_landed_rate
-- took only (p_function, p_location). The client calls every scalar
-- measure through one hook that sends all four filter params, so
-- PostgREST could not resolve them and all three tiles rendered as "—".
-- open_requisitions_count already had the uniform signature and worked,
-- which is what made the cause obvious.
--
-- level_band and tenure_band are accepted and ignored: they are employee
-- dimensions and a requisition has neither. Accepting-and-ignoring keeps
-- one calling convention across the whole semantic layer; the alternative
-- is a client that must remember which measures take which arguments,
-- which is exactly the coupling the uniform contract exists to prevent.

drop function if exists metrics.median_time_to_fill(text[], text[]);
drop function if exists metrics.offer_acceptance_rate(text[], text[]);
drop function if exists metrics.first_offer_landed_rate(text[], text[]);
drop function if exists metrics.first_offer_acceptance_rate(text[], text[]);

create function metrics.median_time_to_fill(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
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

create function metrics.offer_acceptance_rate(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
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

create function metrics.first_offer_landed_rate(
  p_function text[] default null, p_location text[] default null,
  p_level_band text[] default null, p_tenure_band text[] default null
) returns metrics.metric_result
language plpgsql stable security definer set search_path = ''
as $$
declare v_filled integer; v_one_offer integer;
begin
  select
    count(*) filter (where r.outcome in ('Filled', 'Filled (Internal Transfer)')),
    count(*) filter (where r.outcome in ('Filled', 'Filled (Internal Transfer)') and r.offers_made = 1)
  into v_filled, v_one_offer
  from public.requisitions r
  where (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));

  if v_filled = 0 then
    return row('no_data', null, 'No filled requisitions in this filter.', 0)::metrics.metric_result;
  end if;
  return row('value', round((v_one_offer::numeric / v_filled) * 100, 1), null, v_filled)::metrics.metric_result;
end;
$$;

comment on function metrics.offer_acceptance_rate(text[], text[], text[], text[]) is
  'Offers accepted / offers extended (PRD §5 formula). Repeat offers weigh the denominator. Reads 68.5% on the reference dataset. level_band and tenure_band are accepted and ignored — a requisition has neither.';
comment on function metrics.first_offer_landed_rate(text[], text[], text[], text[]) is
  'Share of filled requisitions filled on a single offer. Reads 85.6% against the PRD''s printed 87%; the gap is not explained by any scoping we could identify. level_band and tenure_band are accepted and ignored.';

grant execute on function metrics.median_time_to_fill(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.offer_acceptance_rate(text[], text[], text[], text[]) to anon, authenticated;
grant execute on function metrics.first_offer_landed_rate(text[], text[], text[], text[]) to anon, authenticated;

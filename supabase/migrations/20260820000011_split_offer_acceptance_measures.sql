-- Split offer acceptance into the two measures the PRD conflates.
--
-- PRD §5 names the metric "First-offer acceptance", gives the formula
-- offers_accepted ÷ offers_made, and prints 87%. Those describe two
-- different things, and neither reproduces 87% exactly:
--
--   offers_accepted / offers_made ................ 68.5%  (222/324)
--   filled on a single offer / filled reqs ....... 85.6%  (190/222)
--   ... excluding internal transfers ............. 84.2%  (170/202)
--
-- The stated formula is the OVERALL offer acceptance rate: it divides
-- every accepted offer by every offer extended, so a req that needed
-- three offers before one landed counts three times in the denominator.
-- That is a real and useful measure, but it is not "first-offer
-- acceptance" — which asks how often the first offer lands, and is the
-- reading the metric's name and its printed 87% both point at.
--
-- Rather than pick one and quietly disagree with either the PRD's formula
-- or its number, both are implemented under names that say what they
-- compute. The residual 1.4pp against the printed 87% is unexplained by
-- any scoping we can find and is recorded rather than fitted to.

comment on function metrics.first_offer_acceptance_rate(text[], text[]) is
  'SUPERSEDED by offer_acceptance_rate (same computation, honest name). Retained only so existing callers do not break.';

-- Overall: every accepted offer over every offer extended. This is the
-- PRD's stated formula.
create function metrics.offer_acceptance_rate(
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

comment on function metrics.offer_acceptance_rate(text[], text[]) is
  'Offers accepted / offers extended (PRD §5 formula). Counts a requisition once per offer, so repeat offers weigh the denominator. Reads 68.5% on the reference dataset.';

-- First offer: of the requisitions we filled, how often did the first
-- offer land? Filled reqs only — an unfilled req has no first offer to
-- have been accepted or refused, and counting it either way is wrong.
create function metrics.first_offer_landed_rate(
  p_function text[] default null, p_location text[] default null
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

comment on function metrics.first_offer_landed_rate(text[], text[]) is
  'Share of filled requisitions filled on a single offer. Reads 85.6% on the reference dataset against the PRD''s printed 87%; the 1.4pp gap is not explained by any scoping we could identify.';

grant execute on function metrics.offer_acceptance_rate(text[], text[]) to anon, authenticated;
grant execute on function metrics.first_offer_landed_rate(text[], text[]) to anon, authenticated;

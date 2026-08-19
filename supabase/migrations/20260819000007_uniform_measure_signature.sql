-- open_requisitions_count only took p_function/p_location, breaking the
-- uniform 4-arg calling convention every other measure follows (SEM-3 —
-- "every measure accepts the standard filter-context object"). The extra
-- two params are accepted and ignored (requisitions has no level_band or
-- tenure_band dimension), which keeps the client-side RPC caller generic
-- instead of special-casing this one measure.

drop function metrics.open_requisitions_count(text[], text[]);

create function metrics.open_requisitions_count(
  p_function text[] default null,
  p_location text[] default null,
  p_level_band text[] default null,
  p_tenure_band text[] default null
) returns metrics.metric_result
language sql stable as $$
  select row('value', count(*), null, count(*))::metrics.metric_result
  from public.requisitions r
  where r.outcome = 'Open'
    and (p_function is null or r.function = any(p_function))
    and (p_location is null or r.office_location = any(p_location));
$$;

grant execute on function metrics.open_requisitions_count(text[], text[], text[], text[]) to anon, authenticated;

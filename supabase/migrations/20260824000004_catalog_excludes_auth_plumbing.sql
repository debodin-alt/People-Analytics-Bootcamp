-- Keep the metric catalog to actual measures.
--
-- Found by the new regression suite, which asserts MET-1 (every measure
-- carries a definition) and reported five undocumented entries. They were
-- not measures that lost their comments — they were the authentication
-- helpers added later, which the catalog's exclusion list predated and so
-- never covered. A reader of the Methodology page does not need a
-- methodology entry for has_capability.
--
-- Both halves are worth doing: exclude them from the user-facing catalog
-- because they are not numbers, and comment them anyway so nothing in the
-- schema is undocumented for whoever reads it next.

comment on function metrics.current_employee_id() is
  'The employee record the calling user is mapped to, or NULL if unmapped. Row scope derives from this.';
comment on function metrics.current_session_context() is
  'The caller''s own role, employee mapping and capabilities, so the UI can hide what it must not offer. UI hiding is convenience; the measures refusing is the control.';
comment on function metrics.has_capability(text) is
  'Whether the calling user''s role holds a capability, per the metrics.role_capabilities grid.';
comment on function metrics.require_capability(text) is
  'Raises 42501 unless the caller holds the capability. Used by chart measures, where an empty result set would read as "no such people" rather than "withheld".';
comment on function metrics.visible_employee_ids() is
  'The single definition of which employees the caller may see individually: all for admin and executive, own reporting tree for manager (recursive, depth-guarded), self for viewer, none without a role. Every row-level rule derives from here.';

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
      'data_freshness', 'data_vintage', 'drill_hierarchies',
      -- identity, capability and row-scope plumbing
      'current_app_role', 'current_employee_id', 'current_session_context',
      'has_capability', 'require_capability', 'visible_employee_ids'
    )
  order by p.proname;
$$;

grant execute on function metrics.metric_catalog() to authenticated;

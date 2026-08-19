-- reporting_boundary() included data_loads.loaded_at in its GREATEST,
-- which is ingestion time (when the load script ran), not data vintage —
-- it pulled the derived boundary to today's wall-clock date instead of
-- the data's actual latest activity (~April 2026), silently shrinking the
-- TTM window and undercounting voluntary attrition (54 vs the correct 73,
-- verified against total termination_type='Voluntary' rows). Replaced
-- with fact-table dates only, including employees.termination_date and
-- hire_date which were missing from the original definition entirely.

create or replace function metrics.reporting_boundary()
returns date
language sql
stable
as $$
  select coalesce(
    greatest(
      (select max(termination_date) from public.employees),
      (select max(hire_date) from public.employees),
      (select max(event_date) from public.compensation_events),
      (select max(effective_date) from public.performance_reviews),
      (select max(close_date) from public.requisitions),
      (select max(response_date)::date from public.engagement_responses)
    ),
    current_date
  );
$$;

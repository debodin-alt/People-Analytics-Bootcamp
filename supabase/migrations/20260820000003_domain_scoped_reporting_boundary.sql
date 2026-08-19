-- Scope the reporting boundary to the domain it measures.
--
-- THE DEFECT
-- reporting_boundary() took GREATEST across every fact table, so the
-- single latest date anywhere in the platform set the TTM window for
-- every metric. In this dataset exactly one requisition (REQ-2026-5001)
-- closes 2026-05-08 — two weeks past the recruiting extract's own stated
-- snapshot date of 2026-04-24, and 16 days past the last workforce event.
-- That one row dragged the attrition window forward and pushed two real
-- voluntary terminations out the back of it:
--
--   boundary 2026-05-08 (cross-domain)  -> 71 of 73 voluntary terms
--   boundary 2026-04-22 (workforce)     -> 73 of 73  <- PRD §5 reference
--
-- A requisition closing late is not evidence that we have complete
-- workforce data through that date. Deriving the window from the data
-- (PRD §2.3) is right; deriving it from *unrelated* data is not.
--
-- THE FIX
-- Two domain-scoped boundaries. Workforce, attrition and compensation
-- measures key off the people facts; recruiting measures key off the
-- requisition facts. Each domain stays internally consistent and cannot
-- be perturbed by an outlier in another.
--
-- reporting_boundary() is retained as the platform's headline as-of date
-- and now resolves to the workforce boundary — every existing caller is
-- a workforce measure, and this is a people analytics platform, so the
-- people-data vintage is the honest headline. Where the two differ the
-- Methodology page must state both rather than imply one freshness.

create or replace function metrics.workforce_boundary()
returns date language sql stable
security definer set search_path = ''
as $$
  select coalesce(
    greatest(
      (select max(termination_date) from public.employees),
      (select max(hire_date) from public.employees),
      (select max(event_date) from public.compensation_events),
      (select max(effective_date) from public.performance_reviews),
      (select max(response_date)::date from public.engagement_responses)
    ),
    current_date
  );
$$;

comment on function metrics.workforce_boundary() is
  'Latest people-fact date: headcount, attrition, compensation, performance, engagement. Drives every workforce TTM window.';

create or replace function metrics.recruiting_boundary()
returns date language sql stable
security definer set search_path = ''
as $$
  select coalesce(
    greatest(
      (select max(open_date) from public.requisitions),
      (select max(close_date) from public.requisitions),
      (select max(offer_date) from public.offers)
    ),
    current_date
  );
$$;

comment on function metrics.recruiting_boundary() is
  'Latest requisition-fact date. Drives recruiting TTM windows only — deliberately separate from the workforce boundary.';

-- Headline as-of date. Resolves to the workforce boundary; see the
-- rationale above.
create or replace function metrics.reporting_boundary()
returns date language sql stable
security definer set search_path = ''
as $$
  select metrics.workforce_boundary();
$$;

comment on function metrics.reporting_boundary() is
  'Platform headline as-of date = workforce_boundary(). Recruiting measures must use recruiting_boundary() instead.';

grant execute on function metrics.workforce_boundary() to anon, authenticated;
grant execute on function metrics.recruiting_boundary() to anon, authenticated;

-- mv_monthly_headcount derives its month range from reporting_boundary(),
-- so its last bucket moves with this change. Refresh (not CONCURRENTLY —
-- the range itself changes, and this runs inside the migration).
refresh materialized view metrics.mv_monthly_headcount;

-- Metric catalog for the Methodology page (PRD §6.1 Page 11, MET-1).
--
-- Reads the definitions straight out of pg_description rather than
-- restating them in the UI. Documentation that lives beside the code it
-- documents cannot drift from it — and the variances recorded on these
-- functions (the attrition denominator, the two offer-acceptance
-- readings) are exactly the things a reader must not have to discover by
-- reconciling the dashboard against the PRD by hand.

create function metrics.metric_catalog()
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
    -- Internal plumbing rather than a reportable measure.
    and p.proname not in ('metric_catalog', 'refresh_aggregates', 'minimum_cell_size')
  order by p.proname;
$$;

-- Both boundaries, deliberately exposed together. Where they differ, the
-- Methodology page must say so rather than implying one freshness for the
-- whole platform.
create function metrics.data_vintage()
returns table (domain text, boundary date, note text)
language sql stable security definer set search_path = ''
as $$
  select 'Workforce'::text, metrics.workforce_boundary(),
         'Headcount, attrition, compensation, performance, engagement. Drives every workforce TTM window.'::text
  union all
  select 'Recruiting'::text, metrics.recruiting_boundary(),
         'Requisitions and offers. Deliberately separate — a late requisition must not move the attrition window.'::text;
$$;

grant execute on function metrics.metric_catalog() to anon, authenticated;
grant execute on function metrics.data_vintage() to anon, authenticated;

-- Backfill definitions for the measures that did not already carry one,
-- so the catalog is complete rather than half-populated.
comment on function metrics.active_headcount(text[], text[], text[], text[]) is
  'Employees with employment_status = Active, including those on leave. PRD §5: 820 on the reference dataset. Not suppressed — headcount is org structure, and small real units exist (Executive = 1).';
comment on function metrics.involuntary_attrition_count_ttm(text[], text[], text[], text[]) is
  'Involuntary terminations in the trailing 12 months from workforce_boundary(). Reported separately from voluntary and never blended (MET-3). PRD §5: 27.';
comment on function metrics.regrettable_attrition_count(text[], text[], text[], text[]) is
  'Voluntary leavers whose last rating was Exceeded / Significantly Exceeded, OR whose most recent talent designation was Top Talent / Strong Performer. Spans two sources because the PRD definition does.';
comment on function metrics.median_compa_ratio(text[], text[], text[], text[]) is
  'Median of base_salary / salary_range_mid across active employees. PRD §5: 1.00. Suppressed below 5 employees — a median over a handful is a near-direct read of an individual''s pay position.';
comment on function metrics.below_090_compa_count(text[], text[], text[], text[]) is
  'Active employees paid below 0.90 compa-ratio — the population a market adjustment targets. PRD §5: 60.';
comment on function metrics.elevated_flight_risk_count(text[], text[], text[], text[]) is
  'Active employees with flight_risk_rating = High. A DISPLAYED FIELD from the source data, not a model output — this platform computes no predictive risk score. PRD §5: 42. Suppressed on the denominator, so "1 of 2" cannot identify a person.';
comment on function metrics.engagement_survey_mean(text[], text[], text[], text[]) is
  'Mean of the 30 Likert items, scale 1-5, from the anonymous survey. Aggregate only — engagement_responses carries no employee key. PRD §5: 3.66. A DIFFERENT INSTRUMENT from the per-employee score; never averaged with it (MET-2).';
comment on function metrics.engagement_employee_mean(text[], text[], text[], text[]) is
  'Mean of latest_engagement_score across active employees, scale 0-10. PRD §5: 7.33. A DIFFERENT INSTRUMENT from the survey mean; never averaged with it and never sharing an axis (MET-2).';
comment on function metrics.open_requisitions_count(text[], text[], text[], text[]) is
  'Requisitions with outcome = Open. On Hold (22) and Cancelled (31) are separate states and are never rolled in. PRD §5: 36.';
comment on function metrics.median_time_to_fill(text[], text[], text[], text[]) is
  'Median close_date - open_date across FILLED requisitions only; an open req has no time-to-fill and counting it as zero would flatter the measure. Target 60 days for IC roles.';
comment on function metrics.workforce_boundary() is
  'Latest people-fact date: headcount, attrition, compensation, performance, engagement. Drives every workforce TTM window. Derived from the data (PRD §2.3), never hardcoded.';
comment on function metrics.recruiting_boundary() is
  'Latest requisition-fact date. Deliberately separate from the workforce boundary: one requisition closing late must not move the attrition window.';
comment on function metrics.headcount_trend(integer) is
  'Point-in-time headcount at each month end, read from the mv_monthly_headcount materialised aggregate (NFR-2). Reconstructed from hire and termination dates.';
comment on function metrics.pay_position_by_gender(text[], text[], text[], text[]) is
  'UNADJUSTED median compa-ratio by gender. Does not control for level, function, location or tenure, so it is NOT a like-for-like comparison and a difference is NOT evidence of pay discrimination. Compa-ratio rather than salary so levels and currencies compare without FX conversion (MAP-2). Suppressed below 5.';
comment on function metrics.tenure_hazard(text[], text[], text[]) is
  'Voluntary exits banded by tenure AT EXIT, computed from termination_date - hire_date. Deliberately not the tenure_band carried in the dimension: for a leaver those differ, and the curve is meaningless banded any other way.';
comment on function metrics.engagement_theme_frequency(text[], text[], text[], text[]) is
  'Counts of People-team-assigned theme codes across open-ended responses. Exposes codes and counts only, never response_text — free text alongside function, level, tenure and location re-identifies people.';
comment on function metrics.survey_participation_rate(text[], text[], text[], text[]) is
  'Survey responses over active headcount. Approximate by construction: the survey is anonymous so responses cannot be matched to the roster, and the denominator is headcount at the current boundary rather than at survey close.';

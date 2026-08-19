-- Complete the metric catalog (MET-1: every number rendered anywhere in
-- the product traces to a definition reachable from beside it).
--
-- The catalog built in the previous migration immediately reported 26 of
-- 47 measures undocumented — which is the argument for generating it from
-- pg_description rather than maintaining a hand-written list that quietly
-- falls behind the code.
--
-- Also narrows the catalog to actual MEASURES: data_freshness,
-- data_vintage and drill_hierarchies are infrastructure the UI calls, not
-- numbers a reader needs a definition for.

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
      'metric_catalog', 'refresh_aggregates', 'minimum_cell_size',
      'data_freshness', 'data_vintage', 'drill_hierarchies'
    )
  order by p.proname;
$$;

grant execute on function metrics.metric_catalog() to anon, authenticated;

-- Workforce
comment on function metrics.headcount_by_dimension(text, text[], text[], text[], text[]) is
  'Active headcount grouped by one of a fixed set of dimensions (function, career_level, level_band, office_location, work_arrangement, tenure_band, career_track, job_family). The dimension is resolved through a whitelist, never interpolated into SQL.';
comment on function metrics.composition_by_function(text) is
  'Headcount by function for a given employment status. Sums to total headcount for that status.';
comment on function metrics.manager_count(text[], text[], text[], text[]) is
  'Active employees with at least one direct report. PRD §5: ~115.';
comment on function metrics.manager_debt_count(text[], text[], text[], text[]) is
  'Active managers carrying exactly one direct report — an org-design signal the PRD names explicitly rather than leaving to be inferred.';
comment on function metrics.median_span_of_control(text[], text[], text[], text[]) is
  'Median direct reports among employees who have at least one. Employees with no reports are excluded, not counted as zero.';
comment on function metrics.span_of_control_distribution(text[], text[], text[], text[]) is
  'Managers banded by direct-report count, with the single-report band ("manager debt") called out as its own band.';
comment on function metrics.first_year_population(text[], text[], text[], text[]) is
  'Active employees with under one year of tenure — the cohort most exposed to early attrition.';
comment on function metrics.monthly_hires_exits(integer) is
  'Hires, exits and net change per calendar month, keyed to workforce_boundary(). Hires and exits are opposing flows and are never stacked into a combined total.';

-- Attrition
comment on function metrics.attrition_by_dimension(text, text[], text[], text[], text[]) is
  'Voluntary and involuntary counts plus a voluntary RATE per cut. The rate matters because "which functions lose people fastest" is a rate question — ranking by raw count just re-ranks by headcount. Denominator is average headcount over the window, matching voluntary_attrition_rate_ttm so the page cannot disagree with itself.';
comment on function metrics.attrition_by_type_ttm() is
  'Voluntary and involuntary termination counts in the trailing 12 months, returned as two separate figures. Never summed into a single attrition number (MET-3).';
comment on function metrics.attrition_reasons(text[], text[], text[], text[]) is
  'Stated leaving reasons for VOLUNTARY leavers only. Involuntary reasons (Performance, Misconduct, Restructure) answer a different question and are deliberately not blended in. PRD §5: Better Opportunity 25, Career Growth 12, Compensation 10, Manager Issues 7.';

-- Compensation
comment on function metrics.compa_ratio_distribution(text[], text[], text[], text[]) is
  'Active employees banded by compa-ratio, diverging around 1.00 (parity with the salary-range midpoint). Sums to active headcount.';
comment on function metrics.compa_ratio_by_dimension(text, text[], text[], text[], text[]) is
  'Median compa-ratio per cut. Suppression is applied PER CUT, not just overall — an unsuppressed small cut is precisely how an aggregate leaks an individual''s pay.';
comment on function metrics.median_range_penetration(text[], text[], text[], text[]) is
  'Median (base - range_min) / (range_max - range_min), expressed as a percentage. ACI treats 60-80% as the healthy band. Suppressed below 5 employees.';

-- Recruiting
comment on function metrics.requisition_status_counts(text[], text[]) is
  'Requisitions by outcome. Open, On Hold and Cancelled are three different states of the world and are reported separately, never rolled together.';
comment on function metrics.open_requisition_aging(text[], text[]) is
  'Currently-open requisitions banded by days open, aged against recruiting_boundary() rather than today''s date — "how long has this been open" must age from the data, not the wall clock.';
comment on function metrics.time_to_fill_by_dimension(text, text[], text[]) is
  'Median days to fill per cut, filled requisitions only. Target is 60 days for IC roles.';
comment on function metrics.funnel_with_conversion(text[], text[]) is
  'Six-stage recruiting funnel with stage-to-stage conversion. Drawn as stage bars, never a trapezoid — a trapezoid lies about proportion (§10.11).';
comment on function metrics.recruiting_funnel_stages() is
  'SUPERSEDED by funnel_with_conversion, which adds stage-to-stage conversion and filter support. Retained only so existing callers do not break.';
comment on function metrics.applications_by_source(text[], text[]) is
  'Applications by sourcing channel. Application volume, not hires — source quality (which channels produce hires who stay and perform) is Tier 2 analysis and is not computed here.';
comment on function metrics.offer_decline_reasons(text[], text[]) is
  'Stated reasons across declined offers.';

-- Engagement
comment on function metrics.engagement_by_category() is
  'Mean survey score per question category, 1-5 Likert. Categories with fewer than 5 responses are excluded entirely.';
comment on function metrics.engagement_by_cohort(text, text[], text[], text[], text[]) is
  'Mean survey score per cohort, 1-5 Likert, ordered worst-first so cohorts below the company mean surface rather than being buried. Suppressed below 5 respondents: a mean over one respondent IS that respondent''s answers.';

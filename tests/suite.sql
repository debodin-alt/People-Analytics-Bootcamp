-- Meridian regression suite.
--
-- Runs inside a single transaction that always ROLLS BACK, so the role
-- impersonation and app_users mutations used to exercise the permission
-- model leave no trace. Emits one row per assertion; the runner fails the
-- build if any row has pass = false.
--
-- Two things this suite is deliberately built to catch:
--
--   1. Metric drift. PRD §5 and §8 publish exact reference values for
--      this dataset. Every one of them is asserted here, so a change to a
--      measure that moves a number announces itself instead of being
--      discovered by eye months later.
--
--   2. The specific defects found while building. Each bug that shipped
--      and had to be fixed gets an assertion, because a bug found once by
--      luck will otherwise be found again the same way. Those are tagged
--      REGRESSION with the defect they lock down.

begin;

create temp table results (
  section text,
  test text,
  expected text,
  actual text
) on commit drop;

-- Impersonate the configured admin. Looked up rather than hardcoded so
-- the suite runs against any environment.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', (select auth_user_id from public.app_users where app_role = 'admin' and is_active limit 1))::text,
  true
);

-- ---------------------------------------------------------------------
-- 1. Metric reconciliation against the PRD's published figures
-- ---------------------------------------------------------------------

insert into results values
  ('metrics', 'active headcount (PRD §5)', '820',
    (select value::text from metrics.active_headcount())),

  ('metrics', 'voluntary terminations TTM (PRD §5)', '73',
    (select population_count::text from metrics.voluntary_attrition_rate_ttm())),

  ('metrics', 'involuntary terminations TTM (PRD §5)', '27',
    (select value::text from metrics.involuntary_attrition_count_ttm())),

  ('metrics', 'median compa-ratio (PRD §5)', '1.00',
    (select value::text from metrics.median_compa_ratio())),

  ('metrics', 'paid below 0.90 compa (PRD §5)', '60',
    (select value::text from metrics.below_090_compa_count())),

  ('metrics', 'elevated flight risk (PRD §5)', '42',
    (select value::text from metrics.elevated_flight_risk_count())),

  ('metrics', 'open requisitions (PRD §5)', '36',
    (select value::text from metrics.open_requisitions_count())),

  ('metrics', 'engagement survey mean, 1-5 (PRD §5)', '3.66',
    (select value::text from metrics.engagement_survey_mean())),

  ('metrics', 'engagement per-employee mean, 0-10 (PRD §5)', '7.33',
    (select value::text from metrics.engagement_employee_mean())),

  ('metrics', 'people managers (PRD §5 ~115)', '115',
    (select value::text from metrics.manager_count())),

  ('metrics', 'annual reviews (PRD §8.1)', '3149',
    (select sum(reviews)::text from metrics.rating_distribution())),

  ('metrics', 'calibration adjustment rate (PRD §8.1 485/3149)', '15.4',
    (select value::text from metrics.calibration_adjustment_rate())),

  ('metrics', 'promotions recommended (PRD §8.2)', '312',
    (select value::text from metrics.promotion_recommended_count())),

  ('metrics', 'promoted (PRD §8.2)', '170',
    (select reviews::text from metrics.promotion_pipeline() where outcome = 'Promoted')),

  ('metrics', 'approved not effective (PRD §8.2)', '75',
    (select reviews::text from metrics.promotion_pipeline() where outcome = 'Approved Not Effective')),

  ('metrics', 'market position resolves where benchmarked (Engineering)', 'value',
    (select status from metrics.median_market_position(array['Engineering']))),

  ('metrics', 'weakest universal competency (PRD §8.2 U03 @ 3.27)', 'U03 3.27',
    (select competency_id || ' ' || mean_score from metrics.competency_means('Universal') limit 1)),

  ('metrics', 'leaving reason Better Opportunity (PRD §8.1)', '25',
    (select leavers::text from metrics.attrition_reasons() where reason like '%Better Opportunity%')),

  ('metrics', 'requisition states Open/OnHold/Cancelled (PRD §5)', '36/22/31',
    (select string_agg(requisitions::text, '/' order by array_position(array['Open','On Hold','Cancelled'], outcome))
     from metrics.requisition_status_counts() where outcome in ('Open','On Hold','Cancelled'))),

  ('metrics', 'rating distribution shape (PRD §8.2)', '105/420/1539/814/271',
    (select string_agg(reviews::text, '/' order by rating_order) from metrics.rating_distribution()));

-- Internal consistency: a dimension cut must account for every person.
insert into results values
  ('consistency', 'headcount by function sums to total', '820',
    (select sum(headcount)::text from metrics.headcount_by_dimension('function'))),
  ('consistency', 'headcount by tenure band sums to total', '820',
    (select sum(headcount)::text from metrics.headcount_by_dimension('tenure_band'))),
  ('consistency', 'compa distribution sums to total', '820',
    (select sum(employees)::text from metrics.compa_ratio_distribution())),
  ('consistency', 'attrition by function sums to voluntary total', '73',
    (select sum(voluntary)::text from metrics.attrition_by_dimension('function'))),
  ('consistency', 'tenure hazard sums to voluntary total', '73',
    (select sum(leavers)::text from metrics.tenure_hazard()));

-- Domain-scoped boundaries must stay separate.
insert into results values
  ('boundaries', 'workforce boundary is people-fact latest', '2026-04-22',
    (select metrics.workforce_boundary()::text)),
  ('boundaries', 'recruiting boundary is req-fact latest', '2026-05-08',
    (select metrics.recruiting_boundary()::text)),
  ('boundaries', 'headline boundary tracks workforce', 'true',
    (select (metrics.reporting_boundary() = metrics.workforce_boundary())::text));

-- ---------------------------------------------------------------------
-- 2. REGRESSION — defects that shipped once already
-- ---------------------------------------------------------------------

-- Defect: ORDER BY driving the LIMIT leaked into the result, so the trend
-- drew time right-to-left. Values correct, shape reversed.
insert into results values
  ('regression', 'headcount trend is chronological, not newest-first', 'true',
    (select (array_agg(period order by rn))[1] < (array_agg(period order by rn))[array_length(array_agg(period order by rn),1)] from
       (select period, row_number() over () rn from metrics.headcount_trend(6)) t)::text);

-- Defect: a tenure filter on a historical trend produces a confident
-- wrong series. Must refuse, not silently ignore.
do $$
declare v_ok text := 'false';
begin
  begin
    perform * from metrics.headcount_trend(6, null, null, null, array['<1 year']);
  exception when others then
    v_ok := 'true';
  end;
  insert into results values ('regression', 'headcount trend refuses tenure filter', 'true', v_ok);
end $$;

-- Defect: filters were accepted by measures but never passed, so charts
-- showed company-wide data beside filtered tiles. A filtered cut must
-- differ from the unfiltered one.
insert into results values
  ('regression', 'filters actually narrow chart measures', 'true',
    (select (
      (select sum(headcount) from metrics.headcount_by_dimension('function', array['Engineering']))
      < (select sum(headcount) from metrics.headcount_by_dimension('function'))
    )::text));

-- Defect: recruiting measures took a non-standard argument count, so the
-- client could not call them and tiles rendered blank. Every chart
-- measure must accept the standard four filter arguments.
insert into results values
  ('regression', 'all chart measures take the standard 4 filter args', '0',
    (select count(*)::text
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'metrics'
       and pg_get_function_result(p.oid) like 'TABLE%'
       and p.proname not in ('current_session_context','data_freshness','data_vintage',
                             'drill_hierarchies','metric_catalog','visible_employee_ids',
                             'recruiting_funnel_stages')
       and not (pg_get_function_arguments(p.oid) like '%p_function%'
            and pg_get_function_arguments(p.oid) like '%p_location%'
            and pg_get_function_arguments(p.oid) like '%p_level_band%'
            and pg_get_function_arguments(p.oid) like '%p_tenure_band%')));

-- Defect: level_map mapped M8 (CEO) to Apex SVP, so an M8 in a
-- benchmarked function would have been measured against SVP market data
-- and reported a confident, wrong market position (measured: 1.6296).
-- M8 sits above the top of the Apex ladder and must resolve to nothing.
insert into results values
  ('regression', 'M8 has no market benchmark mapping', 'false',
    (select has_market_benchmark::text from public.level_map where meridian_career_level = 'M8')),
  ('regression', 'M8 resolves no market position even in a benchmarked function', '<none>',
    (select coalesce(
       (select e.market_position_p50::text
        from metrics.dim_employee e
        join public.level_map lm on lm.meridian_career_level = e.career_level
        where e.career_level = 'M8' and lm.has_market_benchmark), '<none>'))),
  ('regression', 'market position refuses rather than falls back where unbenchmarked', 'unavailable',
    (select status from metrics.median_market_position(array['Legal'])));

-- Defect: MET-1 requires every rendered number to trace to a definition.
insert into results values
  ('regression', 'every measure carries a definition (MET-1)', '0',
    (select count(*)::text from metrics.metric_catalog() where coalesce(definition,'') = ''));

-- ---------------------------------------------------------------------
-- 3. Privacy — suppression must fire on small cuts
-- ---------------------------------------------------------------------

-- Executive function has exactly one person: a headcount of 1 is org
-- structure and stays visible, but anything about that person must not.
insert into results values
  ('privacy', 'headcount of 1 is not suppressed (org structure)', 'value',
    (select status from metrics.active_headcount(array['Executive']))),
  ('privacy', 'compa-ratio suppressed at n=1', 'suppressed',
    (select status from metrics.median_compa_ratio(array['Executive']))),
  ('privacy', 'flight risk suppressed on denominator at n=1', 'suppressed',
    (select status from metrics.elevated_flight_risk_count(array['Executive']))),
  ('privacy', 'range penetration suppressed at n=1', 'suppressed',
    (select status from metrics.median_range_penetration(array['Executive']))),
  ('privacy', 'engagement cohorts below 5 are withheld', '0',
    (select count(*)::text from metrics.engagement_by_cohort('function')
     where not suppressed and respondents < 5));

-- ---------------------------------------------------------------------
-- 4. Grant posture — what the browser key can reach
--
--    Asserted against has_*_privilege rather than by HTTP, because that
--    is what actually decides. Note these check the EFFECTIVE privilege,
--    which includes anything inherited from PUBLIC — the exact path that
--    made an earlier revoke look successful while changing nothing.
-- ---------------------------------------------------------------------

insert into results values
  ('grants', 'anon cannot execute active_headcount', 'false',
    has_function_privilege('anon', 'metrics.active_headcount(text[],text[],text[],text[])', 'execute')::text),
  ('grants', 'anon cannot execute median_compa_ratio', 'false',
    has_function_privilege('anon', 'metrics.median_compa_ratio(text[],text[],text[],text[])', 'execute')::text),
  ('grants', 'anon cannot execute metric_catalog', 'false',
    has_function_privilege('anon', 'metrics.metric_catalog()', 'execute')::text),
  ('grants', 'anon cannot read employees', 'false',
    has_table_privilege('anon', 'public.employees', 'select')::text),
  ('grants', 'anon cannot read dim_employee', 'false',
    has_table_privilege('anon', 'metrics.dim_employee', 'select')::text),
  ('grants', 'anon cannot read engagement verbatims', 'false',
    has_table_privilege('anon', 'public.engagement_open_ended', 'select')::text),
  ('grants', 'anon cannot read recruiters (named people)', 'false',
    has_table_privilege('anon', 'public.recruiters', 'select')::text),
  ('grants', 'authenticated CAN execute active_headcount', 'true',
    has_function_privilege('authenticated', 'metrics.active_headcount(text[],text[],text[],text[])', 'execute')::text),
  ('grants', 'grant_app_access is not browser-callable', 'false',
    has_function_privilege('authenticated', 'public.grant_app_access(text,text,text,text)', 'execute')::text),
  ('grants', 'no client role can read app_users directly', 'false',
    has_table_privilege('anon', 'public.app_users', 'select')::text);

-- ---------------------------------------------------------------------
-- 5. Role model — capability gates and row scope
--
--    Each block mutates app_users to impersonate a role; the outer
--    transaction rolls all of it back.
-- ---------------------------------------------------------------------

-- MANAGER: company aggregates yes, compensation no, own tree only.
update public.app_users set app_role = 'manager', employee_id = 'E10022'
where auth_user_id = (select auth_user_id from public.app_users limit 1);

insert into results values
  ('roles', 'manager sees company headcount', '820',
    (select value::text from metrics.active_headcount())),
  ('roles', 'manager refused compensation', 'unavailable',
    (select status from metrics.median_compa_ratio())),
  ('roles', 'manager refused flight risk', 'unavailable',
    (select status from metrics.elevated_flight_risk_count())),
  ('roles', 'manager row scope is own tree only (E10022 = 55 + self)', '56',
    (select count(*)::text from metrics.visible_employee_ids()));

-- VIEWER: headline numbers only.
update public.app_users set app_role = 'viewer', employee_id = 'E10500'
where auth_user_id = (select auth_user_id from public.app_users limit 1);

insert into results values
  ('roles', 'viewer sees company headcount', '820',
    (select value::text from metrics.active_headcount())),
  ('roles', 'viewer refused compensation', 'unavailable',
    (select status from metrics.median_compa_ratio())),
  ('roles', 'viewer row scope is self only', '1',
    (select count(*)::text from metrics.visible_employee_ids()));

do $$
declare v_refused text := 'false';
begin
  begin
    perform * from metrics.headcount_by_dimension('function');
  exception when others then
    v_refused := 'true';
  end;
  insert into results values ('roles', 'viewer refused dimension cuts', 'true', v_refused);
end $$;

-- NO ROLE: absence must deny, not fall back to a default.
update public.app_users set is_active = false
where auth_user_id = (select auth_user_id from public.app_users limit 1);

insert into results values
  ('roles', 'deactivated account has no role', 'true',
    (select (metrics.current_app_role() is null)::text)),
  ('roles', 'deactivated account has no row scope', '0',
    (select count(*)::text from metrics.visible_employee_ids())),
  ('roles', 'deactivated account holds no capabilities', 'false',
    metrics.has_capability('company_aggregates')::text);

-- ---------------------------------------------------------------------
-- 6. Grant helper — REGRESSION for the mapping wipe
--
--    Defect: an omitted optional argument wrote the parameter default
--    (null) over an existing employee_id, silently unscoping a manager.
-- ---------------------------------------------------------------------

update public.app_users set is_active = true, app_role = 'admin', employee_id = 'E10001'
where auth_user_id = (select auth_user_id from public.app_users limit 1);

do $$
declare v_email text; v_after text;
begin
  select u.email into v_email from auth.users u
  join public.app_users a on a.auth_user_id = u.id limit 1;

  perform public.grant_app_access(v_email, 'executive');  -- role only, no employee_id
  select employee_id into v_after from public.app_users
  where auth_user_id = (select auth_user_id from public.app_users limit 1);

  insert into results values
    ('regression', 'role-only re-grant preserves employee mapping', 'E10001', coalesce(v_after, '<WIPED>'));
end $$;

-- ---------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------

select
  section,
  test,
  expected,
  coalesce(actual, '<null>') as actual,
  (expected is not distinct from actual) as pass
from results
order by (expected is not distinct from actual), section, test;

rollback;

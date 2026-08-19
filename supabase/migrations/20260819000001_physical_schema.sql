-- Meridian People Analytics Platform — physical schema
-- Per PRD_Class2 §4.1-4.3. Fourteen source tables, three mapping tables,
-- the data_loads audit table, and a staging mirror for the ingestion path.
--
-- RLS posture for v0.1: tables carrying employee_id (employees,
-- compensation_events, performance_reviews, competency_scores) are RLS-ON
-- with NO select policy for anon/authenticated — deny by default. The
-- semantic layer (next migration) exposes them only through `metrics`
-- views, which read as the view owner and therefore see through RLS
-- deliberately, while excluding first_name/last_name/work_email/
-- date_of_birth per NFR-4. Real per-role RLS policies land on Day 4
-- (SEM-8) without a query-layer rewrite — the policies slot in here later.
-- Tables with no individual PII (recruiting, engagement, benchmarks,
-- mapping tables) get a permissive public-read policy now.

-- ---------------------------------------------------------------------
-- 1. employees — spine table, self-joins via manager_employee_id
-- ---------------------------------------------------------------------

create table public.employees (
  employee_id text primary key,
  first_name text not null,
  last_name text not null,
  preferred_name text,
  work_email text not null,
  pronouns text,
  date_of_birth date not null,
  age integer not null,
  gender text not null,
  race_ethnicity text not null,
  veteran_status text not null,
  disability_self_id text not null,
  hire_date date not null,
  tenure_years numeric not null,
  employment_status text not null check (employment_status in ('Active', 'Terminated')),
  employment_type text not null,
  flsa_classification text not null,
  worker_classification text not null,
  termination_date date,
  termination_reason text,
  termination_type text check (termination_type in ('Voluntary', 'Involuntary')),
  rehire_eligible boolean,
  job_title text not null,
  job_code text not null,
  job_family text not null,
  job_sub_family text not null,
  career_track text not null check (career_track in ('IC', 'Mgmt')),
  career_level text not null,
  department text not null,
  function text not null,
  cost_center text not null,
  manager_employee_id text references public.employees (employee_id),
  number_of_direct_reports integer not null default 0,
  office_location text not null,
  work_country text not null,
  work_state_province text not null,
  work_city text not null,
  pay_zone text not null check (pay_zone in ('High', 'Standard', 'Mid')),
  work_arrangement text not null,
  currency text not null check (currency in ('USD', 'EUR', 'CAD')),
  base_salary numeric not null,
  pay_frequency text not null,
  target_bonus_pct numeric,
  target_bonus_amount numeric,
  target_total_cash numeric,
  ote numeric,
  sales_commission_plan text,
  last_bonus_paid_amount numeric,
  last_bonus_paid_date date,
  last_merit_increase_pct numeric,
  last_merit_increase_date date,
  last_promotion_date date,
  salary_range_min numeric not null,
  salary_range_mid numeric not null,
  salary_range_max numeric not null,
  compa_ratio numeric not null,
  range_penetration numeric not null,
  equity_grant_type text,
  total_shares_granted numeric,
  vested_shares numeric,
  unvested_shares numeric,
  vesting_start_date date,
  most_recent_grant_date date,
  most_recent_grant_shares numeric,
  current_perf_rating text,
  prev_perf_rating text,
  prev2_perf_rating text,
  nine_box_placement text,
  promotion_readiness text,
  successor_flag text check (successor_flag in ('Yes', 'No')),
  on_pip_flag text,
  flight_risk_rating text check (flight_risk_rating in ('High', 'Medium', 'Low')),
  latest_engagement_score numeric,
  last_survey_response_date date,
  compliance_training_status text not null,
  certifications_count integer not null default 0,
  internal_moves_count integer not null default 0,
  pto_balance_days numeric,
  currently_on_leave boolean not null default false,
  leave_type text,
  medical_plan_enrolled text,
  retirement_plan_participation text not null,
  retirement_contribution_pct numeric,
  source_of_hire text not null,
  referrer_employee_id text references public.employees (employee_id),
  data_load_id text
);

create index employees_manager_idx on public.employees (manager_employee_id);
create index employees_function_idx on public.employees (function);
create index employees_status_idx on public.employees (employment_status);
create index employees_office_idx on public.employees (office_location);
create index employees_career_level_idx on public.employees (career_level);

alter table public.employees enable row level security;

-- ---------------------------------------------------------------------
-- 2. compensation_events
-- ---------------------------------------------------------------------

create table public.compensation_events (
  event_id text primary key,
  employee_id text not null references public.employees (employee_id),
  event_date date not null,
  event_type text not null,
  comp_cycle text not null,
  currency text not null check (currency in ('USD', 'EUR', 'CAD')),
  prior_base_salary numeric,
  new_base_salary numeric,
  salary_change_amount numeric,
  salary_change_pct numeric,
  prior_level text,
  new_level text,
  prior_job_title text,
  new_job_title text,
  bonus_target_amount numeric,
  bonus_paid_amount numeric,
  bonus_payout_factor numeric,
  equity_grant_type text,
  equity_shares numeric,
  equity_grant_value_or_strike numeric,
  data_load_id text
);

create index comp_events_employee_idx on public.compensation_events (employee_id);
create index comp_events_date_idx on public.compensation_events (event_date);
create index comp_events_type_idx on public.compensation_events (event_type);

alter table public.compensation_events enable row level security;

-- ---------------------------------------------------------------------
-- 3. performance_reviews
-- ---------------------------------------------------------------------

create table public.performance_reviews (
  review_id text primary key,
  employee_id text not null references public.employees (employee_id),
  cycle_name text not null,
  cycle_fy integer,
  review_type text not null,
  effective_date date not null,
  review_status text not null,
  reviewer_employee_id text references public.employees (employee_id),
  skip_level_reviewer_employee_id text references public.employees (employee_id),
  self_rating text,
  manager_initial_rating text not null,
  final_rating text not null,
  calibration_adjusted text not null check (calibration_adjusted in ('Yes', 'No')),
  nine_box_placement text,
  talent_designation text,
  goals_achievement_score numeric,
  competency_score numeric,
  promotion_recommended text not null check (promotion_recommended in ('Yes', 'No')),
  promotion_outcome text not null,
  merit_increase_recommended text not null check (merit_increase_recommended in ('Yes', 'No')),
  data_load_id text
);

create index perf_reviews_employee_idx on public.performance_reviews (employee_id);
create index perf_reviews_effective_date_idx on public.performance_reviews (effective_date);
create index perf_reviews_cycle_idx on public.performance_reviews (cycle_name);

alter table public.performance_reviews enable row level security;

-- ---------------------------------------------------------------------
-- 4. competency_scores (long format: one row per review x competency)
-- ---------------------------------------------------------------------

create table public.competency_scores (
  review_id text not null references public.performance_reviews (review_id),
  employee_id text not null references public.employees (employee_id),
  competency_id text not null,
  competency_name text not null,
  competency_type text not null check (competency_type in ('Universal', 'Leadership', 'Functional')),
  score numeric not null,
  data_load_id text,
  primary key (review_id, competency_id)
);

create index competency_scores_employee_idx on public.competency_scores (employee_id);

alter table public.competency_scores enable row level security;

-- ---------------------------------------------------------------------
-- 5. engagement_questions — 30 Likert items across 10 categories
-- ---------------------------------------------------------------------

create table public.engagement_questions (
  question_id text primary key,
  category text not null,
  question_text text not null,
  question_type text not null
);

alter table public.engagement_questions enable row level security;
create policy engagement_questions_public_read on public.engagement_questions for select using (true);

-- ---------------------------------------------------------------------
-- 6. engagement_responses — anonymous, no employee key (structural, NFR-6)
-- ---------------------------------------------------------------------

create table public.engagement_responses (
  response_id text primary key,
  response_date timestamptz not null,
  function text not null,
  department text not null,
  level_band text not null,
  tenure_band text not null,
  office_location text not null,
  is_manager boolean not null,
  data_load_id text
);

create index engagement_responses_function_idx on public.engagement_responses (function);

alter table public.engagement_responses enable row level security;
create policy engagement_responses_public_read on public.engagement_responses for select using (true);

-- ---------------------------------------------------------------------
-- 7. engagement_response_scores — long format (response x question),
--    normalized from the 30 wide Q01..Q30 columns in the source file so
--    the semantic layer can aggregate by category with one join instead
--    of a 30-branch CASE expression.
-- ---------------------------------------------------------------------

create table public.engagement_response_scores (
  response_id text not null references public.engagement_responses (response_id),
  question_id text not null references public.engagement_questions (question_id),
  score numeric not null check (score between 1 and 5),
  primary key (response_id, question_id)
);

alter table public.engagement_response_scores enable row level security;
create policy engagement_response_scores_public_read on public.engagement_response_scores for select using (true);

-- ---------------------------------------------------------------------
-- 8. engagement_open_ended
-- ---------------------------------------------------------------------

create table public.engagement_open_ended (
  oe_response_id text primary key,
  response_id text references public.engagement_responses (response_id),
  question_id text not null,
  function text not null,
  department text not null,
  level_band text not null,
  tenure_band text not null,
  office_location text not null,
  theme_code text not null,
  response_text text not null,
  data_load_id text
);

create index engagement_open_ended_theme_idx on public.engagement_open_ended (theme_code);

alter table public.engagement_open_ended enable row level security;
create policy engagement_open_ended_public_read on public.engagement_open_ended for select using (true);

-- ---------------------------------------------------------------------
-- 9. requisitions
-- ---------------------------------------------------------------------

create table public.requisitions (
  req_id text primary key,
  function text not null,
  level text not null,
  job_title text not null,
  office_location text not null,
  open_date date not null,
  close_date date,
  time_to_fill_days integer,
  outcome text not null check (outcome in ('Filled', 'Open', 'On Hold', 'Cancelled')),
  hiring_manager_id text references public.employees (employee_id),
  recruiter_id text not null,
  applications integer not null default 0,
  recruiter_screens integer not null default 0,
  hm_screens integer not null default 0,
  onsites integer not null default 0,
  offers_made integer not null default 0,
  offers_accepted integer not null default 0,
  data_load_id text
);

create index requisitions_function_idx on public.requisitions (function);
create index requisitions_outcome_idx on public.requisitions (outcome);
create index requisitions_recruiter_idx on public.requisitions (recruiter_id);

alter table public.requisitions enable row level security;
create policy requisitions_public_read on public.requisitions for select using (true);

-- ---------------------------------------------------------------------
-- 10. funnel_events (long format: one row per req x stage)
-- ---------------------------------------------------------------------

create table public.funnel_events (
  req_id text not null references public.requisitions (req_id),
  function text not null,
  level text not null,
  office_location text not null,
  recruiter_id text not null,
  outcome text not null,
  stage_order integer not null,
  stage_name text not null,
  candidate_count integer not null default 0,
  data_load_id text,
  primary key (req_id, stage_order)
);

alter table public.funnel_events enable row level security;
create policy funnel_events_public_read on public.funnel_events for select using (true);

-- ---------------------------------------------------------------------
-- 11. offers
-- ---------------------------------------------------------------------

create table public.offers (
  offer_id text primary key,
  req_id text not null references public.requisitions (req_id),
  function text not null,
  level text not null,
  office_location text not null,
  offer_date date not null,
  outcome text not null check (outcome in ('Accepted', 'Declined')),
  decline_reason text,
  data_load_id text
);

create index offers_req_idx on public.offers (req_id);
create index offers_outcome_idx on public.offers (outcome);

alter table public.offers enable row level security;
create policy offers_public_read on public.offers for select using (true);

-- ---------------------------------------------------------------------
-- 12. application_sources (long format: one row per req x source)
-- ---------------------------------------------------------------------

create table public.application_sources (
  req_id text not null references public.requisitions (req_id),
  function text not null,
  level text not null,
  office_location text not null,
  source text not null,
  applications integer not null default 0,
  data_load_id text,
  primary key (req_id, source)
);

alter table public.application_sources enable row level security;
create policy application_sources_public_read on public.application_sources for select using (true);

-- ---------------------------------------------------------------------
-- 13. recruiters
-- ---------------------------------------------------------------------

create table public.recruiters (
  recruiter_id text primary key,
  recruiter_name text not null,
  team text not null,
  reqs_total integer not null default 0,
  reqs_filled integer not null default 0,
  reqs_open integer not null default 0,
  reqs_cancelled integer not null default 0,
  reqs_on_hold integer not null default 0,
  avg_time_to_fill_days numeric,
  offers_made integer not null default 0,
  hires integer not null default 0,
  first_offer_accept_pct numeric,
  data_load_id text
);

alter table public.recruiters enable row level security;
create policy recruiters_public_read on public.recruiters for select using (true);

-- ---------------------------------------------------------------------
-- 14. market_benchmarks (ACI, long-format lookup)
-- ---------------------------------------------------------------------

create table public.market_benchmarks (
  function text not null,
  track text not null check (track in ('IC', 'Mgmt')),
  apex_level text not null,
  title_typical text not null,
  pay_zone text not null, -- Apex tier name, e.g. "Tier 1"
  zone_multiplier numeric not null,
  p25_base_salary_usd_k numeric not null,
  p50_base_salary_usd_k numeric not null,
  p75_base_salary_usd_k numeric not null,
  data_load_id text,
  primary key (function, track, apex_level, pay_zone)
);

alter table public.market_benchmarks enable row level security;
create policy market_benchmarks_public_read on public.market_benchmarks for select using (true);

-- ---------------------------------------------------------------------
-- 15. competency_framework
-- ---------------------------------------------------------------------

create table public.competency_framework (
  competency_id text primary key,
  competency_name text not null,
  competency_type text not null check (competency_type in ('Universal', 'Leadership', 'Functional')),
  function text, -- null for Universal / Leadership
  description text not null,
  data_load_id text
);

alter table public.competency_framework enable row level security;
create policy competency_framework_public_read on public.competency_framework for select using (true);

-- ---------------------------------------------------------------------
-- Mapping tables (§4.2) — without these every market comparison is wrong
-- ---------------------------------------------------------------------

create table public.level_map (
  meridian_career_level text primary key, -- P1-P7 / M3-M8
  apex_level text not null,               -- I-VII / M, SrM, D, VP, SVP
  apex_track text not null check (apex_track in ('IC', 'Mgmt'))
);

alter table public.level_map enable row level security;
create policy level_map_public_read on public.level_map for select using (true);

create table public.pay_zone_map (
  -- Composite key: office_location alone is ambiguous (Boston, Dublin and Toronto are
  -- all tagged "High" in Meridian's own pay_zone field, MAP-1) and insufficient for
  -- Remote-US, which spans three different internal pay_zone values on its own.
  office_location text not null,
  pay_zone text not null check (pay_zone in ('High', 'Standard', 'Mid')),
  apex_tier text not null,               -- "Tier 1".."Tier 7"
  apex_tier_multiplier numeric not null, -- vs Tier 1 = 100
  primary key (office_location, pay_zone)
);

alter table public.pay_zone_map enable row level security;
create policy pay_zone_map_public_read on public.pay_zone_map for select using (true);

create table public.fx_rates (
  currency text primary key check (currency in ('USD', 'EUR', 'CAD')),
  usd_rate numeric not null -- 1 unit of currency = usd_rate USD, ACI survey-period rate
);

alter table public.fx_rates enable row level security;
create policy fx_rates_public_read on public.fx_rates for select using (true);

-- ---------------------------------------------------------------------
-- data_loads audit table (§4.3.5) — reporting window and freshness
-- indicator are always derived from here (ING-11, ING-12), never hardcoded.
-- ---------------------------------------------------------------------

create table public.data_loads (
  data_load_id text primary key,
  source_type text not null default 'file_upload',
  file_names text[] not null,
  row_counts jsonb not null,
  validation_summary text not null,
  loaded_by text not null,
  loaded_at timestamptz not null default now()
);

alter table public.data_loads enable row level security;
create policy data_loads_public_read on public.data_loads for select using (true);

-- ---------------------------------------------------------------------
-- staging schema — ingestion lands here first; validation runs here;
-- promotion to production happens in one transaction (ING-9). Staging
-- tables mirror production column names but carry no FK/check constraints,
-- since a load that would violate them is exactly what validation (§4.3.3)
-- must catch and report per-row before anything is promoted.
-- ---------------------------------------------------------------------

create schema if not exists staging;

-- LIKE ... INCLUDING DEFAULTS never copies CHECK constraints, PKs or FKs
-- unless INCLUDING CONSTRAINTS is also given, so none of those need
-- dropping here. NOT NULL constraints are the one thing LIKE always
-- copies regardless of options — and staging must accept incomplete rows
-- (that is what validation exists to catch), so every NOT NULL is
-- stripped below in one pass rather than tracked per column by hand.

create table staging.employees (like public.employees including defaults);
create table staging.compensation_events (like public.compensation_events including defaults);
create table staging.performance_reviews (like public.performance_reviews including defaults);
create table staging.competency_scores (like public.competency_scores including defaults);
create table staging.engagement_responses (like public.engagement_responses including defaults);
create table staging.engagement_response_scores (like public.engagement_response_scores including defaults);
create table staging.engagement_questions (like public.engagement_questions including defaults);
create table staging.engagement_open_ended (like public.engagement_open_ended including defaults);
create table staging.requisitions (like public.requisitions including defaults);
create table staging.funnel_events (like public.funnel_events including defaults);
create table staging.offers (like public.offers including defaults);
create table staging.application_sources (like public.application_sources including defaults);
create table staging.recruiters (like public.recruiters including defaults);
create table staging.market_benchmarks (like public.market_benchmarks including defaults);
create table staging.competency_framework (like public.competency_framework including defaults);

do $$
declare
  rec record;
begin
  for rec in
    select table_name, column_name
    from information_schema.columns
    where table_schema = 'staging' and is_nullable = 'NO'
  loop
    execute format('alter table staging.%I alter column %I drop not null', rec.table_name, rec.column_name);
  end loop;
end $$;

comment on schema staging is 'Ingestion lands here first (§4.3.4). Validation runs against these tables; promotion to public is one transaction, all-or-nothing (ING-8, ING-9).';

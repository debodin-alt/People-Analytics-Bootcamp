-- Fix the M8 benchmark mismapping, and make "no benchmark" explicit.
--
-- THE DEFECT
-- level_map maps both M7 and M8 to Apex SVP. M8 is the CEO — above the
-- top of the ACI ladder, which stops at SVP — so there is no market
-- benchmark for that level at all. The seed migration's own comment said
-- market position "must resolve to `unavailable`, not silently fall back
-- to SVP", but nothing implemented that: the mapping simply pointed M8
-- at SVP and the join did what it was told.
--
-- It has been invisible because Meridian's single M8 sits in the
-- "Executive" function, which has no benchmark rows for any level, so
-- market_position_p50 came out NULL by accident rather than by design.
-- Put an M8 in Engineering — which has 7 SVP benchmark rows — and the
-- CEO would have been measured against SVP market data, understating
-- their position with a number that looks entirely plausible.
--
-- THE FIX
-- Whether a level HAS a published benchmark becomes explicit data rather
-- than an accident of which rows happen to exist. The benchmark join is
-- gated on it, so an unbenchmarked level cannot resolve a market position
-- however the surrounding data changes.
--
-- Note this is distinct from the other reason a market position is
-- absent: 279 active employees sit in functions ACI does not publish
-- (Finance, Legal, People, IT, Workplace, Other G&A). That absence is
-- legitimate and data-driven. M8's was a mapping error.

alter table public.level_map
  add column has_market_benchmark boolean not null default true;

update public.level_map
  set has_market_benchmark = false
  where meridian_career_level = 'M8';

comment on column public.level_map.has_market_benchmark is
  'False where the Apex ladder publishes no benchmark for this Meridian level. M8 (CEO) sits above the ladder''s top rung (SVP); mapping it to SVP for the sake of having a mapping would produce a confident, wrong market position.';

create or replace view metrics.dim_employee as
 SELECT e.employee_id,
    e.employment_status,
    e.employment_type,
    e.hire_date,
    e.termination_date,
    e.termination_type,
    e.tenure_years,
        CASE
            WHEN e.tenure_years < 1::numeric THEN '<1 year'::text
            WHEN e.tenure_years < 3::numeric THEN '1-3 years'::text
            WHEN e.tenure_years < 5::numeric THEN '3-5 years'::text
            WHEN e.tenure_years < 8::numeric THEN '5-8 years'::text
            ELSE '8+ years'::text
        END AS tenure_band,
    e.career_track,
    e.career_level,
        CASE
            WHEN e.career_level = ANY (ARRAY['P1'::text, 'P2'::text]) THEN 'Entry / Mid IC'::text
            WHEN e.career_level = 'P3'::text THEN 'Senior IC'::text
            WHEN e.career_level = ANY (ARRAY['P4'::text, 'P5'::text, 'P6'::text, 'P7'::text]) THEN 'Staff+ IC'::text
            WHEN e.career_level = 'M3'::text THEN 'First-Line Manager'::text
            WHEN e.career_level = 'M4'::text THEN 'Sr Manager'::text
            WHEN e.career_level = 'M5'::text THEN 'Director'::text
            WHEN e.career_level = ANY (ARRAY['M6'::text, 'M7'::text, 'M8'::text]) THEN 'VP+'::text
            ELSE 'Unclassified'::text
        END AS level_band,
    e.job_title,
    e.job_family,
    e.department,
    e.function,
    e.manager_employee_id,
    e.number_of_direct_reports,
    e.office_location,
    e.work_country,
    e.pay_zone,
    lm.apex_level,
    lm.apex_track,
    pzm.apex_tier,
    pzm.apex_tier_multiplier,
    e.currency,
    e.base_salary,
    round(e.base_salary * COALESCE(fx.usd_rate, 1::numeric), 2) AS base_salary_usd,
    e.salary_range_min,
    e.salary_range_mid,
    e.salary_range_max,
    e.compa_ratio,
    e.range_penetration,
        CASE
            WHEN mb.p50_base_salary_usd_k IS NOT NULL THEN round(e.base_salary * COALESCE(fx.usd_rate, 1::numeric) / (mb.p50_base_salary_usd_k * 1000::numeric), 4)
            ELSE NULL::numeric
        END AS market_position_p50,
    e.current_perf_rating,
    e.nine_box_placement,
    e.flight_risk_rating,
    e.latest_engagement_score,
    e.on_pip_flag,
    e.gender,
    e.race_ethnicity,
    e.work_arrangement,
    e.termination_reason,
    e.job_code,
    e.last_promotion_date,
    e.promotion_readiness,
    e.prev_perf_rating
   FROM public.employees e
     LEFT JOIN public.level_map lm ON lm.meridian_career_level = e.career_level
     LEFT JOIN public.pay_zone_map pzm ON pzm.office_location = e.office_location AND pzm.pay_zone = e.pay_zone
     LEFT JOIN public.fx_rates fx ON fx.currency = e.currency
     LEFT JOIN public.market_benchmarks mb ON lm.has_market_benchmark AND mb.function = e.function AND mb.track = lm.apex_track AND mb.apex_level = lm.apex_level AND mb.pay_zone = pzm.apex_tier;

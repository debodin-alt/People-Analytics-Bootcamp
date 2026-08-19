-- Add work_arrangement to metrics.dim_employee.
--
-- headcount_by_dimension whitelisted 'work_arrangement' (the PRD asks the
-- Workforce page to cut headcount by it) but the column was never carried
-- into the view. Because the dimension is resolved by a CASE expression,
-- the missing column failed at PLAN time — which broke EVERY dimension the
-- function offered, not just this one. A per-dimension function would have
-- failed only on the bad cut; the shared-function design turns one missing
-- column into a total outage, which is worth knowing about the trade-off.
--
-- Definition below is the live view (pg_get_viewdef) with the column
-- appended and relations explicitly schema-qualified, rather than retyped.
-- CREATE OR REPLACE VIEW permits appending columns but not reordering, so
-- work_arrangement lands last.

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
    e.work_arrangement
   FROM public.employees e
     LEFT JOIN public.level_map lm ON lm.meridian_career_level = e.career_level
     LEFT JOIN public.pay_zone_map pzm ON pzm.office_location = e.office_location AND pzm.pay_zone = e.pay_zone
     LEFT JOIN public.fx_rates fx ON fx.currency = e.currency
     LEFT JOIN public.market_benchmarks mb ON mb.function = e.function AND mb.track = lm.apex_track AND mb.apex_level = lm.apex_level AND mb.pay_zone = pzm.apex_tier;

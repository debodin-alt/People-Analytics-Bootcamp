-- Carry the remaining v0.1 columns into metrics.dim_employee.
--
-- dim_employee was shaped for the Executive Overview, so each new page has
-- been discovering a missing column the hard way (work_arrangement broke
-- headcount_by_dimension; termination_reason broke attrition_reasons).
-- Adding the batch the remaining pages need in one pass instead of one
-- migration per page:
--
--   termination_reason    Attrition — stated leaving reasons
--   job_code              Compensation — pay equity cuts job_code x level x zone
--   last_promotion_date   Talent — performance-mobility gap
--   promotion_readiness   Talent — promotion pipeline
--   prev_perf_rating      Talent — rating trajectory
--
-- Still deliberately absent: first_name, last_name, work_email,
-- date_of_birth (NFR-4). Those never enter the semantic layer.
--
-- Generated from the live definition; CREATE OR REPLACE VIEW appends only.

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
     LEFT JOIN public.market_benchmarks mb ON mb.function = e.function AND mb.track = lm.apex_track AND mb.apex_level = lm.apex_level AND mb.pay_zone = pzm.apex_tier;

-- Seed the three mapping tables (§4.2). These are known reference data —
-- Meridian's own level ladder, its five real office locations crossed with
-- the internal pay_zone values that actually occur there, and the ACI
-- survey-period FX rates — not something an admin uploads through the
-- ingestion path. Verified against the source workbooks directly:
-- Materials/Meridian Analytics/Class 1-2 Data/meridian_employee_master.xlsx
-- (office_location x pay_zone combinations actually present) and
-- Compensation Benchmarks/aci_compensation_report_data.xlsx
-- ("Geographic Pay Zones" and "Long-Format Lookup Table" tabs).

insert into public.level_map (meridian_career_level, apex_level, apex_track) values
  ('P1', 'I',   'IC'),
  ('P2', 'II',  'IC'),
  ('P3', 'III', 'IC'),
  ('P4', 'IV',  'IC'),
  ('P5', 'V',   'IC'),
  ('P6', 'VI',  'IC'),
  ('P7', 'VII', 'IC'),
  ('M3', 'M',   'Mgmt'),
  ('M4', 'SrM', 'Mgmt'),
  ('M5', 'D',   'Mgmt'),
  ('M6', 'VP',  'Mgmt'),
  ('M7', 'SVP', 'Mgmt'),
  -- M8 is the CEO — above the ACI ladder. No Apex benchmark exists at this
  -- level; market-position measures must resolve this to `unavailable`,
  -- not silently fall back to SVP (ING-13 / MetricResultStatus).
  ('M8', 'SVP', 'Mgmt');

-- office_location x pay_zone, both present in the employee master today
-- (Remote-US carries all three internal zones; every other office carries one).
insert into public.pay_zone_map (office_location, pay_zone, apex_tier, apex_tier_multiplier) values
  ('Boston',    'High',     'Tier 1', 100),
  ('Toronto',   'High',     'Tier 6', 76),
  ('Dublin',    'High',     'Tier 7', 80),
  ('Denver',    'Mid',      'Tier 3', 87),
  ('Remote-US', 'High',     'Tier 2', 92),
  ('Remote-US', 'Standard', 'Tier 4', 80),
  ('Remote-US', 'Mid',      'Tier 5', 72);

insert into public.fx_rates (currency, usd_rate) values
  ('USD', 1.0),
  ('CAD', 0.736),
  ('EUR', 1.082);

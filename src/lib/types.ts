/**
 * The type contract for the Meridian People Analytics Platform.
 *
 * Per PRD_Class2 §11.1: this file is written before any schema or UI code,
 * and it is the only file both the data layer and the UI layer touch.
 * A metric result always carries a typed status (never a raw number standing
 * in for "no data") — see MetricResult below, generalized early from the
 * MetricResultStatus contract in PRD_Class5 §6.2.3 so it doesn't need a
 * rework later.
 */

// ---------------------------------------------------------------------------
// Filter context — persists across pages, serializes to the URL (CAP-1/CAP-2)
// ---------------------------------------------------------------------------

export interface FilterContext {
  function?: string[];
  location?: string[];
  levelBand?: string[];
  tenureBand?: string[];
  /** Reporting period. Omit for "as of the derived boundary". */
  period?: PeriodSelection;
  /** Optional comparison mode for period-over-period deltas (CAP-9/CAP-10). */
  comparison?: 'none' | 'prior_period' | 'same_period_last_year';
}

export interface PeriodSelection {
  /** ISO date. Always derived from data_loads, never a hardcoded constant (ING-11). */
  asOf: string;
  window?: 'ttm' | 'qtd' | 'ytd' | 'fy';
}

// ---------------------------------------------------------------------------
// Metric result — the typed contract every measure returns (metrics.* RPCs)
// ---------------------------------------------------------------------------

export type MetricResultStatus =
  | 'value'
  | 'no_data'
  | 'unavailable'
  | 'suppressed'
  | 'error';

export interface MetricResult<T = number> {
  status: MetricResultStatus;
  /** A legitimate result, including a genuine numeric zero, when status = 'value'. */
  value: T | null;
  reason: string | null;
  populationCount: number | null;
  citation: CitationContract | null;
}

export interface CitationContract {
  measure: string;
  definitionRef: string; // deep link into the Methodology page
  sourceTables: string[];
  dataLoadId: string;
  asOf: string;
}

// ---------------------------------------------------------------------------
// Drill hierarchies — declared in the model, read by the UI (SEM-5)
// ---------------------------------------------------------------------------

export type OrgHierarchyLevel = 'function' | 'job_family' | 'career_level' | 'employee';
export type GeoHierarchyLevel = 'region' | 'country' | 'office' | 'pay_zone';
export type TimeHierarchyLevel = 'year' | 'quarter' | 'month';

export interface DrillPath {
  hierarchy: 'org' | 'geography' | 'time';
  levels: string[]; // breadcrumb, root to current
}

// ---------------------------------------------------------------------------
// The Wizard contract (WIZ-4)
// ---------------------------------------------------------------------------

export type ChartForm =
  | 'line'
  | 'stacked_bar'
  | 'horizontal_bar'
  | 'bar_with_reference_line'
  | 'histogram'
  | 'diverging_histogram'
  | 'scatter'
  | 'stage_bars'
  | 'heatmap'
  | 'stat_tile';

export interface WizardChartSpec {
  form: ChartForm;
  measure: string; // metrics.* function name
  dimension?: string; // conformed dimension to group by
  series?: string[];
  filters: FilterContext;
  title: string;
}

export interface WizardResponse {
  answer: string;
  citedMeasures: string[];
  citedTables: string[];
  chart?: WizardChartSpec;
  refused?: { reason: string };
  clarificationNeeded?: { question: string };
}

// ---------------------------------------------------------------------------
// Ingestion contract (ING-1)
// ---------------------------------------------------------------------------

export interface RawTable {
  targetTable: string;
  headerRowIndex: number;
  columns: string[];
  rows: Record<string, unknown>[];
}

export interface SourceAdapter {
  parse(source: File | Blob | ArrayBuffer, fileName: string): Promise<RawTable[]>;
}

export interface ValidationFailure {
  table: string;
  rowNumber: number;
  message: string;
}

export interface LoadResult {
  dataLoadId: string;
  ok: boolean;
  rowCounts: Record<string, number>;
  failures: ValidationFailure[];
}

// ---------------------------------------------------------------------------
// Physical row types — one per PRD_Class2 §4.1 table, matching the real
// Meridian workbook columns (verified against the source files directly,
// not just the PRD's summary list — the employee master alone carries 85
// columns).
// ---------------------------------------------------------------------------

export type EmploymentStatus = 'Active' | 'Terminated';
export type PayZone = 'High' | 'Standard' | 'Mid';
export type CareerTrack = 'IC' | 'Mgmt';

export interface Employee {
  employee_id: string;
  first_name: string;
  last_name: string;
  preferred_name: string | null;
  work_email: string;
  pronouns: string | null;
  date_of_birth: string;
  age: number;
  gender: string;
  race_ethnicity: string;
  veteran_status: string;
  disability_self_id: string;
  hire_date: string;
  tenure_years: number;
  employment_status: EmploymentStatus;
  employment_type: string;
  flsa_classification: string;
  worker_classification: string;
  termination_date: string | null;
  termination_reason: string | null;
  termination_type: 'Voluntary' | 'Involuntary' | null;
  rehire_eligible: boolean | null;
  job_title: string;
  job_code: string;
  job_family: string;
  job_sub_family: string;
  career_track: CareerTrack;
  career_level: string; // P1-P7 / M3-M8
  department: string; // identical to function for active rows (modeling note, §4.4.3)
  function: string;
  cost_center: string;
  manager_employee_id: string | null;
  number_of_direct_reports: number;
  office_location: string;
  work_country: string;
  work_state_province: string;
  work_city: string;
  pay_zone: PayZone; // Meridian's own 3-value zone — never join this directly to an ACI tier (MAP-1)
  work_arrangement: string;
  currency: 'USD' | 'EUR' | 'CAD';
  base_salary: number; // local currency — convert via fx_rates before summing (MAP-2)
  pay_frequency: string;
  target_bonus_pct: number | null;
  target_bonus_amount: number | null;
  target_total_cash: number | null;
  ote: number | null;
  sales_commission_plan: string | null;
  last_bonus_paid_amount: number | null;
  last_bonus_paid_date: string | null;
  last_merit_increase_pct: number | null;
  last_merit_increase_date: string | null;
  last_promotion_date: string | null;
  salary_range_min: number;
  salary_range_mid: number;
  salary_range_max: number;
  compa_ratio: number;
  range_penetration: number;
  equity_grant_type: string | null;
  total_shares_granted: number | null;
  vested_shares: number | null;
  unvested_shares: number | null;
  vesting_start_date: string | null;
  most_recent_grant_date: string | null;
  most_recent_grant_shares: number | null;
  current_perf_rating: string | null;
  prev_perf_rating: string | null;
  prev2_perf_rating: string | null;
  nine_box_placement: string | null;
  promotion_readiness: string | null;
  successor_flag: 'Yes' | 'No' | null;
  on_pip_flag: string | null;
  flight_risk_rating: 'High' | 'Medium' | 'Low' | null; // a displayed field, not a computed score in v0.1
  latest_engagement_score: number | null; // 0-10 scale, per-employee instrument — never share an axis with the survey (MET-2)
  last_survey_response_date: string | null;
  compliance_training_status: string;
  certifications_count: number;
  internal_moves_count: number;
  pto_balance_days: number | null;
  currently_on_leave: boolean;
  leave_type: string | null;
  medical_plan_enrolled: string | null;
  retirement_plan_participation: string;
  retirement_contribution_pct: number | null;
  source_of_hire: string;
  referrer_employee_id: string | null;
}

export interface CompensationEvent {
  event_id: string;
  employee_id: string;
  event_date: string;
  event_type: string;
  comp_cycle: string;
  currency: 'USD' | 'EUR' | 'CAD';
  prior_base_salary: number | null;
  new_base_salary: number | null;
  salary_change_amount: number | null;
  salary_change_pct: number | null;
  prior_level: string | null;
  new_level: string | null;
  prior_job_title: string | null;
  new_job_title: string | null;
  bonus_target_amount: number | null;
  bonus_paid_amount: number | null;
  bonus_payout_factor: number | null;
  equity_grant_type: string | null;
  equity_shares: number | null;
  equity_grant_value_or_strike: number | null;
}

export interface PerformanceReview {
  review_id: string;
  employee_id: string;
  cycle_name: string;
  cycle_fy: number | null;
  review_type: string;
  effective_date: string;
  review_status: string;
  reviewer_employee_id: string | null;
  skip_level_reviewer_employee_id: string | null;
  self_rating: string | null;
  manager_initial_rating: string;
  final_rating: string;
  calibration_adjusted: 'Yes' | 'No';
  nine_box_placement: string | null;
  talent_designation: string | null;
  goals_achievement_score: number | null;
  competency_score: number | null;
  promotion_recommended: 'Yes' | 'No';
  promotion_outcome: string;
  merit_increase_recommended: 'Yes' | 'No';
}

export interface CompetencyScore {
  review_id: string;
  employee_id: string;
  competency_id: string;
  competency_name: string;
  competency_type: 'Universal' | 'Leadership' | 'Functional';
  score: number;
}

export interface EngagementResponse {
  response_id: string; // anonymous — no employee key
  response_date: string;
  function: string;
  department: string;
  level_band: string;
  tenure_band: string;
  office_location: string;
  is_manager: boolean;
}

export interface EngagementResponseScore {
  response_id: string;
  question_id: string;
  score: number; // 1-5 Likert
}

export interface EngagementQuestion {
  question_id: string;
  category: string;
  question_text: string;
  question_type: string;
}

export interface EngagementOpenEnded {
  oe_response_id: string;
  response_id: string | null;
  question_id: string;
  function: string;
  department: string;
  level_band: string;
  tenure_band: string;
  office_location: string;
  theme_code: string;
  response_text: string;
}

export interface Requisition {
  req_id: string;
  function: string;
  level: string;
  job_title: string;
  office_location: string;
  open_date: string;
  close_date: string | null;
  time_to_fill_days: number | null;
  outcome: 'Filled' | 'Open' | 'On Hold' | 'Cancelled';
  hiring_manager_id: string;
  recruiter_id: string;
  applications: number;
  recruiter_screens: number;
  hm_screens: number;
  onsites: number;
  offers_made: number;
  offers_accepted: number;
}

export interface FunnelEvent {
  req_id: string;
  function: string;
  level: string;
  office_location: string;
  recruiter_id: string;
  outcome: string;
  stage_order: number;
  stage_name: string;
  candidate_count: number;
}

export interface Offer {
  offer_id: string;
  req_id: string;
  function: string;
  level: string;
  office_location: string;
  offer_date: string;
  outcome: 'Accepted' | 'Declined';
  decline_reason: string | null;
}

export interface ApplicationSource {
  req_id: string;
  function: string;
  level: string;
  office_location: string;
  source: string;
  applications: number;
}

export interface Recruiter {
  recruiter_id: string;
  recruiter_name: string;
  team: string;
  reqs_total: number;
  reqs_filled: number;
  reqs_open: number;
  reqs_cancelled: number;
  reqs_on_hold: number;
  avg_time_to_fill_days: number;
  offers_made: number;
  hires: number;
  first_offer_accept_pct: number;
}

export interface MarketBenchmark {
  function: string;
  track: CareerTrack;
  apex_level: string; // I-VII / M, SrM, D, VP, SVP
  title_typical: string;
  pay_zone: string; // Apex tier name, e.g. "Tier 1"
  zone_multiplier: number;
  p25_base_salary_usd_k: number;
  p50_base_salary_usd_k: number;
  p75_base_salary_usd_k: number;
}

export interface CompetencyFramework {
  competency_id: string;
  competency_name: string;
  competency_type: 'Universal' | 'Leadership' | 'Functional';
  function: string | null; // null for Universal/Leadership
  description: string;
}

// ---------------------------------------------------------------------------
// Mapping tables (§4.2) — without these every market comparison is wrong
// ---------------------------------------------------------------------------

export interface LevelMap {
  meridian_career_level: string; // P1-P7 / M3-M8
  apex_level: string; // I-VII / M, SrM, D, VP, SVP
  apex_track: CareerTrack;
}

export interface PayZoneMap {
  /** Composite key: office_location alone is not enough for Remote-US, which carries
   *  three different internal pay_zone values; office_location alone is ambiguous for
   *  fixed offices too, since Boston, Dublin and Toronto are all tagged "High" (MAP-1). */
  office_location: string;
  pay_zone: PayZone;
  apex_tier: string; // "Tier 1".."Tier 7"
  apex_tier_multiplier: number; // vs Tier 1 = 100
}

export interface FxRate {
  currency: 'USD' | 'EUR' | 'CAD';
  usd_rate: number; // 1 unit of currency = usd_rate USD, at the ACI survey-period rate
}

// ---------------------------------------------------------------------------
// data_loads audit table (§4.3.5)
// ---------------------------------------------------------------------------

export interface DataLoad {
  data_load_id: string;
  source_type: 'file_upload';
  file_names: string[];
  row_counts: Record<string, number>;
  validation_summary: string;
  loaded_by: string;
  loaded_at: string;
}

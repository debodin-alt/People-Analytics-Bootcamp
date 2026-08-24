import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc, filterParams } from '../lib/useMetric';
import { formatRate, formatScore } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';
import { useTheme } from '../context/ThemeContext';
import { paletteDark, paletteLight, statusColors } from '../lib/palette';
import { TENURE_BANDS } from '../lib/constants';

/** 1-5 Likert drawn on its own scale, from a zero baseline. */
const LIKERT_DOMAIN: [number, number] = [0, 5];

interface CohortRow {
  label: string;
  mean_score: number | null;
  respondents: number;
  suppressed: boolean;
}

/**
 * Page 6 — Engagement (PRD_Class2 §6.1).
 *
 * Two instruments, never blended (MET-2): the anonymous survey is a 1-5
 * Likert reported in aggregate only, and the per-employee score is a
 * separate 0-10 instrument. They are shown in separate tiles, each
 * labelled with its scale, and never plotted on a shared axis.
 */
export function Engagement() {
  const { filters } = useFilters();
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const f = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const surveyMean = useMetric('engagement_survey_mean', f);
  const employeeMean = useMetric('engagement_employee_mean', f);
  const participation = useMetric('survey_participation_rate', f);

  const byCategory = useTableRpc<{ category: string; mean_score: number; n: number }>('engagement_by_category', filterParams(f));
  const byFunction = useTableRpc<CohortRow>('engagement_by_cohort', { p_dimension: 'function', ...filterParams(f) });
  const byLevelBand = useTableRpc<CohortRow>('engagement_by_cohort', { p_dimension: 'level_band', ...filterParams(f) });
  const byTenure = useTableRpc<CohortRow>('engagement_by_cohort', { p_dimension: 'tenure_band', ...filterParams(f) });
  const themes = useTableRpc<{ theme_code: string; mentions: number; suppressed: boolean }>(
    'engagement_theme_frequency',
    filterParams(f),
  );

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  const companyMean =
    surveyMean.result?.status === 'value' && surveyMean.result.value !== null ? Number(surveyMean.result.value) : undefined;

  // Cohorts below the company mean are the point of the cut — the PRD asks
  // for them surfaced rather than buried, so they carry the warning colour.
  const cohortData = (rows: CohortRow[] | null) =>
    (rows ?? [])
      .filter((r) => !r.suppressed && r.mean_score !== null)
      .map((r) => ({
        label: `${r.label} (n=${r.respondents})`,
        value: r.mean_score as number,
        color: companyMean !== undefined && (r.mean_score as number) < companyMean ? statusColors.serious : palette.series[0],
      }));

  const suppressedNote = (rows: CohortRow[] | null) => {
    const n = (rows ?? []).filter((r) => r.suppressed).length;
    return n > 0 ? `${n} cohort(s) suppressed — fewer than 5 respondents.` : undefined;
  };

  const scaleNote = 'Anonymous survey, 1-5 Likert. Aggregate only; cohorts under 5 respondents are suppressed.';

  const tenureOrdered = byTenure.data
    ? [...byTenure.data].sort(
        (a, b) => TENURE_BANDS.indexOf(a.label as never) - TENURE_BANDS.indexOf(b.label as never),
      )
    : null;

  return (
    <div>
      <div className="kpi-row">
        <KpiTile
          label="Survey mean (1-5 Likert)"
          value={displayValue(surveyMean, (v) => formatScore(v, 2))}
          loading={surveyMean.loading}
        />
        <KpiTile
          label="Per-employee score (0-10)"
          value={displayValue(employeeMean, (v) => formatScore(v, 2))}
          loading={employeeMean.loading}
        />
        <KpiTile label="Survey participation" value={displayValue(participation, formatRate)} loading={participation.loading} />
      </div>

      <div
        style={{
          fontSize: 11,
          color: 'var(--ink-faint)',
          margin: '0 0 14px',
          lineHeight: 1.5,
        }}
      >
        The two engagement measures above are <strong>different instruments on different scales</strong> and are never
        averaged together or plotted on a shared axis. Survey responses carry no employee identifier — anonymity is
        structural, not a setting.
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Score by category"
          note={`${scaleNote}${companyMean !== undefined ? ` Company mean ${companyMean.toFixed(2)}.` : ''}`}
          status={chartState(byCategory)}
          errorMessage={byCategory.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
          >
          {byCategory.data && (
            <SortedHorizontalBar
              data={byCategory.data.map((c) => ({
                label: c.category,
                value: c.mean_score,
                color: companyMean !== undefined && c.mean_score < companyMean ? statusColors.serious : palette.series[0],
              }))}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              referenceValue={companyMean}
              referenceLabel="Company mean"
              domain={LIKERT_DOMAIN}
              labelWidth={190}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Open-ended themes"
          note="Theme codes assigned by the People team. Raw verbatim text is not exposed — free text plus demographics re-identifies people."
          status={chartState(themes)}
          errorMessage={themes.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {themes.data && (
            <SortedHorizontalBar
              data={themes.data.slice(0, 12).map((t) => ({ label: t.theme_code, value: t.mentions }))}
              valueLabel="Mentions"
              labelWidth={190}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Engagement by function"
          note={[scaleNote, suppressedNote(byFunction.data)].filter(Boolean).join(' ')}
          status={chartState(byFunction)}
          errorMessage={byFunction.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {byFunction.data && (
            <SortedHorizontalBar
              data={cohortData(byFunction.data)}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              referenceValue={companyMean}
              referenceLabel="Company mean"
              domain={LIKERT_DOMAIN}
              labelWidth={170}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Engagement by level band"
          note={[scaleNote, suppressedNote(byLevelBand.data)].filter(Boolean).join(' ')}
          status={chartState(byLevelBand)}
          errorMessage={byLevelBand.error ?? undefined}
          spanClass="span-6"
          bodyHeight={240}
        >
          {byLevelBand.data && (
            <SortedHorizontalBar
              data={cohortData(byLevelBand.data)}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              referenceValue={companyMean}
              referenceLabel="Company mean"
              domain={LIKERT_DOMAIN}
              labelWidth={170}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Engagement by tenure band"
          note={[scaleNote, suppressedNote(byTenure.data)].filter(Boolean).join(' ')}
          status={chartState(byTenure)}
          errorMessage={byTenure.error ?? undefined}
          spanClass="span-6"
        >
          {tenureOrdered && (
            <SortedHorizontalBar
              data={cohortData(tenureOrdered)}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              referenceValue={companyMean}
              referenceLabel="Company mean"
              domain={LIKERT_DOMAIN}
              labelWidth={150}
              preserveOrder
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

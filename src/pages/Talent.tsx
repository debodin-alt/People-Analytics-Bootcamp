import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc, filterParams } from '../lib/useMetric';
import { formatCount, formatRate } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';
import { useTheme } from '../context/ThemeContext';
import { paletteDark, paletteLight, statusColors } from '../lib/palette';

/** Page 7 — Talent & Performance (PRD_Class2 §6.1). */
export function Talent() {
  const { filters } = useFilters();
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const f = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const calibration = useMetric('calibration_adjustment_rate', f);
  const promoRecommended = useMetric('promotion_recommended_count', f);

  const ratings = useTableRpc<{
    rating: string;
    rating_order: number;
    reviews: number;
    pct: number | null;
    suppressed: boolean;
  }>('rating_distribution', filterParams(f));
  const pipeline = useTableRpc<{ outcome: string; reviews: number }>('promotion_pipeline', filterParams(f));
  const universal = useTableRpc<{ competency_id: string; competency_name: string; mean_score: number; scores: number }>(
    'competency_means',
    { p_competency_type: 'Universal', ...filterParams(f) },
  );
  const leadership = useTableRpc<{ competency_id: string; competency_name: string; mean_score: number; scores: number }>(
    'competency_means',
    { p_competency_type: 'Leadership', ...filterParams(f) },
  );
  const nineBox = useTableRpc<{ placement: string; employees: number }>('nine_box_distribution', filterParams(f));

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  // Ratings below "Met" carry the warning colour: the distribution's shape
  // is the finding, not the raw counts.
  const ratingColor = (order: number) => (order <= 2 ? statusColors.serious : palette.series[0]);

  const totalAnnual = ratings.data?.reduce((sum, r) => sum + r.reviews, 0) ?? null;

  return (
    <div>
      <div className="kpi-row">
        <KpiTile
          label="Annual reviews"
          value={totalAnnual === null ? '—' : formatCount(totalAnnual)}
          loading={ratings.loading}
        />
        <KpiTile
          label="Calibration adjustment rate"
          value={displayValue(calibration, formatRate)}
          loading={calibration.loading}
        />
        <KpiTile
          label="Promotions recommended"
          value={displayValue(promoRecommended, formatCount)}
          loading={promoRecommended.loading}
        />
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Rating distribution"
          note="Annual reviews only — 90-day and other review types use a different basis, and mixing them would move the distribution without any change in performance."
          status={chartState(ratings)}
          errorMessage={ratings.error ?? undefined}
          spanClass="span-6"
        >
          {ratings.data && (
            <SortedHorizontalBar
              data={ratings.data.map((r) => ({
                label: r.rating.replace(' Expectations', ''),
                value: r.reviews,
                color: ratingColor(r.rating_order),
              }))}
              valueLabel="Reviews"
              preserveOrder
              labelWidth={140}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Promotion pipeline"
          note="Approved Not Effective is kept as its own outcome rather than folded into promoted or declined — an approval that never took effect is the interesting case."
          status={chartState(pipeline)}
          errorMessage={pipeline.error ?? undefined}
          spanClass="span-6"
        >
          {pipeline.data && (
            <SortedHorizontalBar
              data={pipeline.data.map((p) => ({
                label: p.outcome,
                value: p.reviews,
                color: p.outcome === 'Approved Not Effective' ? statusColors.serious : palette.series[0],
              }))}
              valueLabel="Reviews"
              labelWidth={170}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Universal competencies"
          note="Mean score across annual reviews, weakest first. Scale 1–5."
          status={chartState(universal)}
          errorMessage={universal.error ?? undefined}
          spanClass="span-6"
          bodyHeight={240}
        >
          {universal.data && (
            <SortedHorizontalBar
              data={universal.data.map((c) => ({ label: c.competency_name, value: c.mean_score }))}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              domain={[0, 5]}
              preserveOrder
              labelWidth={210}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Leadership competencies"
          note="Applies to people managers (M3+). Scale 1–5."
          status={chartState(leadership)}
          errorMessage={leadership.error ?? undefined}
          spanClass="span-6"
          bodyHeight={240}
        >
          {leadership.data && (
            <SortedHorizontalBar
              data={leadership.data.map((c) => ({ label: c.competency_name, value: c.mean_score }))}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              domain={[0, 5]}
              preserveOrder
              labelWidth={210}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Nine-box placement"
          note="Active employees. Placements with fewer than 5 people are withheld."
          status={chartState(nineBox)}
          errorMessage={nineBox.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {nineBox.data && (
            <SortedHorizontalBar
              data={nineBox.data.map((n) => ({ label: n.placement, value: n.employees }))}
              valueLabel="Employees"
              preserveOrder
              labelWidth={180}
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

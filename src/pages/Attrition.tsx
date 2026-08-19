import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc } from '../lib/useMetric';
import { formatCount, formatRate } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';

interface AttritionRow {
  label: string;
  voluntary: number;
  involuntary: number;
  avg_headcount: number;
  voluntary_rate: number | null;
}

/**
 * Page 3 — Attrition & Retention (PRD_Class2 §6.1).
 *
 * Voluntary, involuntary and regrettable are presented as three separate
 * numbers and never combined into a single "attrition" figure (MET-3).
 */
export function Attrition() {
  const { filters } = useFilters();
  const f = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const voluntaryRate = useMetric('voluntary_attrition_rate_ttm', f);
  const involuntary = useMetric('involuntary_attrition_count_ttm', f);
  const regrettable = useMetric('regrettable_attrition_count', f);

  const byFunction = useTableRpc<AttritionRow>('attrition_by_dimension', { p_dimension: 'function' });
  const byLocation = useTableRpc<AttritionRow>('attrition_by_dimension', { p_dimension: 'office_location' });
  const byLevelBand = useTableRpc<AttritionRow>('attrition_by_dimension', { p_dimension: 'level_band' });
  const reasons = useTableRpc<{ reason: string; leavers: number }>('attrition_reasons');
  const hazard = useTableRpc<{ band: string; band_order: number; leavers: number }>('tenure_hazard');

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  // Cuts with no measurable population produce a null rate; charting them
  // as zero would imply "no attrition here" rather than "not computable".
  const rateData = (rows: AttritionRow[] | null) =>
    (rows ?? []).filter((r) => r.voluntary_rate !== null).map((r) => ({ label: r.label, value: r.voluntary_rate as number }));

  const voluntaryCount = voluntaryRate.result?.populationCount ?? null;

  return (
    <div>
      <div className="kpi-row">
        <KpiTile label="Voluntary attrition (TTM)" value={displayValue(voluntaryRate, formatRate)} loading={voluntaryRate.loading} />
        <KpiTile
          label="Voluntary leavers"
          value={voluntaryCount === null ? '—' : formatCount(voluntaryCount)}
          loading={voluntaryRate.loading}
        />
        <KpiTile label="Involuntary exits" value={displayValue(involuntary, formatCount)} loading={involuntary.loading} />
        <KpiTile label="Regrettable exits" value={displayValue(regrettable, formatCount)} loading={regrettable.loading} />
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Voluntary attrition rate by function"
          status={chartState(byFunction)}
          errorMessage={byFunction.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {byFunction.data && (
            <SortedHorizontalBar data={rateData(byFunction.data)} valueLabel="Voluntary rate" formatValue={(v) => `${v.toFixed(1)}%`} />
          )}
        </ChartFrame>

        <ChartFrame
          title="Stated leaving reasons"
          status={chartState(reasons)}
          errorMessage={reasons.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {reasons.data && (
            <SortedHorizontalBar
              data={reasons.data.map((r) => ({ label: r.reason.replace(/^Resignation - /, ''), value: r.leavers }))}
              valueLabel="Leavers"
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Tenure hazard — voluntary exits by tenure at exit"
          status={chartState(hazard)}
          errorMessage={hazard.error ?? undefined}
          spanClass="span-6"
        >
          {hazard.data && (
            <SortedHorizontalBar
              data={[...hazard.data].sort((a, b) => a.band_order - b.band_order).map((h) => ({ label: h.band, value: h.leavers }))}
              valueLabel="Leavers"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Voluntary attrition rate by location"
          status={chartState(byLocation)}
          errorMessage={byLocation.error ?? undefined}
          spanClass="span-6"
        >
          {byLocation.data && (
            <SortedHorizontalBar data={rateData(byLocation.data)} valueLabel="Voluntary rate" formatValue={(v) => `${v.toFixed(1)}%`} />
          )}
        </ChartFrame>

        <ChartFrame
          title="Voluntary attrition rate by level band"
          status={chartState(byLevelBand)}
          errorMessage={byLevelBand.error ?? undefined}
          spanClass="span-6"
        >
          {byLevelBand.data && (
            <SortedHorizontalBar data={rateData(byLevelBand.data)} valueLabel="Voluntary rate" formatValue={(v) => `${v.toFixed(1)}%`} />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { StackedBar } from '../components/charts/StackedBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc, filterParams } from '../lib/useMetric';
import { formatCount, formatScore } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';
import { TENURE_BANDS } from '../lib/constants';

interface DimensionRow {
  label: string;
  headcount: number;
}

/** Page 2 — Workforce (PRD_Class2 §6.1). */
export function Workforce() {
  const { filters } = useFilters();
  const f = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const headcount = useMetric('active_headcount', f);
  const managers = useMetric('manager_count', f);
  const managerDebt = useMetric('manager_debt_count', f);
  const medianSpan = useMetric('median_span_of_control', f);
  const firstYear = useMetric('first_year_population', f);

  const byFunction = useTableRpc<DimensionRow>('headcount_by_dimension', { p_dimension: 'function', ...filterParams(f) });
  const byTenure = useTableRpc<DimensionRow>('headcount_by_dimension', { p_dimension: 'tenure_band', ...filterParams(f) });
  const byLocation = useTableRpc<DimensionRow>('headcount_by_dimension', { p_dimension: 'office_location', ...filterParams(f) });
  const byArrangement = useTableRpc<DimensionRow>('headcount_by_dimension', { p_dimension: 'work_arrangement', ...filterParams(f) });
  const byLevelBand = useTableRpc<DimensionRow>('headcount_by_dimension', { p_dimension: 'level_band', ...filterParams(f) });
  const span = useTableRpc<{ band: string; band_order: number; managers: number }>('span_of_control_distribution', filterParams(f));
  const flows = useTableRpc<{ period: string; hires: number; exits: number; net_change: number }>(
    'monthly_hires_exits',
    { p_months: 12, ...filterParams(f) },
  );

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  // tenure_band is inherently ordered; sorting it by magnitude would
  // scramble the profile it exists to show (§10.5).
  const tenureOrdered = byTenure.data
    ? [...byTenure.data].sort((a, b) => TENURE_BANDS.indexOf(a.label as never) - TENURE_BANDS.indexOf(b.label as never))
    : null;

  return (
    <div>
      <div className="kpi-row">
        <KpiTile label="Active headcount" value={displayValue(headcount, formatCount)} loading={headcount.loading} />
        <KpiTile label="People managers" value={displayValue(managers, formatCount)} loading={managers.loading} />
        <KpiTile label="Manager debt (1 report)" value={displayValue(managerDebt, formatCount)} loading={managerDebt.loading} />
        <KpiTile label="Median span of control" value={displayValue(medianSpan, (v) => formatScore(v, 1))} loading={medianSpan.loading} />
        <KpiTile label="First-year population" value={displayValue(firstYear, formatCount)} loading={firstYear.loading} />
      </div>

      <div className="chart-grid">
        <ChartFrame title="Composition by function" status={chartState(byFunction)} errorMessage={byFunction.error ?? undefined} spanClass="span-6" bodyHeight={280}>
          {byFunction.data && (
            <SortedHorizontalBar
              data={byFunction.data.map((d) => ({ label: d.label, value: d.headcount }))}
              valueLabel="Headcount"
            />
          )}
        </ChartFrame>

        <ChartFrame title="Tenure profile" status={chartState(byTenure)} errorMessage={byTenure.error ?? undefined} spanClass="span-6">
          {tenureOrdered && (
            <SortedHorizontalBar
              data={tenureOrdered.map((d) => ({ label: d.label, value: d.headcount }))}
              valueLabel="Headcount"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame title="Monthly hires and exits" status={chartState(flows)} errorMessage={flows.error ?? undefined} spanClass="span-6">
          {flows.data && (
            <StackedBar
              data={flows.data.map((d) => ({ period: d.period.slice(0, 7), hires: d.hires, exits: d.exits }))}
              categoryKey="period"
              segments={[
                { key: 'hires', label: 'Hires' },
                { key: 'exits', label: 'Exits' },
              ]}
              stacked={false}
            />
          )}
        </ChartFrame>

        <ChartFrame title="Span of control" status={chartState(span)} errorMessage={span.error ?? undefined} spanClass="span-6">
          {span.data && (
            <SortedHorizontalBar
              data={[...span.data]
                .sort((a, b) => a.band_order - b.band_order)
                .map((d) => ({ label: d.band, value: d.managers }))}
              valueLabel="Managers"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame title="Headcount by location" status={chartState(byLocation)} errorMessage={byLocation.error ?? undefined} spanClass="span-4">
          {byLocation.data && (
            <SortedHorizontalBar data={byLocation.data.map((d) => ({ label: d.label, value: d.headcount }))} valueLabel="Headcount" />
          )}
        </ChartFrame>

        <ChartFrame title="Headcount by level band" status={chartState(byLevelBand)} errorMessage={byLevelBand.error ?? undefined} spanClass="span-4">
          {byLevelBand.data && (
            <SortedHorizontalBar data={byLevelBand.data.map((d) => ({ label: d.label, value: d.headcount }))} valueLabel="Headcount" />
          )}
        </ChartFrame>

        <ChartFrame title="Work arrangement" status={chartState(byArrangement)} errorMessage={byArrangement.error ?? undefined} spanClass="span-4">
          {byArrangement.data && (
            <SortedHorizontalBar data={byArrangement.data.map((d) => ({ label: d.label, value: d.headcount }))} valueLabel="Headcount" />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

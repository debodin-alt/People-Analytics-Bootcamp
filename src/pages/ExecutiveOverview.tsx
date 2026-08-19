import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { TrendLine } from '../components/charts/TrendLine';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { StackedBar } from '../components/charts/StackedBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc } from '../lib/useMetric';
import { formatCount, formatRate, formatScore } from '../lib/format';
import type { MetricResultStatus } from '../lib/types';

/** Page 1 — modeled on meridian_ceo_people_dashboard.html (PRD_Class2 §6.1). */
export function ExecutiveOverview() {
  const { filters } = useFilters();
  const metricFilters = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const headcount = useMetric('active_headcount', metricFilters);
  const attrition = useMetric('voluntary_attrition_rate_ttm', metricFilters);
  const openReqs = useMetric('open_requisitions_count', metricFilters);
  const engagement = useMetric('engagement_employee_mean', metricFilters);
  const compaRatio = useMetric('median_compa_ratio', metricFilters);
  const flightRisk = useMetric('elevated_flight_risk_count', metricFilters);

  const trend = useTableRpc<{ period: string; headcount: number }>('headcount_trend', { p_months: 12 });
  const composition = useTableRpc<{ function: string; headcount: number }>('composition_by_function', {
    p_status: 'Active',
  });
  const attritionByType = useTableRpc<{ voluntary: number; involuntary: number }>('attrition_by_type_ttm');
  const funnel = useTableRpc<{ stage_order: number; stage_name: string; candidate_count: number }>(
    'recruiting_funnel_stages',
  );
  const engagementByCategory = useTableRpc<{ category: string; mean_score: number; n: number }>(
    'engagement_by_category',
  );

  return (
    <div>
      <div className="kpi-row">
        <KpiTile label="Active headcount" value={displayValue(headcount, formatCount)} loading={headcount.loading} />
        <KpiTile label="Voluntary attrition (TTM)" value={displayValue(attrition, formatRate)} loading={attrition.loading} />
        <KpiTile label="Open requisitions" value={displayValue(openReqs, formatCount)} loading={openReqs.loading} />
        <KpiTile label="Engagement mean" value={displayValue(engagement, (v) => formatScore(v, 2))} loading={engagement.loading} />
        <KpiTile label="Median compa-ratio" value={displayValue(compaRatio, (v) => formatScore(v, 2))} loading={compaRatio.loading} />
        <KpiTile label="Elevated flight risk" value={displayValue(flightRisk, formatCount)} loading={flightRisk.loading} />
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Headcount trend"
          status={trend.loading ? 'loading' : trend.data && trend.data.length > 0 ? 'ready' : 'empty'}
          spanClass="span-6"
        >
          {trend.data && <TrendLine data={trend.data.map((d) => ({ period: d.period, value: d.headcount }))} valueLabel="Headcount" />}
        </ChartFrame>

        <ChartFrame
          title="Composition by function"
          status={composition.loading ? 'loading' : composition.data && composition.data.length > 0 ? 'ready' : 'empty'}
          spanClass="span-6"
        >
          {composition.data && (
            <SortedHorizontalBar
              data={composition.data.map((d) => ({ label: d.function, value: d.headcount }))}
              valueLabel="Headcount"
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Attrition by type (TTM)"
          status={attritionByType.loading ? 'loading' : attritionByType.data && attritionByType.data.length > 0 ? 'ready' : 'empty'}
          spanClass="span-4"
        >
          {attritionByType.data && (
            <StackedBar
              data={[{ period: 'TTM', ...attritionByType.data[0] }]}
              categoryKey="period"
              segments={[
                { key: 'voluntary', label: 'Voluntary' },
                { key: 'involuntary', label: 'Involuntary' },
              ]}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Recruiting funnel"
          status={funnel.loading ? 'loading' : funnel.data && funnel.data.length > 0 ? 'ready' : 'empty'}
          spanClass="span-4"
        >
          {funnel.data && (
            <SortedHorizontalBar
              data={[...funnel.data]
                .sort((a, b) => a.stage_order - b.stage_order)
                .map((d) => ({ label: d.stage_name, value: d.candidate_count }))}
              valueLabel="Candidates"
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Engagement by category"
          status={engagementByCategory.loading ? 'loading' : engagementByCategory.data && engagementByCategory.data.length > 0 ? 'ready' : 'empty'}
          spanClass="span-4"
        >
          {engagementByCategory.data && (
            <SortedHorizontalBar
              data={engagementByCategory.data.map((d) => ({ label: d.category, value: d.mean_score }))}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

function displayValue(
  metric: { result: { status: MetricResultStatus; value: unknown } | null },
  fmt: (n: number) => string,
): string {
  if (!metric.result) return '—';
  const { status, value } = metric.result;
  if (status === 'value' && value !== null) return fmt(Number(value));
  if (status === 'no_data') return 'No data';
  if (status === 'suppressed') return 'Suppressed';
  if (status === 'unavailable') return 'N/A';
  return '—';
}

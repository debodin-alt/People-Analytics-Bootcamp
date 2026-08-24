import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { TrendLine } from '../components/charts/TrendLine';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { StackedBar } from '../components/charts/StackedBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc, filterParams } from '../lib/useMetric';
import { formatCount, formatRate, formatScore } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';

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

  const trend = useTableRpc<{ period: string; headcount: number }>('headcount_trend', { p_months: 12, ...filterParams(metricFilters) });
  const composition = useTableRpc<{ function: string; headcount: number }>('composition_by_function', {
    p_status: 'Active',
    ...filterParams(metricFilters),
  });
  const attritionByType = useTableRpc<{ voluntary: number; involuntary: number }>('attrition_by_type_ttm', filterParams(metricFilters));
  const funnel = useTableRpc<{ stage_order: number; stage_name: string; candidates: number }>(
    'funnel_with_conversion',
    filterParams(metricFilters),
  );
  const engagementByCategory = useTableRpc<{ category: string; mean_score: number; n: number }>(
    'engagement_by_category',
    filterParams(metricFilters),
  );

  // Same helper the other pages use: an errored measure must render as an
  // error, not as "empty". headcount_trend deliberately refuses a tenure
  // filter, and that refusal is only useful if the reason reaches the user.
  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

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
          status={chartState(trend)}
          errorMessage={trend.error ?? undefined}
          spanClass="span-6"
        >
          {trend.data && <TrendLine data={trend.data.map((d) => ({ period: d.period, value: d.headcount }))} valueLabel="Headcount" />}
        </ChartFrame>

        <ChartFrame
          title="Composition by function"
          status={chartState(composition)}
          errorMessage={composition.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
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
          status={chartState(attritionByType)}
          errorMessage={attritionByType.error ?? undefined}
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
          status={chartState(funnel)}
          errorMessage={funnel.error ?? undefined}
          spanClass="span-4"
          bodyHeight={260}
        >
          {funnel.data && (
            <SortedHorizontalBar
              data={[...funnel.data]
                .sort((a, b) => a.stage_order - b.stage_order)
                .map((d) => ({ label: d.stage_name, value: d.candidates }))}
              valueLabel="Candidates"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Engagement by category"
          status={chartState(engagementByCategory)}
          errorMessage={engagementByCategory.error ?? undefined}
          spanClass="span-4"
          bodyHeight={260}
        >
          {engagementByCategory.data && (
            <SortedHorizontalBar
              data={engagementByCategory.data.map((d) => ({ label: d.category, value: d.mean_score }))}
              valueLabel="Mean score"
              formatValue={(v) => v.toFixed(2)}
              domain={[0, 5]}
              labelWidth={165}
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

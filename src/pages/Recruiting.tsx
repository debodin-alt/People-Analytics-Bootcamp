import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc } from '../lib/useMetric';
import { formatCount, formatRate } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';
import { useTheme } from '../context/ThemeContext';
import { paletteDark, paletteLight, statusColors } from '../lib/palette';

const TIME_TO_FILL_TARGET_DAYS = 60; // §5: 60-day target for IC roles

/** Page 5 — Recruiting (PRD_Class2 §6.1). */
export function Recruiting() {
  const { filters } = useFilters();
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;

  // Requisitions carry function and location but no level_band or tenure
  // band — those are employee dimensions. Passing only what applies keeps
  // the filter honest rather than silently ignoring two of four controls.
  const f = { function: filters.function, location: filters.location };

  const openReqs = useMetric('open_requisitions_count', f);
  const medianTtf = useMetric('median_time_to_fill', f);
  const firstOffer = useMetric('first_offer_landed_rate', f);
  const offerAcceptance = useMetric('offer_acceptance_rate', f);

  const funnel = useTableRpc<{
    stage_order: number;
    stage_name: string;
    candidates: number;
    conversion_from_prev: number | null;
  }>('funnel_with_conversion', f.function || f.location ? { p_function: f.function ?? null, p_location: f.location ?? null } : {});
  const statuses = useTableRpc<{ outcome: string; requisitions: number }>('requisition_status_counts');
  const aging = useTableRpc<{ band: string; band_order: number; requisitions: number }>('open_requisition_aging');
  const ttfByFunction = useTableRpc<{ label: string; median_ttf: number; reqs_filled: number }>(
    'time_to_fill_by_dimension',
    { p_dimension: 'function' },
  );
  const sources = useTableRpc<{ source: string; applications: number }>('applications_by_source');
  const declines = useTableRpc<{ reason: string; declines: number }>('offer_decline_reasons');

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  return (
    <div>
      <div className="kpi-row">
        <KpiTile label="Open requisitions" value={displayValue(openReqs, formatCount)} loading={openReqs.loading} />
        <KpiTile label="Median time to fill" value={displayValue(medianTtf, (v) => `${v.toFixed(0)}d`)} loading={medianTtf.loading} />
        <KpiTile label="Filled on first offer" value={displayValue(firstOffer, formatRate)} loading={firstOffer.loading} />
        <KpiTile label="Offer acceptance (all offers)" value={displayValue(offerAcceptance, formatRate)} loading={offerAcceptance.loading} />
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Recruiting funnel"
          note={
            funnel.data
              ? funnel.data
                  .filter((s) => s.conversion_from_prev !== null)
                  .map((s) => `${s.stage_name} ${s.conversion_from_prev}%`)
                  .join('  ·  ')
              : undefined
          }
          status={chartState(funnel)}
          errorMessage={funnel.error ?? undefined}
          spanClass="span-6"
        >
          {funnel.data && (
            <SortedHorizontalBar
              data={[...funnel.data]
                .sort((a, b) => a.stage_order - b.stage_order)
                .map((s) => ({ label: s.stage_name, value: s.candidates }))}
              valueLabel="Candidates"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Time to fill by function"
          note={`Filled requisitions only. Target ${TIME_TO_FILL_TARGET_DAYS} days for IC roles.`}
          status={chartState(ttfByFunction)}
          errorMessage={ttfByFunction.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {ttfByFunction.data && (
            <SortedHorizontalBar
              data={ttfByFunction.data.map((t) => ({
                label: t.label,
                value: t.median_ttf,
                color: t.median_ttf > TIME_TO_FILL_TARGET_DAYS ? statusColors.serious : palette.series[0],
              }))}
              valueLabel="Median days to fill"
              formatValue={(v) => `${v.toFixed(0)}d`}
              referenceValue={TIME_TO_FILL_TARGET_DAYS}
              referenceLabel={`Target ${TIME_TO_FILL_TARGET_DAYS}d`}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Requisitions by status"
          note="Open, On Hold and Cancelled are three different states and are never rolled together."
          status={chartState(statuses)}
          errorMessage={statuses.error ?? undefined}
          spanClass="span-6"
        >
          {statuses.data && (
            <SortedHorizontalBar
              data={statuses.data.map((s) => ({ label: s.outcome, value: s.requisitions }))}
              valueLabel="Requisitions"
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Open requisition aging"
          note="Aged against the recruiting data boundary, not today's date."
          status={chartState(aging)}
          errorMessage={aging.error ?? undefined}
          spanClass="span-6"
        >
          {aging.data && (
            <SortedHorizontalBar
              data={[...aging.data]
                .sort((a, b) => a.band_order - b.band_order)
                .map((a) => ({
                  label: a.band,
                  value: a.requisitions,
                  color: a.band_order >= 4 ? statusColors.serious : palette.series[0],
                }))}
              valueLabel="Open requisitions"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Applications by source"
          status={chartState(sources)}
          errorMessage={sources.error ?? undefined}
          spanClass="span-6"
        >
          {sources.data && (
            <SortedHorizontalBar
              data={sources.data.map((s) => ({ label: s.source, value: s.applications }))}
              valueLabel="Applications"
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Offer decline reasons"
          status={chartState(declines)}
          errorMessage={declines.error ?? undefined}
          spanClass="span-6"
          bodyHeight={320}
        >
          {declines.data && (
            <SortedHorizontalBar
              data={declines.data.map((d) => ({ label: d.reason, value: d.declines }))}
              valueLabel="Declines"
              labelWidth={240}
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

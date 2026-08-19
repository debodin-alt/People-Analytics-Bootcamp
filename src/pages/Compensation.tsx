import { KpiTile } from '../components/charts/KpiTile';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { useFilters } from '../context/FilterContext';
import { useMetric, useTableRpc } from '../lib/useMetric';
import { formatCount, formatRate, formatScore } from '../lib/format';
import { displayValue } from '../lib/metricDisplay';
import { useTheme } from '../context/ThemeContext';
import { paletteDark, paletteLight, statusColors } from '../lib/palette';

interface CompaByDim {
  label: string;
  median_compa: number | null;
  employees: number;
  suppressed: boolean;
}

/** Page 4 — Compensation (PRD_Class2 §6.1). */
export function Compensation() {
  const { filters } = useFilters();
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const f = {
    function: filters.function,
    location: filters.location,
    levelBand: filters.levelBand,
    tenureBand: filters.tenureBand,
  };

  const medianCompa = useMetric('median_compa_ratio', f);
  const below090 = useMetric('below_090_compa_count', f);
  const rangePen = useMetric('median_range_penetration', f);

  const distribution = useTableRpc<{ band: string; band_order: number; employees: number }>('compa_ratio_distribution');
  const byFunction = useTableRpc<CompaByDim>('compa_ratio_by_dimension', { p_dimension: 'function' });
  const byLevelBand = useTableRpc<CompaByDim>('compa_ratio_by_dimension', { p_dimension: 'level_band' });
  const byLocation = useTableRpc<CompaByDim>('compa_ratio_by_dimension', { p_dimension: 'office_location' });
  const byGender = useTableRpc<{ gender: string; median_compa: number | null; employees: number; suppressed: boolean }>(
    'pay_position_by_gender',
  );

  const chartState = (s: { loading: boolean; data: unknown[] | null; error: string | null }) =>
    s.loading ? 'loading' : s.error ? 'error' : s.data && s.data.length > 0 ? 'ready' : 'empty';

  // Diverging around 1.00: below-range bands read as the exception they
  // are, the band straddling parity stays neutral (§10.3).
  const bandColor = (band: string) => {
    if (band === '< 0.80' || band === '0.80-0.90') return statusColors.serious;
    if (band === '0.90-0.95' || band === '0.95-1.00') return palette.series[3];
    return palette.series[0];
  };

  // Compa-ratios cluster tightly around 1.00, so absolute bars on a zero
  // baseline all render the same length and convey nothing — while
  // truncating the axis to fix that is explicitly forbidden (§10.11).
  // The resolution §10.3 prescribes for polarity around a midpoint is a
  // diverging form: chart the DEVIATION from parity, where zero is a real
  // zero. Bars then read left (paid below range midpoint) or right
  // (above), which is the actual question.
  //
  // A suppressed cut must not be charted as a gap in the ranking; drop it
  // from the bars and let the note carry it.
  const compaDeviationData = (rows: CompaByDim[] | null) =>
    (rows ?? [])
      .filter((r) => !r.suppressed && r.median_compa !== null)
      .map((r) => {
        const deviation = (r.median_compa as number) - 1.0;
        return {
          label: r.label,
          value: Number(deviation.toFixed(3)),
          color: deviation < 0 ? statusColors.serious : palette.series[0],
        };
      });

  const formatDeviation = (v: number) => `${v > 0 ? '+' : ''}${v.toFixed(2)}`;
  const deviationNote = 'Deviation from parity (1.00). Left of zero = paid below the salary-range midpoint.';

  const suppressedCount = (rows: { suppressed: boolean }[] | null) => (rows ?? []).filter((r) => r.suppressed).length;

  return (
    <div>
      <div className="kpi-row">
        <KpiTile label="Median compa-ratio" value={displayValue(medianCompa, (v) => formatScore(v, 2))} loading={medianCompa.loading} />
        <KpiTile label="Paid below 0.90 compa" value={displayValue(below090, formatCount)} loading={below090.loading} />
        <KpiTile label="Median range penetration" value={displayValue(rangePen, formatRate)} loading={rangePen.loading} />
      </div>

      <div className="chart-grid">
        <ChartFrame
          title="Compa-ratio distribution"
          note="Diverging around 1.00 — parity with the salary range midpoint. Bands below 0.90 are the population a market adjustment would target."
          status={chartState(distribution)}
          errorMessage={distribution.error ?? undefined}
          spanClass="span-6"
        >
          {distribution.data && (
            <SortedHorizontalBar
              data={[...distribution.data]
                .sort((a, b) => a.band_order - b.band_order)
                .map((d) => ({ label: d.band, value: d.employees, color: bandColor(d.band) }))}
              valueLabel="Employees"
              preserveOrder
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Median compa-ratio by function"
          note={
            suppressedCount(byFunction.data) > 0
              ? `${deviationNote} ${suppressedCount(byFunction.data)} function(s) suppressed — fewer than 5 employees.`
              : deviationNote
          }
          status={chartState(byFunction)}
          errorMessage={byFunction.error ?? undefined}
          spanClass="span-6"
          bodyHeight={280}
        >
          {byFunction.data && (
            <SortedHorizontalBar
              data={compaDeviationData(byFunction.data)}
              valueLabel="Deviation from parity"
              formatValue={formatDeviation}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Median compa-ratio by level band"
          note={deviationNote}
          status={chartState(byLevelBand)}
          errorMessage={byLevelBand.error ?? undefined}
          spanClass="span-6"
        >
          {byLevelBand.data && (
            <SortedHorizontalBar
              data={compaDeviationData(byLevelBand.data)}
              valueLabel="Deviation from parity"
              formatValue={formatDeviation}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Median compa-ratio by location"
          note={deviationNote}
          status={chartState(byLocation)}
          errorMessage={byLocation.error ?? undefined}
          spanClass="span-6"
        >
          {byLocation.data && (
            <SortedHorizontalBar
              data={compaDeviationData(byLocation.data)}
              valueLabel="Deviation from parity"
              formatValue={formatDeviation}
            />
          )}
        </ChartFrame>

        <ChartFrame
          title="Pay position by gender — unadjusted"
          note="UNADJUSTED: does not control for level, function, location or tenure, so it is not a like-for-like comparison and a difference here is not evidence of pay discrimination. Compa-ratio is used rather than salary so levels and currencies are comparable. Treat as a prompt to run a controlled analysis, never as a conclusion. Groups under 5 employees are suppressed."
          status={chartState(byGender)}
          errorMessage={byGender.error ?? undefined}
          spanClass="span-6"
          bodyHeight={200}
        >
          {byGender.data && (
            <SortedHorizontalBar
              data={byGender.data
                .filter((g) => !g.suppressed && g.median_compa !== null)
                .map((g) => {
                  const deviation = (g.median_compa as number) - 1.0;
                  return {
                    label: `${g.gender} (n=${g.employees})`,
                    value: Number(deviation.toFixed(3)),
                    color: deviation < 0 ? statusColors.serious : palette.series[0],
                  };
                })}
              valueLabel="Deviation from parity"
              formatValue={(v) => `${v > 0 ? '+' : ''}${v.toFixed(3)}`}
            />
          )}
        </ChartFrame>
      </div>
    </div>
  );
}

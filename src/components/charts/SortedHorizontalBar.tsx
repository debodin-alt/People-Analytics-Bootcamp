import { Bar, BarChart, CartesianGrid, Cell, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useTheme } from '../../context/ThemeContext';
import { paletteDark, paletteLight } from '../../lib/palette';

export interface HorizontalBarDatum {
  label: string;
  value: number;
  /**
   * Explicit bar colour. Used for diverging measures, where position
   * relative to a midpoint is the point of the chart — compa-ratio around
   * 1.00, for instance (§10.3). Omit for ordinary magnitude charts, which
   * take the single primary series colour.
   */
  color?: string;
}

interface Props {
  data: HorizontalBarDatum[];
  valueLabel: string;
  formatValue?: (n: number) => string;
  referenceValue?: number;
  referenceLabel?: string;
  /**
   * Keep the caller's order instead of sorting by value. Required for
   * inherently ordered dimensions — tenure bands, career levels, span
   * bands, funnel stages (§10.5): sorting those by magnitude destroys
   * the sequence that makes the chart readable.
   */
  preserveOrder?: boolean;
}

/**
 * Magnitude across categories — sorted descending by default, bars start
 * at zero, gridline on one axis only. Never a pie above five slices
 * (§10.3, §10.11).
 */
export function SortedHorizontalBar({
  data,
  valueLabel,
  formatValue,
  referenceValue,
  referenceLabel,
  preserveOrder = false,
}: Props) {
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const sorted = preserveOrder ? data : [...data].sort((a, b) => b.value - a.value);
  const fmt = formatValue ?? ((n: number) => n.toLocaleString());

  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={sorted} layout="vertical" margin={{ top: 4, right: 24, bottom: 4, left: 4 }}>
        <CartesianGrid horizontal={false} stroke={palette.gridline} />
        <XAxis type="number" tick={{ fontSize: 11, fill: palette.inkMuted }} tickFormatter={fmt} stroke={palette.gridline} />
        <YAxis
          type="category"
          dataKey="label"
          width={120}
          tick={{ fontSize: 11 }}
          axisLine={{ stroke: palette.gridline }}
          tickLine={false}
          // Recharts thins category labels when vertical space is tight,
          // which silently leaves bars unlabelled — a category chart whose
          // categories are unreadable has lost its identity channel
          // (§10.9: colour is never the only encoding). Force every label.
          interval={0}
        />
        <Tooltip formatter={(v) => [fmt(Number(v)), valueLabel]} />
        {referenceValue !== undefined && (
          <ReferenceLine
            x={referenceValue}
            stroke={palette.inkMuted}
            strokeDasharray="3 3"
            label={{ value: referenceLabel, position: 'insideTopRight', fontSize: 10, fill: palette.inkMuted }}
          />
        )}
        <Bar dataKey="value" radius={[0, 4, 4, 0]} maxBarSize={22}>
          {sorted.map((d, i) => (
            <Cell key={i} fill={d.color ?? palette.series[0]} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}

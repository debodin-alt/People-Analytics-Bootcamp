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
  /**
   * Width reserved for category labels. The default suits short labels;
   * widen it for long ones (offer decline reasons, job titles) which
   * otherwise wrap into each other and become unreadable.
   */
  labelWidth?: number;
  /**
   * Fixed value-axis domain. Set this for bounded instruments — a 1-5
   * Likert should be drawn on its own scale, not auto-fitted to the data.
   * Auto-fitting makes a 0.1 difference span half the chart, and lets the
   * axis maximum jump between charts of the same measure (Recharts nices
   * the step, so a max of 4.09 yields a 0-8 axis while 3.9 yields 0-4).
   * Keep the lower bound at zero: bar length must stay proportional to
   * value (§10.11 forbids a truncated bar axis).
   */
  domain?: [number, number];
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
  labelWidth = 120,
  domain,
}: Props) {
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const sorted = preserveOrder ? data : [...data].sort((a, b) => b.value - a.value);
  const fmt = formatValue ?? ((n: number) => n.toLocaleString());

  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={sorted} layout="vertical" margin={{ top: 4, right: 24, bottom: 4, left: 4 }}>
        <CartesianGrid horizontal={false} stroke={palette.gridline} />
        <XAxis
          type="number"
          domain={domain}
          allowDataOverflow={false}
          tick={{ fontSize: 11, fill: palette.inkMuted }}
          tickFormatter={fmt}
          stroke={palette.gridline}
        />
        <YAxis
          type="category"
          dataKey="label"
          width={labelWidth}
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

import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useTheme } from '../../context/ThemeContext';
import { paletteDark, paletteLight } from '../../lib/palette';

interface Props {
  data: Record<string, number | string>[];
  categoryKey: string;
  segments: { key: string; label: string }[];
  formatValue?: (n: number) => string;
  /**
   * Stacking asserts the segments sum to a meaningful whole. Set false for
   * series that are opposing flows rather than parts of one total — hires
   * vs exits, for instance, where a stack would imply a combined quantity
   * that does not exist.
   */
  stacked?: boolean;
}

/** Change over time, part-to-whole — stacked bar, at most 4 segments (§10.3). */
export function StackedBar({ data, categoryKey, segments, formatValue, stacked = true }: Props) {
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const fmt = formatValue ?? ((n: number) => n.toLocaleString());

  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 8, right: 16, bottom: 4, left: 4 }}>
        <CartesianGrid vertical={false} stroke={palette.gridline} />
        <XAxis dataKey={categoryKey} tick={{ fontSize: 11, fill: palette.inkMuted }} axisLine={{ stroke: palette.gridline }} tickLine={false} />
        <YAxis tick={{ fontSize: 11, fill: palette.inkMuted }} tickFormatter={fmt} axisLine={false} tickLine={false} />
        <Tooltip formatter={(v) => fmt(Number(v))} />
        <Legend wrapperStyle={{ fontSize: 11 }} />
        {segments.map((s, i) => (
          <Bar
            key={s.key}
            dataKey={s.key}
            name={s.label}
            stackId={stacked ? 'a' : undefined}
            fill={palette.series[i]}
            maxBarSize={40}
          />
        ))}
      </BarChart>
    </ResponsiveContainer>
  );
}

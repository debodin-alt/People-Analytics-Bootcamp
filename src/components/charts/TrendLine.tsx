import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useTheme } from '../../context/ThemeContext';
import { paletteDark, paletteLight } from '../../lib/palette';

export interface TrendDatum {
  period: string;
  value: number;
}

interface Props {
  data: TrendDatum[];
  valueLabel: string;
  formatValue?: (n: number) => string;
}

/** Change over time, 1-4 series — 2px line, recessive gridline on one axis only (§10.3, §10.5). */
export function TrendLine({ data, valueLabel, formatValue }: Props) {
  const { theme } = useTheme();
  const palette = theme === 'dark' ? paletteDark : paletteLight;
  const fmt = formatValue ?? ((n: number) => n.toLocaleString());

  return (
    <ResponsiveContainer width="100%" height="100%">
      <LineChart data={data} margin={{ top: 8, right: 16, bottom: 4, left: 4 }}>
        <CartesianGrid vertical={false} stroke={palette.gridline} />
        <XAxis dataKey="period" tick={{ fontSize: 11, fill: palette.inkMuted }} axisLine={{ stroke: palette.gridline }} tickLine={false} />
        <YAxis tick={{ fontSize: 11, fill: palette.inkMuted }} tickFormatter={fmt} axisLine={false} tickLine={false} />
        <Tooltip formatter={(v) => [fmt(Number(v)), valueLabel]} />
        <Line type="monotone" dataKey="value" stroke={palette.series[0]} strokeWidth={2} dot={false} />
      </LineChart>
    </ResponsiveContainer>
  );
}

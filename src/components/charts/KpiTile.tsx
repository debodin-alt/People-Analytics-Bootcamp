import { deltaPolarity, formatPercentagePointDelta } from '../../lib/format';

interface KpiTileProps {
  label: string;
  value: string;
  deltaPp?: number;
  higherIsBetter?: boolean;
  loading?: boolean;
}

export function KpiTile({ label, value, deltaPp, higherIsBetter = true, loading }: KpiTileProps) {
  const polarity = deltaPp !== undefined ? deltaPolarity(deltaPp, higherIsBetter) : 'neutral';
  return (
    <div className="kpi-tile">
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{loading ? '—' : value}</div>
      {deltaPp !== undefined && !loading && (
        <div className={`kpi-delta ${polarity}`}>
          {polarity === 'good' ? '▲' : polarity === 'bad' ? '▼' : '–'} {formatPercentagePointDelta(deltaPp)} vs prior
        </div>
      )}
    </div>
  );
}

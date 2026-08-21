/** Number and text formatting rules — PRD_Class2 §10.8. */

/**
 * §10.8: abbreviate ABOVE four digits — i.e. from 10,000, not from 1,000.
 * The looser threshold rendered 3,149 annual reviews as "3K", discarding
 * precision a reader needs at that magnitude. Counts in the thousands are
 * still read exactly; only genuinely large numbers get abbreviated.
 */
export function formatCount(n: number): string {
  if (Math.abs(n) >= 10_000) return formatAbbreviated(n, 0);
  return n.toLocaleString('en-US');
}

export function formatAbbreviated(n: number, decimals = 1): string {
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return `${(n / 1_000_000).toFixed(decimals)}M`;
  if (abs >= 1_000) return `${(n / 1_000).toFixed(decimals)}K`;
  return n.toFixed(decimals);
}

export function formatRate(n: number): string {
  // One decimal place on rates and scores.
  return `${n.toFixed(1)}%`;
}

export function formatScore(n: number, decimals = 1): string {
  return n.toFixed(decimals);
}

/** A move from 8.9% to 9.4% is 0.5pp, never "0.5%" (§10.8). */
export function formatPercentagePointDelta(deltaPp: number): string {
  const sign = deltaPp > 0 ? '+' : '';
  return `${sign}${deltaPp.toFixed(1)}pp`;
}

export function formatCurrency(n: number, code: 'USD' | 'EUR' | 'CAD' = 'USD'): string {
  return `${code} ${formatAbbreviated(n, 1)}`;
}

/**
 * Delta direction/color, checked against the metric's polarity.
 * `higherIsBetter = false` for measures like attrition, where a rise is bad.
 */
export function deltaPolarity(
  delta: number,
  higherIsBetter: boolean,
): 'good' | 'bad' | 'neutral' {
  if (delta === 0) return 'neutral';
  const rose = delta > 0;
  const isGood = higherIsBetter ? rose : !rose;
  return isGood ? 'good' : 'bad';
}

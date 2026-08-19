import type { MetricResultStatus } from './types';

interface MetricLike {
  result: { status: MetricResultStatus; value: unknown } | null;
}

/**
 * Renders a MetricResult for display. Each status gets distinct wording —
 * a suppressed cut and a genuinely absent measure must never both read as
 * a dash, and a real zero must read as "0" rather than as missing data.
 */
export function displayValue(metric: MetricLike, fmt: (n: number) => string): string {
  if (!metric.result) return '—';
  const { status, value } = metric.result;
  switch (status) {
    case 'value':
      return value === null ? '—' : fmt(Number(value));
    case 'no_data':
      return 'No data';
    case 'suppressed':
      return 'Suppressed';
    case 'unavailable':
      return 'N/A';
    case 'error':
      return '—';
  }
}

/** Explanatory sub-label for the non-value statuses, so a tile is never mute about why it is blank. */
export function displayReason(metric: MetricLike & { result: { reason?: string | null } | null }): string | undefined {
  const status = metric.result?.status;
  if (!status || status === 'value') return undefined;
  return metric.result?.reason ?? undefined;
}

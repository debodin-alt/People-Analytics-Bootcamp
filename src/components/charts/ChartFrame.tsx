import type { ReactNode } from 'react';
import type { MetricResultStatus } from '../../lib/types';

/**
 * Every visual in the product renders through this frame so the four
 * states in §10.6 are a property of the library, not of individual charts:
 * loading (skeleton, no layout shift), empty (filter excludes everything),
 * insufficient data (below minimum cell size — render the frame and say
 * so), and error (inline, never a blank card).
 */

interface ChartFrameProps {
  title: string;
  status: 'loading' | 'ready' | 'empty' | 'insufficient_data' | 'error';
  emptyReason?: string;
  errorMessage?: string;
  onClearFilter?: () => void;
  children: ReactNode;
  spanClass?: string;
  /**
   * Explicit body height in px for category charts with many rows. Every
   * axis label is forced to render, so a 14-category chart in the default
   * height overlaps its own labels. Roughly 16px per category.
   */
  bodyHeight?: number;
}

export function ChartFrame({
  title,
  status,
  emptyReason,
  errorMessage,
  onClearFilter,
  children,
  spanClass = 'span-6',
  bodyHeight,
}: ChartFrameProps) {
  return (
    <div className={`chart-frame ${spanClass}`}>
      <div className="chart-title">{title}</div>
      <div className="chart-body" style={bodyHeight ? { minHeight: bodyHeight } : undefined}>
        {status === 'loading' && <div className="chart-skeleton" aria-hidden="true" />}
        {status === 'empty' && (
          <div className="chart-state-message">
            <div>
              {emptyReason ?? 'No data for the current filter.'}
              {onClearFilter && (
                <>
                  {' '}
                  <button className="clear-link" onClick={onClearFilter} style={{ display: 'inline' }}>
                    Clear filter
                  </button>
                </>
              )}
            </div>
          </div>
        )}
        {status === 'insufficient_data' && (
          <div className="chart-state-message">
            {emptyReason ?? 'Fewer than the minimum cell size in this cut; suppressed to protect anonymity.'}
          </div>
        )}
        {status === 'error' && (
          <div className="chart-state-message error">{errorMessage ?? 'The request could not be completed.'}</div>
        )}
        {status === 'ready' && children}
      </div>
    </div>
  );
}

/** Maps a MetricResult status onto the chart frame's render state. */
export function chartStatusFor(metricStatus: MetricResultStatus): ChartFrameProps['status'] {
  switch (metricStatus) {
    case 'value':
      return 'ready';
    case 'no_data':
      return 'empty';
    case 'suppressed':
      return 'insufficient_data';
    case 'unavailable':
      return 'error';
    case 'error':
      return 'error';
  }
}

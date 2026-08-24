import { useEffect, useState } from 'react';
import { supabase } from './supabase';
import type { MetricResult } from './types';

export interface MetricFilters {
  function?: string[];
  location?: string[];
  levelBand?: string[];
  tenureBand?: string[];
}

/**
 * Translates the UI filter context into the standard 4-argument shape
 * every measure accepts (SEM-3). Chart calls spread this alongside their
 * own arguments, so adding a filter to the bar cannot leave a chart
 * showing a different population from the tiles beside it.
 */
export function filterParams(filters: MetricFilters): Record<string, string[] | null> {
  return {
    p_function: filters.function?.length ? filters.function : null,
    p_location: filters.location?.length ? filters.location : null,
    p_level_band: filters.levelBand?.length ? filters.levelBand : null,
    p_tenure_band: filters.tenureBand?.length ? filters.tenureBand : null,
  };
}

type MetricState<T> = { loading: boolean; result: MetricResult<T> | null; error: string | null };

/** Shape of the metrics.metric_result composite as PostgREST serialises it. */
interface RawMetricResult {
  status: MetricResult['status'];
  value: unknown;
  reason: string | null;
  population_count: number | null;
}

/**
 * Adapt the database's snake_case composite to the camelCase app contract
 * in lib/types.ts. Postgres and PostgREST do not convert case, so reading
 * `result.populationCount` straight off the response silently yields
 * undefined — which reads as "no data" rather than as a bug.
 */
function toMetricResult<T>(data: unknown): MetricResult<T> | null {
  if (!data || typeof data !== 'object') return null;
  const raw = data as RawMetricResult;
  return {
    status: raw.status,
    value: (raw.value ?? null) as T | null,
    reason: raw.reason ?? null,
    populationCount: raw.population_count ?? null,
    citation: null,
  };
}

/** Calls a metrics.* RPC that returns the typed metric_result composite. */
export function useMetric<T = number>(rpcName: string, filters: MetricFilters = {}): MetricState<T> {
  const [state, setState] = useState<MetricState<T>>({ loading: true, result: null, error: null });
  const key = JSON.stringify(filters);

  useEffect(() => {
    let cancelled = false;
    setState((s) => ({ ...s, loading: true }));
    supabase
      .schema('metrics')
      .rpc(rpcName, {
        p_function: filters.function ?? null,
        p_location: filters.location ?? null,
        p_level_band: filters.levelBand ?? null,
        p_tenure_band: filters.tenureBand ?? null,
      })
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setState({ loading: false, result: null, error: error.message });
          return;
        }
        setState({ loading: false, result: toMetricResult<T>(data), error: null });
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rpcName, key]);

  return state;
}

/** Calls a metrics.* table function that has no filter args (chart-data helpers). */
export function useTableRpc<T>(rpcName: string, args: Record<string, unknown> = {}) {
  const [state, setState] = useState<{ loading: boolean; data: T[] | null; error: string | null }>({
    loading: true,
    data: null,
    error: null,
  });
  const key = JSON.stringify(args);

  useEffect(() => {
    let cancelled = false;
    setState((s) => ({ ...s, loading: true }));
    supabase.schema('metrics').rpc(rpcName, args).then(({ data, error }) => {
      if (cancelled) return;
      if (error) {
        setState({ loading: false, data: null, error: error.message });
        return;
      }
      setState({ loading: false, data: data as T[], error: null });
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rpcName, key]);

  return state;
}

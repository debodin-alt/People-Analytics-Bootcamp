import { useEffect, useState } from 'react';
import { supabase } from './supabase';
import type { MetricResult } from './types';

interface MetricFilters {
  function?: string[];
  location?: string[];
  levelBand?: string[];
  tenureBand?: string[];
}

type MetricState<T> = { loading: boolean; result: MetricResult<T> | null; error: string | null };

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
        setState({ loading: false, result: data as MetricResult<T>, error: null });
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

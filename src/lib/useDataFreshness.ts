import { useEffect, useState } from 'react';
import { supabase } from './supabase';

type Freshness =
  | { status: 'loading' }
  | { status: 'no_data' }
  | { status: 'error' }
  | { status: 'ready'; asOf: string; dataLoadId: string };

/**
 * The reporting window and the freshness indicator are always derived from
 * `data_loads` (ING-11, ING-12) — never a hardcoded constant, so the same
 * code works after every refresh.
 */
export function useDataFreshness(): Freshness {
  const [state, setState] = useState<Freshness>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    // Goes through metrics.data_freshness() rather than selecting from
    // data_loads: the client holds no table-level read access, and the
    // function exposes only these two fields (not file names or row counts).
    supabase
      .schema('metrics')
      .rpc('data_freshness')
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setState({ status: 'error' });
          return;
        }
        if (!data || data.length === 0) {
          setState({ status: 'no_data' });
          return;
        }
        setState({
          status: 'ready',
          asOf: new Date(data[0].loaded_at as string).toLocaleDateString(),
          dataLoadId: data[0].data_load_id as string,
        });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return state;
}

import { createContext, useCallback, useContext, useMemo, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { FilterContext as FilterContextShape } from '../lib/types';

/**
 * Global filter context (§7.1). Set on one page, follows the user to every
 * other page because it lives in the URL, not component state — CAP-1
 * (serializes to the URL) and CAP-2 (survives navigation, cleared only by
 * an explicit clear action) fall out of that for free.
 */

interface FilterContextValue {
  filters: FilterContextShape;
  setFunction: (values: string[]) => void;
  setLocation: (values: string[]) => void;
  setLevelBand: (values: string[]) => void;
  setTenureBand: (values: string[]) => void;
  setComparison: (mode: FilterContextShape['comparison']) => void;
  clearAll: () => void;
}

const Ctx = createContext<FilterContextValue | null>(null);

const LIST_KEYS = ['function', 'location', 'levelBand', 'tenureBand'] as const;

export function FilterProvider({ children }: { children: ReactNode }) {
  const [params, setParams] = useSearchParams();

  const filters = useMemo<FilterContextShape>(() => {
    const get = (key: string) => {
      const v = params.get(key);
      return v ? v.split(',') : undefined;
    };
    return {
      function: get('function'),
      location: get('location'),
      levelBand: get('levelBand'),
      tenureBand: get('tenureBand'),
      comparison: (params.get('comparison') as FilterContextShape['comparison']) ?? 'none',
    };
  }, [params]);

  const setList = useCallback(
    (key: (typeof LIST_KEYS)[number], values: string[]) => {
      setParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          if (values.length === 0) next.delete(key);
          else next.set(key, values.join(','));
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  const setComparison = useCallback(
    (mode: FilterContextShape['comparison']) => {
      setParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          if (!mode || mode === 'none') next.delete('comparison');
          else next.set('comparison', mode);
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  const clearAll = useCallback(() => {
    setParams(new URLSearchParams(), { replace: true });
  }, [setParams]);

  const value = useMemo<FilterContextValue>(
    () => ({
      filters,
      setFunction: (v) => setList('function', v),
      setLocation: (v) => setList('location', v),
      setLevelBand: (v) => setList('levelBand', v),
      setTenureBand: (v) => setList('tenureBand', v),
      setComparison,
      clearAll,
    }),
    [filters, setList, setComparison, clearAll],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useFilters() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useFilters must be used within FilterProvider');
  return ctx;
}

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import type { Store } from '@twimshelf/core';

export function useStore<T>(s: Store<T>): T {
  return useSyncExternalStore(s.subscribe, s.get, s.get);
}

export interface Async<T> {
  data: T | undefined;
  error: unknown;
  loading: boolean;
  reload: () => void;
}

/** Runs `load` when `deps` change; the latest answer wins. */
export function useAsync<T>(load: () => Promise<T>, deps: unknown[]): Async<T> {
  const [state, setState] = useState<{ data?: T; error?: unknown; loading: boolean }>({ loading: true });
  const [tick, setTick] = useState(0);
  const seq = useRef(0);
  useEffect(() => {
    const mine = ++seq.current;
    setState((s) => ({ ...s, loading: true }));
    load().then(
      (data) => mine === seq.current && setState({ data, loading: false }),
      (error) => mine === seq.current && setState((s) => ({ data: s.data, error, loading: false })),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { data: state.data, error: state.error, loading: state.loading, reload };
}

/** Calls `fn` every `ms` while mounted (progress of downloads, imports, sync). */
export function useInterval(fn: () => void, ms: number | null): void {
  const latest = useRef(fn);
  latest.current = fn;
  useEffect(() => {
    if (ms == null) return;
    const id = setInterval(() => latest.current(), ms);
    return () => clearInterval(id);
  }, [ms]);
}

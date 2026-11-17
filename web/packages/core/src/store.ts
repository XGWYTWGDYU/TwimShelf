// A tiny observable value, so state lives outside React (and could be shared with React Native).
export interface Store<T> {
  get(): T;
  set(value: T | ((old: T) => T)): void;
  subscribe(listener: () => void): () => void;
}

export function store<T>(initial: T): Store<T> {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set(next) {
      const v = typeof next === 'function' ? (next as (old: T) => T)(value) : next;
      if (Object.is(v, value)) return;
      value = v;
      listeners.forEach((l) => l());
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

// Where the app is: a small router of its own, in the URL hash so a reload stays put.
import { store } from '@twimshelf/core';
import { useStore } from './hooks';

export type Route =
  | { page: 'browse'; kind?: 'photo' | 'video'; folder?: string; view?: 'loose' | 'album' | 'unreviewed' | 'reviewed'; q?: string }
  | { page: 'folders' }
  | { page: 'tags' }
  | { page: 'bin' }
  | { page: 'settings'; sub?: string };

function parse(hash: string): Route {
  const [path, query = ''] = hash.replace(/^#\/?/, '').split('?');
  const p = new URLSearchParams(query);
  const [page, sub] = path.split('/');
  switch (page) {
    case 'folders': return { page: 'folders' };
    case 'tags': return { page: 'tags' };
    case 'bin': return { page: 'bin' };
    case 'settings': return { page: 'settings', sub: sub || undefined };
    default: {
      const r: Route = { page: 'browse' };
      const kind = p.get('kind'); if (kind === 'photo' || kind === 'video') r.kind = kind;
      const folder = p.get('folder'); if (folder) r.folder = folder;
      const view = p.get('view'); if (view === 'loose' || view === 'album' || view === 'unreviewed' || view === 'reviewed') r.view = view;
      const q = p.get('q'); if (q) r.q = q;
      return r;
    }
  }
}

export function href(r: Route): string {
  if (r.page === 'settings') return `#/settings${r.sub ? '/' + r.sub : ''}`;
  if (r.page !== 'browse') return `#/${r.page}`;
  const p = new URLSearchParams();
  if (r.kind) p.set('kind', r.kind);
  if (r.folder) p.set('folder', r.folder);
  if (r.view) p.set('view', r.view);
  if (r.q) p.set('q', r.q);
  const s = p.toString();
  return `#/browse${s ? '?' + s : ''}`;
}

export const route = store<Route>(parse(location.hash));
window.addEventListener('hashchange', () => route.set(parse(location.hash)));

export function go(r: Route): void {
  location.hash = href(r);
}

export function useRoute(): Route {
  return useStore(route);
}

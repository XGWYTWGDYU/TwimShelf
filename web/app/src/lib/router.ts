// Where the app is: a small router of its own, in the URL hash so a reload stays put. The places
// are the native sidebar's (LibraryPlace.swift): 浏览 (the cards), the zoomable grids of the media
// kinds, folders and collections, all folders, and the settings.
import { store } from '@twimshelf/core';
import { useStore } from './hooks';

/** A place shown as the zoomable media grid. */
export type GridPlace = 'photos' | 'videos' | 'folder' | 'loose' | 'album' | 'favorites' | 'unreviewed' | 'reviewed' | 'bad' | 'trash';
const GRID_PLACES: GridPlace[] = ['photos', 'videos', 'folder', 'loose', 'album', 'favorites', 'unreviewed', 'reviewed', 'bad', 'trash'];

export type Route =
  | { page: 'browse'; kind?: 'photo' | 'video'; folder?: string; view?: 'loose' | 'album' | 'favorites' | 'unreviewed' | 'reviewed'; q?: string }
  | { page: 'grid'; place: GridPlace; folder?: string }
  | { page: 'folders' }
  | { page: 'tags' }
  | { page: 'settings'; sub?: string };

function parse(hash: string): Route {
  const [path, query = ''] = hash.replace(/^#\/?/, '').split('?');
  const p = new URLSearchParams(query);
  const [page, sub] = path.split('/');
  switch (page) {
    case 'folders': return { page: 'folders' };
    case 'tags': return { page: 'tags' };
    case 'bin': return { page: 'grid', place: 'trash' };
    case 'settings': return { page: 'settings', sub: sub || undefined };
    case 'grid': {
      const place = (GRID_PLACES as string[]).includes(sub) ? sub as GridPlace : 'photos';
      const folder = p.get('folder') ?? undefined;
      return place === 'folder' && folder ? { page: 'grid', place, folder } : { page: 'grid', place: place === 'folder' ? 'photos' : place };
    }
    default: {
      const r: Route = { page: 'browse' };
      const kind = p.get('kind'); if (kind === 'photo' || kind === 'video') r.kind = kind;
      const folder = p.get('folder'); if (folder) r.folder = folder;
      const view = p.get('view'); if (view === 'loose' || view === 'album' || view === 'favorites' || view === 'unreviewed' || view === 'reviewed') r.view = view;
      const q = p.get('q'); if (q) r.q = q;
      return r;
    }
  }
}

export function href(r: Route): string {
  if (r.page === 'settings') return `#/settings${r.sub ? '/' + r.sub : ''}`;
  if (r.page === 'grid') return `#/grid/${r.place}${r.place === 'folder' && r.folder ? '?folder=' + encodeURIComponent(r.folder) : ''}`;
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

/** The place of a folder's grid. */
export const folderRoute = (name: string): Route => ({ page: 'grid', place: 'folder', folder: name });

export function useRoute(): Route {
  return useStore(route);
}

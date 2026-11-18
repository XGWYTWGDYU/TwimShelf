// Pictures, two kinds: `square` for the grid's tiles (the core's cached square thumbnails,
// `tl_thumbnail`, and the server's square video frame) and `whole` for the cards and the viewer's
// first frame (the picture uncropped, upright, at most `side` on its long edge, as the native card
// decodes it: the server's /api/scaled, a JPEG of a HEIC, the whole video frame). A few at a time, nearest first, so a
// fast scroll does not queue hundreds of requests; results are remembered for the session.
import type { FeedItem } from '@twimshelf/core';
import { core } from './core';

let cacheDir: Promise<string> | null = null;
function cache(): Promise<string> {
  cacheDir ??= fetch(`${core.transport.base}/api/info`, { credentials: 'same-origin' })
    .then((r) => r.json() as Promise<{ cache: string }>)
    .then((i) => i.cache);
  // a failed first try does not stay the answer
  cacheDir.catch(() => { cacheDir = null; });
  return cacheDir;
}

/** The long-edge sizes thumbnails are made at; a card takes the smallest that is sharp enough. */
const SIDES = [256, 512, 1024];
export function sideFor(cssWidth: number): number {
  const want = cssWidth * (window.devicePixelRatio || 1);
  return SIDES.find((s) => s >= want) ?? SIDES[SIDES.length - 1];
}

const done = new Map<string, string>();
const waiting = new Map<string, { item: FeedItem; side: number; kind: PictureKind; resolve: (u: string) => void; reject: (e: unknown) => void; priority: number }>();
let running = 0;
const LIMIT = 6;

export type PictureKind = 'square' | 'whole';

export function cachedThumb(item: FeedItem, side: number, kind: PictureKind = 'square'): string | undefined {
  return done.get(`${item.media_id}@${side}${kind === 'whole' ? 'w' : ''}`);
}

/** The picture's URL; `priority` lower = sooner (the distance from the visible area). */
export function thumb(item: FeedItem, side: number, priority = 0, kind: PictureKind = 'square'): Promise<string> {
  const key = `${item.media_id}@${side}${kind === 'whole' ? 'w' : ''}`;
  const hit = done.get(key);
  if (hit) return Promise.resolve(hit);
  const queued = waiting.get(key);
  if (queued) {
    queued.priority = Math.min(queued.priority, priority);
    return new Promise((resolve, reject) => {
      const old = queued.resolve, oldReject = queued.reject;
      queued.resolve = (u) => { old(u); resolve(u); };
      queued.reject = (e) => { oldReject(e); reject(e); };
    });
  }
  return new Promise((resolve, reject) => {
    waiting.set(key, { item, side, kind, resolve, reject, priority });
    pump();
  });
}

/** Forget queued requests nobody waits for any more (the list changed). */
export function dropQueued(keep: (mediaId: string) => boolean): void {
  for (const [k, w] of waiting) if (!keep(w.item.media_id)) { waiting.delete(k); w.reject(new Error('dropped')); }
}

function pump(): void {
  while (running < LIMIT && waiting.size > 0) {
    let best: [string, typeof waiting extends Map<string, infer V> ? V : never] | null = null;
    for (const e of waiting) if (!best || e[1].priority < best[1].priority) best = e;
    if (!best) return;
    const [key, w] = best;
    waiting.delete(key);
    running++;
    make(w.item, w.side, w.kind).then(
      (url) => { done.set(key, url); w.resolve(url); },
      (e) => w.reject(e),
    ).finally(() => { running--; pump(); });
  }
}

async function make(item: FeedItem, side: number, kind: PictureKind): Promise<string> {
  if (item.kind === 'photo' && kind === 'whole') {
    if (/\.(heic|heif)$/i.test(item.path)) return core.fileUrl(await core.read<string>(core.b.tl_display_image(item.path, side, await cache())));
    const url = `${core.transport.base}/api/scaled?path=${encodeURIComponent(item.path)}&side=${side}`;
    // decoded once here, so the card shows it at once (and a broken file is known)
    await new Promise<void>((resolve, reject) => { const im = new Image(); im.onload = () => resolve(); im.onerror = () => reject(new Error('scaled')); im.src = url; });
    return url;
  }
  if (item.kind === 'photo') {
    const r = await core.read<{ path?: string; video?: boolean }>(core.b.tl_thumbnail(item.media_id, side, await cache()));
    if (r.path) return core.fileUrl(r.path);
  }
  return poster(item.path, side, kind === 'whole');
}

/** A video's frame (made once by the server with ffmpeg): `{path}` of a JPEG in its cache. */
export async function poster(path: string, side: number, whole = true): Promise<string> {
  const r = await fetch(`${core.transport.base}/api/poster?path=${encodeURIComponent(path)}&side=${side}${whole ? '&whole=1' : ''}`, { credentials: 'same-origin' });
  if (!r.ok) throw new Error(`poster: HTTP ${r.status}`);
  return core.fileUrl(((await r.json()) as { path: string }).path);
}

/** Makes a grid's square thumbnails on the server ahead of time, in the background (the native
 *  grid's `thumbnails.warm`): a zoom then finds them ready instead of waiting on each. */
export async function warmThumbs(ids: string[], side: number): Promise<void> {
  if (!ids.length) return;
  try { await core.read(core.b.tl_thumbnails_warm(JSON.stringify(ids), side, await cache())); } catch { /* best effort */ }
}

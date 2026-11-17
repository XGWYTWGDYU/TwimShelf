// Card pictures: the core's cached thumbnails (`tl_thumbnail`, made once into the server's cache
// folder) for photos, the server's poster frame for videos. A few at a time, nearest first, so a
// fast scroll does not queue hundreds of requests; results are remembered for the session.
import type { FeedItem } from '@twimshelf/core';
import { core } from './core';

let cacheDir: Promise<string> | null = null;
function cache(): Promise<string> {
  cacheDir ??= fetch(`${core.transport.base}/api/info`, { credentials: 'same-origin' })
    .then((r) => r.json() as Promise<{ cache: string }>)
    .then((i) => i.cache);
  return cacheDir;
}

/** The long-edge sizes thumbnails are made at; a card takes the smallest that is sharp enough. */
const SIDES = [256, 512, 1024];
export function sideFor(cssWidth: number): number {
  const want = cssWidth * (window.devicePixelRatio || 1);
  return SIDES.find((s) => s >= want) ?? SIDES[SIDES.length - 1];
}

const done = new Map<string, string>();
const waiting = new Map<string, { item: FeedItem; side: number; resolve: (u: string) => void; reject: (e: unknown) => void; priority: number }>();
let running = 0;
const LIMIT = 6;

export function cachedThumb(item: FeedItem, side: number): string | undefined {
  return done.get(`${item.media_id}@${side}`);
}

/** The picture's URL; `priority` lower = sooner (the distance from the visible area). */
export function thumb(item: FeedItem, side: number, priority = 0): Promise<string> {
  const key = `${item.media_id}@${side}`;
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
    waiting.set(key, { item, side, resolve, reject, priority });
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
    make(w.item, w.side).then(
      (url) => { done.set(key, url); w.resolve(url); },
      (e) => w.reject(e),
    ).finally(() => { running--; pump(); });
  }
}

async function make(item: FeedItem, side: number): Promise<string> {
  if (item.kind === 'video') {
    return `${core.transport.base}/api/poster?path=${encodeURIComponent(item.path)}&side=${side}&whole=1`;
  }
  const r = await core.read<{ path?: string; video?: boolean }>(core.b.tl_thumbnail(item.media_id, side, await cache()));
  if (r.path) return core.fileUrl(r.path);
  return `${core.transport.base}/api/poster?path=${encodeURIComponent(item.path)}&side=${side}&whole=1`;
}

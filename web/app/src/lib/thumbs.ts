// Pictures, two kinds: `square` for the grid's tiles (the core's cached square thumbnails,
// `tl_thumbnail`, and a square frame of a video) and `whole` for the cards and the viewer's
// first frame (the picture uncropped, upright, at most `side` on its long edge, as the native card
// decodes it: the server's /api/scaled, a JPEG of a HEIC, the video's whole frame taken in the page). A few at a time, nearest first, so a
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
export function thumbnailDirectories(cache: string): string[] {
  return [...SIDES, 'display'].map((part) => `${cache}/${part}`);
}

export function sideFor(cssWidth: number): number {
  const want = cssWidth * (window.devicePixelRatio || 1);
  return SIDES.find((s) => s >= want) ?? SIDES[SIDES.length - 1];
}

const done = new Map<string, string>();
/** Pictures that could not be made, and when: asked for again only after a while. A grid asks on
 *  every frame, and a broken file at the front of the queue would keep the others waiting. */
const failed = new Map<string, number>();
const RETRY_AFTER_MS = 30_000;
const waiting = new Map<string, { item: FeedItem; side: number; kind: PictureKind; resolve: (u: string) => void; reject: (e: unknown) => void; priority: number }>();
/** Pictures being made at the same time, photos and videos each on their own: a video waits for
 *  its decoder, and must not keep the photos behind it waiting too. */
const running = { photo: 0, video: 0 };
const LIMIT = { photo: 8, video: 8 };
const lane = (item: FeedItem): 'photo' | 'video' => (item.kind === 'photo' ? 'photo' : 'video');

export type PictureKind = 'square' | 'whole';

export function cachedThumb(item: FeedItem, side: number, kind: PictureKind = 'square'): string | undefined {
  return done.get(`${item.media_id}@${side}${kind === 'whole' ? 'w' : ''}`);
}

/** The picture's URL; `priority` lower = sooner (the distance from the visible area). */
export function thumb(item: FeedItem, side: number, priority = 0, kind: PictureKind = 'square'): Promise<string> {
  const key = `${item.media_id}@${side}${kind === 'whole' ? 'w' : ''}`;
  const hit = done.get(key);
  if (hit) return Promise.resolve(hit);
  const lastTry = failed.get(key);
  if (lastTry !== undefined && Date.now() - lastTry < RETRY_AFTER_MS) return Promise.reject(new Error('failed recently'));
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
  for (;;) {
    let best: [string, typeof waiting extends Map<string, infer V> ? V : never] | null = null;
    for (const e of waiting) {
      if (running[lane(e[1].item)] >= LIMIT[lane(e[1].item)]) continue;
      if (!best || e[1].priority < best[1].priority) best = e;
    }
    if (!best) return;
    const [key, w] = best;
    const l = lane(w.item);
    waiting.delete(key);
    running[l]++;
    make(w.item, w.side, w.kind).then(
      (url) => { failed.delete(key); done.set(key, url); w.resolve(url); },
      (e) => { failed.set(key, Date.now()); w.reject(e); },
    ).finally(() => { running[l]--; pump(); });
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

/** A video's frame, taken here from the video itself and kept in this browser: `whole` has `side`
 *  as its long edge, otherwise a centred square of `side`. The video is opened once for all sizes. */
export async function poster(path: string, side: number, whole = true): Promise<string> {
  const frame = await videoStill(path);
  return URL.createObjectURL(await resized(frame, side, whole));
}

/** One still of each video, large enough for every size asked for (its short edge 1024, its long
 *  edge at most 2048); requests for the same video share it. */
const stills = new Map<string, Promise<Blob>>();
function videoStill(path: string): Promise<Blob> {
  let still = stills.get(path);
  if (!still) {
    still = (async () => {
      const key = `${path}|still`;
      const kept = await readFrame(key);
      if (kept) return kept;
      await frameTurn();
      try {
        const frame = await videoFrame(path);
        void saveFrame(key, frame);
        return frame;
      } finally {
        frameDone();
      }
    })();
    stills.set(path, still);
    // a failure is not remembered here (the queue above waits before asking again)
    still.catch(() => stills.delete(path));
  }
  return still;
}

/** The still at a size: the whole picture with `side` as its long edge, or a centred square. */
async function resized(still: Blob, side: number, whole: boolean): Promise<Blob> {
  const img = await createImageBitmap(still);
  try {
    const w = img.width, h = img.height;
    const scale = whole ? Math.min(1, side / Math.max(w, h)) : side / Math.min(w, h);
    const width = whole ? Math.max(1, Math.round(w * scale)) : side, height = whole ? Math.max(1, Math.round(h * scale)) : side;
    if (whole && width === w && height === h) return still;
    const canvas = document.createElement('canvas');
    canvas.width = width; canvas.height = height;
    const g = canvas.getContext('2d');
    if (!g) return still;
    g.imageSmoothingQuality = 'high';
    g.drawImage(img, (width - w * scale) / 2, (height - h * scale) / 2, w * scale, h * scale);
    return await new Promise<Blob>((resolve) => canvas.toBlob((b) => resolve(b ?? still), 'image/jpeg', 0.88));
  } finally {
    img.close();
  }
}

/** Videos opened at the same time: each one takes a decoder. */
const FRAME_LIMIT = 8;
let framesRunning = 0;
const frameQueue: (() => void)[] = [];
function frameTurn(): Promise<void> {
  if (framesRunning < FRAME_LIMIT) { framesRunning++; return Promise.resolve(); }
  return new Promise((resolve) => frameQueue.push(resolve));
}
function frameDone(): void {
  const next = frameQueue.shift();
  if (next) next(); else framesRunning--;
}

/** The frame at half a second (the middle of a shorter video) as a JPEG, its short edge at most
 *  1024 and its long edge at most 2048. Only what the seek needs is read (`metadata`). */
function videoFrame(path: string): Promise<Blob> {
  return new Promise((resolve, reject) => {
    const video = document.createElement('video');
    const finish = (settle: () => void) => {
      clearTimeout(timer);
      video.onloadedmetadata = video.onseeked = video.onerror = null;
      video.removeAttribute('src');
      video.load();
      settle();
    };
    const fail = (why: string) => finish(() => reject(new Error(`video frame: ${why}`)));
    const timer = setTimeout(() => fail('timed out'), 20_000);
    video.muted = true;
    video.playsInline = true;
    video.preload = 'metadata';
    video.onerror = () => fail('not playable');
    video.onloadedmetadata = () => { video.currentTime = Math.min(0.5, (video.duration || 0) / 2); };
    video.onseeked = () => {
      const w = video.videoWidth, h = video.videoHeight;
      if (!w || !h) return fail('no picture');
      const scale = Math.min(1, 1024 / Math.min(w, h), 2048 / Math.max(w, h));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(w * scale));
      canvas.height = Math.max(1, Math.round(h * scale));
      const g = canvas.getContext('2d');
      if (!g) return fail('no canvas');
      g.drawImage(video, 0, 0, canvas.width, canvas.height);
      canvas.toBlob((blob) => {
        if (blob) finish(() => resolve(blob)); else fail('not encoded');
      }, 'image/jpeg', 0.88);
    };
    video.src = core.fileUrl(path);
  });
}

// The frames taken so far, so that a video is opened for its picture only once. Without this
// storage (a private window) they are simply taken again.
let frameStore: Promise<IDBDatabase | null> | null = null;
function frames(): Promise<IDBDatabase | null> {
  frameStore ??= new Promise((resolve) => {
    try {
      const open = indexedDB.open('twimshelf-video-frames', 1);
      open.onupgradeneeded = () => open.result.createObjectStore('frames');
      open.onsuccess = () => resolve(open.result);
      open.onerror = open.onblocked = () => resolve(null);
    } catch { resolve(null); }
  });
  return frameStore;
}

async function readFrame(key: string): Promise<Blob | null> {
  const db = await frames();
  if (!db) return null;
  return new Promise((resolve) => {
    try {
      const get = db.transaction('frames').objectStore('frames').get(key);
      get.onsuccess = () => resolve(get.result instanceof Blob ? get.result : null);
      get.onerror = () => resolve(null);
    } catch { resolve(null); }
  });
}

async function saveFrame(key: string, frame: Blob): Promise<void> {
  const db = await frames();
  try { db?.transaction('frames', 'readwrite').objectStore('frames').put(frame, key); } catch { /* taken again next time */ }
}

/** Forgets the frames kept in this browser (Settings, Storage). */
export async function clearVideoFrames(): Promise<void> {
  const db = await frames();
  try { db?.transaction('frames', 'readwrite').objectStore('frames').clear(); } catch { /* nothing to clear */ }
}

/** Makes a grid's square thumbnails on the server ahead of time, in the background (the native
 *  grid's `thumbnails.warm`): a zoom then finds them ready instead of waiting on each. */
export async function warmThumbs(ids: string[], side: number): Promise<void> {
  if (!ids.length) return;
  try { await core.read(core.b.tl_thumbnails_warm(JSON.stringify(ids), side, await cache())); } catch { /* best effort */ }
}

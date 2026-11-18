// The media viewer over the whole window (MacPhotoView.swift): ← → (or the round arrow buttons,
// or a sideways two-finger swipe) go through every photo and video of the list it was opened
// from; double-click or pinch zooms a photo; Esc or ✕ closes; Share and ⌘C hand the file on.
//
// The pages lie side by side in a strip (the current one and both neighbours, made ahead): a swipe
// moves the strip with the fingers, so the next photo comes in beside this one, and on release the
// strip settles on the nearest page, carried on by the swipe. Over the bottom, the post's author
// and text; a click on a photo hides or shows them with the buttons. A video page is the player,
// which has its own share and close.
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, Share, X } from 'lucide-react';
import { L, store, type FeedItem } from '@twimshelf/core';
import { useStore } from '../lib/hooks';
import { core } from '../lib/core';
import { openMenuBelow, type MenuEntry } from '../components/Menu';
import { toast } from '../components/toast';
import { PhotoPage, previewOf, type PhotoHandle } from './PhotoPage';
import { Player, type PlayerHandle } from './Player';
import { Caption, captionShows } from './Caption';
import { WheelStream } from '../lib/wheelGesture';
import { animateViewer, fitMedia, intersect, type ViewerSource } from './transition';
import './Viewer.css';

interface ViewerOptions {
  source?: ViewerSource;
  squarePreview?: string;
  onClose?: (last: FeedItem) => void;
}

const viewer = store<({ items: FeedItem[]; index: number } & ViewerOptions) | null>(null);

/** Opens the viewer on `items[index]`; `source` resolves a thumbnail's current position. */
export function openViewer(items: FeedItem[], index: number, options?: ViewerOptions): void {
  if (items.length && !viewer.get()) viewer.set({ items, index: Math.max(0, Math.min(index, items.length - 1)), ...options });
}
export const viewerOpen = () => viewer.get() != null;
/** Whether the viewer covers the window (inline videos stop under it). */
export const viewerState = viewer;

export function ViewerHost() {
  const v = useStore(viewer);
  if (!v) return null;
  return <Viewer {...v} onClose={(last) => {
    if (viewer.get() !== v) return;
    viewer.set(null);
    v.onClose?.(last);
  }} />;
}

const GAP = 40;

function Viewer({ items, index: start, source, squarePreview, onClose }: {
  items: FeedItem[];
  index: number;
  source?: ViewerSource;
  squarePreview?: string;
  onClose: (last: FeedItem) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const surface = useRef<HTMLDivElement>(null);
  const animations = useRef<Animation[]>([]);
  const closing = useRef(false);
  const currentPage = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: window.innerWidth, h: window.innerHeight });
  const [index, setIndex] = useState(start);
  const [offset, setOffset] = useState(0);
  const [chromeHidden, setChromeHidden] = useState(false);
  const [idle, setIdle] = useState(false);
  const photos = useRef(new Map<number, PhotoHandle | null>());
  const player = useRef<PlayerHandle | null>(null);
  const item = items[index];
  const stride = size.w + GAP;
  const st = useRef({ index, offset, stride });
  st.current = { index, offset, stride };

  const mediaFrame = useCallback((media: FeedItem) => {
    const bounds = box.current!.getBoundingClientRect();
    const page = currentPage.current;
    const photo = page?.querySelector('.photo-frame');
    if (photo) return intersect(photo.getBoundingClientRect(), bounds);
    const video = page?.querySelector('video');
    return intersect(fitMedia(video?.getBoundingClientRect() ?? bounds,
      video?.videoWidth || media.size?.[0] || 0, video?.videoHeight || media.size?.[1] || 0), bounds);
  }, []);
  const cancelTransition = useCallback(() => {
    for (const animation of animations.current) {
      animation.onfinish = null;
      animation.cancel();
    }
    animations.current = [];
  }, []);

  // the window's buttons go while the viewer covers it (the desktop app on the Mac)
  useEffect(() => {
    window.twimshelf?.setViewerMode?.(true);
    box.current?.focus();
    return () => window.twimshelf?.setViewerMode?.(false);
  }, []);
  useLayoutEffect(() => {
    const el = box.current!;
    const ro = new ResizeObserver(() => setSize({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  useLayoutEffect(() => {
    const first = items[start];
    const [animation] = animations.current = animateViewer(surface.current!, mediaFrame(first), source?.(first.media_id), true);
    animation.onfinish = cancelTransition;
    return cancelTransition;
  }, [items, start, source, mediaFrame, cancelTransition]);

  // ── the strip's motion, frame by frame (a new swipe can catch a page mid-way) ──
  const motion = useRef<{ from: number; to: number; start: number; duration: number; done: () => void } | null>(null);
  const raf = useRef(0);
  const animate = useCallback((to: number, duration: number, done: () => void) => {
    motion.current = { from: st.current.offset, to, start: performance.now(), duration: duration * 1000, done };
    cancelAnimationFrame(raf.current);
    const tick = (now: number) => {
      const m = motion.current;
      if (!m) return;
      const t = Math.min(1, (now - m.start) / m.duration);
      const e = 1 - Math.pow(1 - t, 3);
      const o = m.from + (m.to - m.from) * e;
      st.current.offset = o;
      setOffset(o);
      if (t >= 1) { motion.current = null; m.done(); return; }
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
  }, []);
  const finishMotion = useCallback(() => {
    const m = motion.current;
    if (!m) return;
    motion.current = null;
    cancelAnimationFrame(raf.current);
    st.current.offset = m.to;
    setOffset(m.to);
    m.done();
  }, []);
  useEffect(() => () => cancelAnimationFrame(raf.current), []);

  /** The strip settled one page further (or back): that page is the current one now. */
  const commit = useCallback((d: number) => {
    const { index: i, stride: s } = st.current;
    if (d === 0 || !items[i + d]) { st.current.offset = 0; setOffset(0); return; }
    photos.current.get(i)?.reset();
    const o = st.current.offset + d * s;
    st.current = { ...st.current, index: i + d, offset: o };
    setIndex(i + d);
    setOffset(o);
    box.current?.focus();
  }, [items]);

  const bounce = useCallback((d: number) => animate(-d * 30, 0.12, () => animate(0, 0.22, () => {})), [animate]);
  const step = useCallback((d: number) => {
    if (closing.current || animations.current.length) return;
    finishMotion();
    if (!items[st.current.index + d]) { bounce(d); return; }
    animate(-d * st.current.stride, 0.3, () => commit(d));
  }, [items, animate, commit, bounce, finishMotion]);

  // ── two-finger swipes (wheel events from the trackpad; a mouse wheel's clicks are no swipe) ──
  const swipe = useRef<{ dx: number; dy: number; on: boolean; done: boolean; samples: { t: number; dx: number }[]; timer: number } | null>(null);
  const stream = useRef(new WheelStream());
  const settle = useCallback((v: number) => {
    const { offset: o, stride: s, index: i } = st.current;
    let d: number;
    if (Math.abs(v) > 350 && ((v < 0) === (o <= 0) || Math.abs(o) < s * 0.1)) d = v < 0 ? 1 : -1;
    else d = Math.round(-(o + v * 0.1) / s);
    d = Math.max(-1, Math.min(1, d));
    if (!items[i + d]) d = 0;
    const target = -d * s;
    const distance = Math.abs(target - o);
    const matched = Math.abs(v) > 1 ? (3 * distance) / Math.abs(v) : 0.3;
    animate(target, Math.min(0.38, Math.max(0.16, matched)), () => commit(d));
  }, [items, animate, commit]);

  /** The swipe ended (the events stopped, or new fingers came): the strip settles. */
  const endSwipe = useCallback(() => {
    const g = swipe.current;
    swipe.current = null;
    if (!g) return;
    window.clearTimeout(g.timer);
    if (!g.on || g.done) return;
    const span = g.samples.length > 1 ? Math.max(1000 / 60, g.samples[g.samples.length - 1].t - g.samples[0].t) : 1;
    const v = g.samples.length > 1 ? g.samples.reduce((a, b) => a + b.dx, 0) / (span / 1000) : 0;
    settle(Math.abs(v) < 50 ? 0 : v * 0.3);
  }, [settle]);

  const onWheel = useCallback((e: WheelEvent) => {
    e.preventDefault();
    if (closing.current || animations.current.length) return;
    const page = photos.current.get(st.current.index);
    // a pinch zooms the photo; a zoomed photo pans with two fingers
    if (e.ctrlKey) { page?.wheel(e); return; }
    if (page?.zoomed()) { page.wheel(e); return; }
    // a mouse wheel (whole lines) is no swipe
    if (e.deltaMode !== 0 || items.length < 2) return;
    const now = performance.now();
    // a new gesture (also one that starts while the last one's momentum still runs) ends the last
    if (stream.current.next(e)) {
      endSwipe();
      // the momentum of a swipe that already turned the page moves nothing
      if (stream.current.momentum) return;
    }
    let s = swipe.current;
    if (!s) s = swipe.current = { dx: 0, dy: 0, on: false, done: false, samples: [], timer: 0 };
    window.clearTimeout(s.timer);
    s.timer = window.setTimeout(endSwipe, 90);
    if (s.done) return;
    // the events started shrinking: the fingers lifted and this is the trackpad's momentum. The
    // strip settles now with the fingers' speed (as on the Mac), the momentum moves nothing.
    if (s.on && stream.current.momentum) {
      const g = s;
      const span = g.samples.length > 1 ? Math.max(1000 / 60, g.samples[g.samples.length - 1].t - g.samples[0].t) : 1;
      const v = g.samples.length > 1 ? g.samples.reduce((a, b) => a + b.dx, 0) / (span / 1000) : 0;
      g.done = true;
      settle(v);
      return;
    }
    // with the fingers: the content follows them
    const dx = -e.deltaX, dy = -e.deltaY;
    if (!s.on) {
      s.dx += dx; s.dy += dy;
      if (!(Math.abs(s.dx) > 4 && Math.abs(s.dx) > Math.abs(s.dy) * 1.2)) return;
      // caught mid-way: the strip goes on from where it is
      motion.current = null;
      cancelAnimationFrame(raf.current);
      s.on = true;
      move(s.dx, now);
    } else if (dx !== 0) move(dx, now);
    function move(d: number, t: number) {
      const g = swipe.current!;
      g.samples.push({ t, dx: d });
      while (g.samples.length && t - g.samples[0].t > 100) g.samples.shift();
      const { offset: o, index: i, stride: str } = st.current;
      const atEnd = (o + d > 0 && i === 0) || (o + d < 0 && i === items.length - 1);
      const next = Math.max(-str, Math.min(str, o + (atEnd ? d * 0.3 : d)));
      st.current.offset = next;
      setOffset(next);
      // a whole page moved under the fingers: that page it is, the rest of the gesture is spent
      if (Math.abs(next) >= str - 0.5 && !atEnd) { g.done = true; commit(next < 0 ? 1 : -1); }
    }
  }, [items, endSwipe, commit, settle]);

  useEffect(() => {
    const el = box.current!;
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [onWheel]);

  // ── share, copy ──
  const copy = useCallback(async () => {
    const it = items[st.current.index];
    try {
      const im = photos.current.get(st.current.index)?.image();
      if (it.kind === 'photo' && im && im.complete && 'ClipboardItem' in window) {
        const c = document.createElement('canvas');
        c.width = im.naturalWidth; c.height = im.naturalHeight;
        c.getContext('2d')!.drawImage(im, 0, 0);
        const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/png'));
        if (blob) { await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]); toast(L('viewer.copied')); return; }
      }
      await navigator.clipboard.writeText(it.path);
      toast(L('viewer.copied'));
    } catch {
      toast(L('viewer.copyFailed'));
    }
  }, [items]);
  const saveAs = useCallback(() => {
    const it = items[st.current.index];
    const a = document.createElement('a');
    a.href = core.fileUrl(it.path);
    a.download = it.path.split(/[\\/]/).pop() ?? 'media';
    a.click();
  }, [items]);
  const share = useCallback((el: Element) => {
    const it = items[st.current.index];
    const entries: MenuEntry[] = [
      { label: L('viewer.copy'), run: () => void copy() },
      { label: L('windows.viewer.saveAs'), run: saveAs },
    ];
    if (window.twimshelf?.showItemInFolder) entries.push('separator', { label: L('mac.showInFinder'), run: () => window.twimshelf!.showItemInFolder!(it.path) });
    openMenuBelow(el, entries);
  }, [items, copy, saveAs]);

  const close = useCallback(() => {
    if (closing.current) return;
    closing.current = true;
    motion.current = null;
    cancelAnimationFrame(raf.current);
    window.clearTimeout(swipe.current?.timer);
    const el = surface.current!;
    const css = getComputedStyle(el);
    const interrupted = animations.current.length ? {
      transform: css.transform,
      clipPath: css.clipPath === 'none' ? 'inset(0px 0px 0px 0px)' : css.clipPath,
      opacity: css.opacity,
    } : undefined;
    cancelTransition();
    el.inert = true;
    const last = items[st.current.index];
    const target = source?.(last.media_id) ?? source?.(items[start].media_id);
    const [animation] = animations.current = animateViewer(el, mediaFrame(last), target, false, interrupted);
    animation.onfinish = () => onClose(last);
  }, [items, start, source, onClose, mediaFrame, cancelTransition]);

  // ── keys ──
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.target as Element | null)?.closest?.('input, textarea')) return;
      if (document.querySelector('.menu-scrim, .dialog-scrim')) return;
      if (closing.current) return;
      const it = items[st.current.index];
      const p = it.kind === 'video' ? player.current : null;
      // on a video, ← → seek (as the Mac player's keys); the round buttons turn the page
      const seeks = true;
      if (p && seeks && e.key === 'ArrowLeft') p.seek(-5);
      else if (p && seeks && e.key === 'ArrowRight') p.seek(5);
      else if (p && e.key === ' ') p.togglePlay();
      else if (p && e.key === 'ArrowUp') p.volume(0.1);
      else if (p && e.key === 'ArrowDown') p.volume(-0.1);
      else if (e.key === 'Escape') close();
      else if (e.key === 'ArrowLeft') step(-1);
      else if (e.key === 'ArrowRight') step(1);
      else if ((e.key === 'f' || e.key === 'F') && !e.metaKey && !e.ctrlKey) {
        if (window.twimshelf?.toggleFullScreen) window.twimshelf.toggleFullScreen();
        else if (document.fullscreenElement) void document.exitFullscreen(); else void document.documentElement.requestFullscreen().catch(() => {});
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'c') void copy();
      else return;
      e.preventDefault();
      e.stopPropagation();
    };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, [items, close, step, copy]);

  // ── a click on a photo: the caption and buttons go or come back; a double click zooms ──
  const pendingClick = useRef(0);
  useEffect(() => () => {
    window.clearTimeout(pendingClick.current);
    window.clearTimeout(swipe.current?.timer);
  }, []);
  const click = (e: React.MouseEvent) => {
    if (closing.current || animations.current.length) return;
    if (items[st.current.index].kind !== 'photo' || e.button !== 0) return;
    const r = box.current!.getBoundingClientRect();
    if (e.detail === 2) {
      window.clearTimeout(pendingClick.current);
      photos.current.get(st.current.index)?.toggleZoom(e.clientX - r.left, e.clientY - r.top);
      return;
    }
    if (e.detail !== 1) return;
    pendingClick.current = window.setTimeout(() => setChromeHidden((h) => !h), 300);
  };

  if (!item) return null;
  const multi = items.length > 1;
  // the position within the current post
  let lo = index, hi = index;
  while (lo > 0 && items[lo - 1].post_id === item.post_id) lo--;
  while (hi < items.length - 1 && items[hi + 1].post_id === item.post_id) hi++;
  const counter = multi && hi > lo ? `${index - lo + 1} / ${hi - lo + 1}` : '';
  // the caption belongs to the post: while the strip moves towards another post's media it fades
  const towards = items[index + (offset < 0 ? 1 : -1)];
  const leaving = offset !== 0 && towards && towards.post_id !== item.post_id;
  const captionOpacity = leaving ? Math.max(0, 1 - Math.abs(offset) / Math.max(1, stride * 0.4)) : 1;
  const video = item.kind === 'video';
  const initialVideoPreview = video && index === start && squarePreview
    ? fitMedia(new DOMRectReadOnly(0, 0, size.w, size.h), item.size?.[0] ?? 0, item.size?.[1] ?? 0)
    : null;
  const pages = [index - 1, index, index + 1].filter((i) => i >= 0 && i < items.length);

  return (
    <div ref={box} className={`viewer${idle && video ? ' idle' : ''}`} data-index={index} role="dialog" aria-modal="true" tabIndex={-1} onMouseDown={click}>
      <div ref={surface} className="viewer-surface">
        <div className="viewer-strip">
          {pages.map((i) => (
            <div key={items[i].media_id} ref={i === index ? currentPage : undefined} className="viewer-page" style={{ transform: `translateX(${(i - index) * stride + offset}px)`, width: size.w }}>
              {items[i].kind === 'photo'
                ? <PhotoPage ref={(h) => { if (h) photos.current.set(i, h); else photos.current.delete(i); }} item={items[i]} width={size.w} height={size.h} squarePreview={i === start ? squarePreview : undefined} />
                : i === index
                  ? <Player ref={player} item={items[i]} poster={previewOf(items[i])}
                      squarePreview={initialVideoPreview && squarePreview ? { url: squarePreview, side: Math.min(initialVideoPreview.width, initialVideoPreview.height) } : undefined}
                      onClose={close} onShare={share} onIdle={setIdle} />
                  : <Poster item={items[i]} />}
            </div>
          ))}
        </div>
        {counter && !chromeHidden && <div className="viewer-counter">{counter}</div>}
        {multi && index > 0 && !chromeHidden && !(video && idle) && (
          <button className="viewer-round viewer-prev" aria-label={L('viewer.previous.mac')} title={L('viewer.previous.mac')} onMouseDown={(e) => e.stopPropagation()} onClick={() => step(-1)}><ChevronLeft size={20} strokeWidth={2.4} /></button>
        )}
        {multi && index < items.length - 1 && !chromeHidden && !(video && idle) && (
          <button className="viewer-round viewer-next" aria-label={L('viewer.next.mac')} title={L('viewer.next.mac')} onMouseDown={(e) => e.stopPropagation()} onClick={() => step(1)}><ChevronRight size={20} strokeWidth={2.4} /></button>
        )}
        {!chromeHidden && captionShows(item) && !(video && idle) && (
          <Caption item={item} maxHeight={size.h * 0.5} trailing={video ? 16 : 110} bottom={video ? 76 : 0} opacity={captionOpacity} />
        )}
        {!video && !chromeHidden && (
          <div className="viewer-corner" onMouseDown={(e) => e.stopPropagation()}>
            <button className="viewer-round small" aria-label={L('viewer.share.mac')} title={L('viewer.share.mac')} onClick={(e) => share(e.currentTarget)}><Share size={15} strokeWidth={2.2} /></button>
            <button className="viewer-round small" aria-label={L('viewer.close.mac')} title={L('viewer.close.mac')} onClick={close}><X size={16} strokeWidth={2.4} /></button>
          </div>
        )}
      </div>
    </div>
  );
}

/** A video page that is not the current one: its frame. */
function Poster({ item }: { item: FeedItem }) {
  const src = previewOf(item);
  return <div className="photo-page">{src && <img className="poster-img" src={src} alt="" draggable={false} />}</div>;
}

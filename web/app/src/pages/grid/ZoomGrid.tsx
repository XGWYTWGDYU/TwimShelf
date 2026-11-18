// The zoomable media grid (MacMediaGridView.swift) on the same engine as the Mac's and the
// iPhone's: a canvas draws every tile; a transparent scroller on top gives the scrolling (momentum,
// the scroll bar) and takes the pointer. Pinch the trackpad to zoom between the three levels as on
// the phone (the pointer is the fingers); ⌘+ / ⌘− or the toolbar go one level. Scrolling during the
// settle ends it at once. Click opens a media (toggles it while selecting; drag across tiles to
// select several); right-click gives its menu.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef } from 'react';
import type { FeedItem } from '@twimshelf/core';
import { cachedThumb, thumb, warmThumbs } from '../../lib/thumbs';
import { GridScene, type ZoomGridTile } from './scene';
import { GridConfig, type Tile } from './zoom';

export interface ZoomGridHandle {
  step(delta: number): void;
  level(): number;
  levelCount(): number;
  focus(): void;
  sourceFrame(mediaId: string): DOMRectReadOnly | undefined;
}

export interface ZoomGridProps {
  tiles: ZoomGridTile[];
  footer: string;
  selecting: boolean;
  selected: Set<string>;
  initialLevel: number;
  /** Room at the top (the toolbar the grid runs under) and at the bottom. */
  insetTop: number;
  bottomInset?: number;
  onOpen(index: number): void;
  onMenu(index: number, e: { clientX: number; clientY: number }): void;
  onSelected(next: Set<string>): void;
  onSettle(level: number): void;
}

const FOOTER = 52;
const SIDES = [256, 512, 1024];

/** Pictures by media id, at the sizes loaded: decoded off the main thread straight into GPU-ready
 *  bitmaps, so a zoom that brings many new tiles draws them without stalling on decoding or on
 *  uploading pictures in the middle of a frame. */
const pictures = new Map<string, { side: number; img: ImageBitmap }>();
const loading = new Set<string>();
let started = 0;
/** What the decoded pictures may take together; those not drawn for the longest go first. */
const MAX_PICTURE_BYTES = 512 * 1024 * 1024;
let pictureBytes = 0;
const bytesOf = (img: ImageBitmap) => img.width * img.height * 4;

function keep(id: string, side: number, img: ImageBitmap) {
  const old = pictures.get(id);
  if (old) { pictureBytes -= bytesOf(old.img); old.img.close(); pictures.delete(id); }
  pictures.set(id, { side, img });
  pictureBytes += bytesOf(img);
  for (const [other, p] of pictures) {
    if (pictureBytes <= MAX_PICTURE_BYTES || other === id) break;
    pictureBytes -= bytesOf(p.img);
    p.img.close();
    pictures.delete(other);
  }
}

function picture(item: FeedItem, side: number, priority: number, onLoad: () => void): ImageBitmap | null {
  const have = pictures.get(item.media_id);
  // the map's order is the order of last use
  if (have) { pictures.delete(item.media_id); pictures.set(item.media_id, have); }
  if (!(have && have.side >= side)) {
    const key = `${item.media_id}@${side}`;
    // at most a few new requests per frame (the rest are asked for in the next frames)
    if (!loading.has(key) && started < 24) {
      started++;
      if (!have) for (const s of SIDES) { const u = cachedThumb(item, s); if (u) { load(item.media_id, s, u, onLoad); break; } }
      loading.add(key);
      thumb(item, side, priority).then((u) => load(item.media_id, side, u, onLoad), () => {}).finally(() => loading.delete(key));
    }
  }
  return have?.img ?? null;
}

function load(id: string, side: number, url: string, onLoad: () => void): Promise<void> {
  return fetch(url, { credentials: 'same-origin' })
    .then((r) => r.blob())
    .then((b) => createImageBitmap(b))
    .then((bmp) => {
      // a square crop for the tile (video frames come whole)
      const m = Math.min(bmp.width, bmp.height);
      if (bmp.width === bmp.height) return bmp;
      return createImageBitmap(bmp, (bmp.width - m) / 2, (bmp.height - m) / 2, m, m).finally(() => bmp.close());
    })
    .then((bmp) => {
      const now = pictures.get(id);
      if (!now || now.side < side) keep(id, side, bmp); else bmp.close();
      onLoad();
    }, () => {});
}

export const ZoomGrid = forwardRef<ZoomGridHandle, ZoomGridProps>(function ZoomGrid(props, ref) {
  const box = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const spacer = useRef<HTMLDivElement>(null);
  const footer = useRef<HTMLDivElement>(null);
  const scene = useRef<GridScene | null>(null);
  const p = useRef(props);
  p.current = props;
  const drawn = useRef<Tile[]>([]);
  const needsDraw = useRef(true);
  const syncing = useRef(false);
  const colors = useRef({ bg: '#fff', placeholder: '#e6e6e6' });

  const readColors = useCallback(() => {
    const cs = getComputedStyle(box.current!);
    colors.current = { bg: cs.getPropertyValue('--bg').trim() || '#fff', placeholder: cs.getPropertyValue('--placeholder-tile').trim() || '#e6e6e6' };
    needsDraw.current = true;
  }, []);

  const config = useCallback((): GridConfig => {
    const el = box.current!;
    const w = el.clientWidth, h = el.clientHeight;
    return new GridConfig({ width: w, height: h, scale: window.devicePixelRatio || 1, insetTop: p.current.insetTop, insetBottom: FOOTER + (p.current.bottomInset ?? 0), count: 0, columns: GridConfig.columnsForWidth(w) });
  }, []);

  // ── scroller ↔ resting layout ──
  const applyRestToScroll = useCallback(() => {
    const s = scene.current, sc = scroller.current;
    if (!s || !sc) return;
    const cfg = s.engine.cfg, r = s.engine.rest;
    const h = cfg.contentHeight(r.level, r.phase);
    syncing.current = true;
    spacer.current!.style.height = `${cfg.insetTop + Math.max(h, 1) + cfg.insetBottom}px`;
    sc.scrollTop = r.offset;
    footer.current!.style.top = `${cfg.insetTop + h + 14}px`;
    requestAnimationFrame(() => { syncing.current = false; });
    needsDraw.current = true;
  }, []);

  const updateContentHeight = useCallback(() => {
    const s = scene.current, sc = scroller.current;
    if (!s || !sc) return;
    const cfg = s.engine.cfg, r = s.engine.rest;
    const h = cfg.contentHeight(r.level, r.phase);
    spacer.current!.style.height = `${cfg.insetTop + Math.max(h, 1) + cfg.insetBottom}px`;
    footer.current!.style.top = `${cfg.insetTop + h + 14}px`;
    const max = cfg.maxOffset(r.level, r.phase);
    if (r.offset > max + 0.5) sc.scrollTo({ top: max, behavior: 'smooth' });
    needsDraw.current = true;
  }, []);

  // ── drawing ──
  const draw = useCallback((t: number) => {
    const s = scene.current, c = canvas.current;
    if (!s || !c) return;
    const wasZooming = s.engine.isZooming;
    const ended = s.frame(t, drawn.current);
    if (wasZooming && ended) zoomDidEnd();
    const cfg = s.engine.cfg;
    const dpr = cfg.scale;
    const W = Math.round(cfg.width * dpr), H = Math.round(cfg.height * dpr);
    if (c.width !== W || c.height !== H) { c.width = W; c.height = H; }
    const ctx = c.getContext('2d', { alpha: false })!;
    started = 0;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.globalAlpha = 1;
    ctx.fillStyle = colors.current.bg;
    ctx.fillRect(0, 0, cfg.width, cfg.height);
    const onLoad = () => { needsDraw.current = true; };
    const sel = s.selecting;
    for (const tile of drawn.current) {
      const info = s.tileOf(tile.photo);
      if (tile.y + tile.side < 0 || tile.y > cfg.height) continue;
      ctx.globalAlpha = tile.alpha;
      ctx.save();
      ctx.beginPath();
      ctx.roundRect(tile.x, tile.y, tile.side, tile.side, tile.radii);
      ctx.clip();
      const img = info ? picture(info.item, SIDES.find((x) => x >= tile.side * dpr) ?? 1024, Math.abs(tile.y), onLoad) : null;
      if (img) {
        ctx.drawImage(img, tile.x, tile.y, tile.side, tile.side);
      } else {
        ctx.fillStyle = colors.current.placeholder;
        ctx.fillRect(tile.x, tile.y, tile.side, tile.side);
      }
      const sd = tile.side;
      // a video: a small play triangle bottom left, on tiles of 40 and up
      if (info?.item.kind === 'video' && sd >= 40) {
        const ox = tile.x + 6, oy = tile.y + sd - 18;
        ctx.beginPath(); ctx.moveTo(ox + 1.5, oy); ctx.lineTo(ox + 1.5, oy + 12); ctx.lineTo(ox + 12, oy + 6); ctx.closePath();
        ctx.shadowColor = 'rgba(0,0,0,0.35)'; ctx.shadowBlur = 2;
        ctx.fillStyle = '#fff'; ctx.fill();
        ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0;
      }
      // a post of several media: their number bottom right, on tiles of 50 and up
      if (info && info.count > 1 && sd >= 50) {
        ctx.font = '600 13px -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif';
        ctx.textAlign = 'right'; ctx.textBaseline = 'alphabetic';
        ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 2; ctx.shadowOffsetY = 0.5;
        ctx.fillStyle = '#fff';
        ctx.fillText(String(info.count), tile.x + sd - 6, tile.y + sd - 6);
        ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0; ctx.shadowOffsetY = 0;
      }
      // selected: a light veil and a blue check circle top right
      if (sel && info && s.selected.has(info.item.media_id)) {
        ctx.fillStyle = 'rgba(255,255,255,0.25)';
        ctx.fillRect(tile.x, tile.y, sd, sd);
        const cx = tile.x + sd - 16, cy = tile.y + 16;
        ctx.shadowColor = 'rgba(0,0,0,0.3)'; ctx.shadowBlur = 3;
        ctx.beginPath(); ctx.arc(cx, cy, 11, 0, Math.PI * 2); ctx.fillStyle = '#fff'; ctx.fill();
        ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0;
        ctx.beginPath(); ctx.arc(cx, cy, 9.5, 0, Math.PI * 2); ctx.fillStyle = '#007aff'; ctx.fill();
        ctx.beginPath(); ctx.moveTo(cx - 4.2, cy + 0.2 - 0.5); ctx.lineTo(cx - 1.2, cy + 3.4 - 0.5); ctx.lineTo(cx + 4.4, cy - 3.4 - 0.5);
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 2.2; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.stroke();
      }
      ctx.restore();
    }
    ctx.globalAlpha = 1;
    needsDraw.current = false;
    prefetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** At rest, the thumbnails of two screens above and below are made ready. */
  const lastPrefetch = useRef(NaN);
  const prefetch = useCallback(() => {
    const s = scene.current;
    if (!s || s.isAnimating) return;
    const r = s.engine.rest;
    if (!isNaN(lastPrefetch.current) && Math.abs(r.offset - lastPrefetch.current) <= s.engine.cfg.height / 3) return;
    lastPrefetch.current = r.offset;
    const side = SIDES.find((x) => x >= s.engine.cfg.side(r.level) * s.engine.cfg.scale) ?? 1024;
    s.nearbyKeys(2).forEach((k, i) => { const t = s.tileOf(k); if (t) picture(t.item, side, 2000 + i, () => { needsDraw.current = true; }); });
  }, []);

  // one frame loop for zooms, animations and pictures that arrived
  useEffect(() => {
    let raf = 0;
    const loop = (ms: number) => {
      const s = scene.current;
      if (s && (s.isAnimating || needsDraw.current)) draw(ms / 1000);
      advanceStep(ms / 1000);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draw]);

  // ── size ──
  useLayoutEffect(() => {
    const el = box.current!;
    readColors();
    const mq = matchMedia('(prefers-color-scheme: dark)');
    mq.addEventListener('change', readColors);
    const fit = () => {
      if (el.clientWidth <= 0 || el.clientHeight <= 0) return;
      const cfg = config();
      if (!scene.current) {
        const s = new GridScene(cfg, p.current.initialLevel);
        s.onRestChanged = applyRestToScroll;
        s.onContentHeightChanged = updateContentHeight;
        s.selecting = p.current.selecting;
        s.selected = new Set(p.current.selected);
        scene.current = s;
        s.setTiles(p.current.tiles);
        applyRestToScroll();
      } else if (!scene.current.engine.cfg.equals(cfg)) {
        scene.current.setConfig(cfg);
        lastPrefetch.current = NaN;
      }
      needsDraw.current = true;
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => { ro.disconnect(); mq.removeEventListener('change', readColors); };
  }, [config, applyRestToScroll, updateContentHeight, readColors]);

  // ── content ──
  useEffect(() => {
    const s = scene.current;
    if (!s) return;
    s.setTiles(props.tiles);
    lastPrefetch.current = NaN;
    // every tile's small thumbnail, made ahead (the densest level is what a zoom out shows)
    const cfg = s.engine.cfg;
    const small = SIDES.find((x) => x >= cfg.side(0) * cfg.scale) ?? 1024;
    void warmThumbs(props.tiles.filter((t) => t.item.kind === 'photo').map((t) => t.item.media_id), small);
    needsDraw.current = true;
  }, [props.tiles]);
  useEffect(() => {
    const s = scene.current;
    if (!s) return;
    s.selecting = props.selecting;
    s.selected = new Set(props.selected);
    needsDraw.current = true;
  }, [props.selecting, props.selected]);
  useEffect(() => {
    const s = scene.current;
    if (s && s.engine.cfg.insetBottom !== FOOTER + (props.bottomInset ?? 0)) { s.setConfig(config()); needsDraw.current = true; }
  }, [props.bottomInset, config]);

  // ── scrolling ──
  const onScroll = useCallback(() => {
    const s = scene.current, sc = scroller.current;
    if (!s || !sc || syncing.current || s.engine.isZooming) return;
    s.engine.rest = { ...s.engine.rest, offset: sc.scrollTop };
    s.realignBeforeTopShows();
    if (s.engine.rest.offset <= 0.5) s.realignToTop();
    draw(performance.now() / 1000);
  }, [draw]);

  // ── pinch (a trackpad pinch arrives as wheel events with ctrlKey) ──
  const pinch = useRef<{ scale: number; samples: { t: number; s: number }[]; timer: number; v: number } | null>(null);
  const zoomUI = useCallback((on: boolean) => {
    footer.current!.style.opacity = on ? '0' : '1';
  }, []);
  function zoomDidEnd() {
    zoomUI(false);
    const s = scene.current;
    if (s) p.current.onSettle(s.engine.rest.level);
    applyRestToScroll();
  }

  const onWheel = useCallback((e: WheelEvent) => {
    const s = scene.current;
    if (!s) return;
    if (!e.ctrlKey) {
      // a scroll starting during the release settle hands control straight to scrolling
      if (s.engine.isZooming && !s.engine.zoom?.pinching) { if (s.finishZoomNow()) zoomDidEnd(); }
      else if (s.engine.isZooming || step.current) e.preventDefault();
      return;
    }
    e.preventDefault();
    if (!s.engine.items.length) return;
    const r = box.current!.getBoundingClientRect();
    const f = { x: e.clientX - r.left, y: e.clientY - r.top };
    const t = performance.now() / 1000;
    let g = pinch.current;
    if (!g) {
      step.current = null;
      if (!s.engine.isZooming) s.engine.rest = { ...s.engine.rest, offset: scroller.current!.scrollTop };
      g = pinch.current = { scale: 1, samples: [{ t, s: 1 }], timer: 0, v: 0 };
      s.engine.beginPinch(f, t);
      zoomUI(true);
    }
    if (!s.engine.zoom?.pinching) return;
    g.scale *= Math.exp(-e.deltaY * 0.01);
    g.samples.push({ t, s: g.scale });
    while (g.samples.length > 1 && t - g.samples[0].t > 0.12) g.samples.shift();
    const first = g.samples[0];
    g.v = t - first.t > 0.01 ? (g.scale - first.s) / (t - first.t) : 0;
    s.engine.pinchChanged(g.scale, f);
    window.clearTimeout(g.timer);
    // the fingers lifted: no more events
    g.timer = window.setTimeout(() => {
      const gg = pinch.current;
      pinch.current = null;
      if (gg && scene.current?.engine.zoom?.pinching) scene.current.engine.release(gg.v, gg.scale);
    }, 70);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [zoomUI]);

  useEffect(() => {
    const sc = scroller.current!;
    sc.addEventListener('wheel', onWheel, { passive: false });
    return () => sc.removeEventListener('wheel', onWheel);
  }, [onWheel]);

  // ── one level in or out about the middle, as a short pinch (keys, toolbar) ──
  const step = useRef<{ to: number; start: number; finger: { x: number; y: number } } | null>(null);
  function advanceStep(t: number) {
    const st = step.current, s = scene.current;
    if (!st || !s) return;
    const k = Math.min(1, (t - st.start) / 0.3);
    const e = 1 - Math.pow(1 - k, 3);
    s.engine.pinchChanged(Math.pow(st.to, e), st.finger);
    if (k >= 1) { step.current = null; s.engine.release(0, st.to); }
  }

  useImperativeHandle(ref, () => ({
    step(delta: number) {
      const s = scene.current;
      if (!s || s.isBusy || !s.engine.items.length) return;
      const r = s.engine.rest, cfg = s.engine.cfg;
      const target = Math.min(Math.max(r.level - delta, 0), cfg.levels - 1);
      if (target === r.level) return;
      const mid = { x: cfg.width / 2, y: (cfg.height - cfg.insetBottom) / 2 };
      s.engine.rest = { ...r, offset: scroller.current!.scrollTop };
      const t = performance.now() / 1000;
      s.engine.beginPinch(mid, t);
      zoomUI(true);
      step.current = { to: cfg.side(target) / cfg.side(r.level), start: t, finger: mid };
    },
    level: () => scene.current?.engine.rest.level ?? p.current.initialLevel,
    levelCount: () => scene.current?.engine.cfg.levels ?? 3,
    focus: () => scroller.current?.focus(),
    sourceFrame(mediaId) {
      const bounds = box.current?.getBoundingClientRect();
      const s = scene.current;
      if (!bounds?.width || !bounds.height || !s) return;
      const index = s.tiles.findIndex((t) => t.item.media_id === mediaId);
      if (index < 0) return;
      const { x, y, w, h } = s.engine.restFrame(index, s.engine.rest);
      if (x + w > 0 && x < bounds.width && y + h > 0 && y < bounds.height) {
        return new DOMRectReadOnly(bounds.x + x, bounds.y + y, w, h);
      }
    },
  }), [zoomUI]);

  // ── clicks, selection, menu ──
  const drag = useRef<{ start: number | null; selects: boolean; base: Set<string>; dragged: boolean } | null>(null);
  const indexAt = (e: { clientX: number; clientY: number }): number | null => {
    const s = scene.current;
    if (!s || s.isAnimating) return null;
    const r = box.current!.getBoundingClientRect();
    return s.engine.restIndex({ x: e.clientX - r.left, y: e.clientY - r.top });
  };
  const down = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    const i = indexAt(e);
    const id = i != null ? p.current.tiles[i]?.item.media_id : undefined;
    drag.current = { start: i, selects: !(id && p.current.selected.has(id)), base: new Set(p.current.selected), dragged: false };
    const move = (ev: MouseEvent) => {
      const d = drag.current;
      if (!d || !p.current.selecting || d.start == null) return;
      const j = indexAt(ev);
      if (j == null) return;
      d.dragged = true;
      const ids = p.current.tiles.slice(Math.min(d.start, j), Math.max(d.start, j) + 1).map((t) => t.item.media_id);
      const next = new Set(d.base);
      for (const x of ids) { if (d.selects) next.add(x); else next.delete(x); }
      p.current.onSelected(next);
    };
    const up = (ev: MouseEvent) => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      const d = drag.current;
      drag.current = null;
      if (!d || d.dragged) return;
      const j = indexAt(ev);
      if (j == null || j !== d.start) return;
      if (p.current.selecting) {
        const x = p.current.tiles[j]?.item.media_id;
        if (!x) return;
        const next = new Set(p.current.selected);
        if (next.has(x)) next.delete(x); else next.add(x);
        p.current.onSelected(next);
      } else p.current.onOpen(j);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };

  return (
    <div ref={box} className="zoom-grid">
      <canvas ref={canvas} className="zoom-grid-canvas" />
      <div ref={scroller} className="zoom-grid-scroller" tabIndex={-1} onScroll={onScroll} onMouseDown={down}
        onClick={(e) => {
          // a click without a mouse press (accessibility, a keyboard): open or toggle as a click does
          if (e.detail !== 0) return;
          const j = indexAt(e);
          if (j == null) return;
          if (p.current.selecting) {
            const x = p.current.tiles[j]?.item.media_id;
            if (!x) return;
            const next = new Set(p.current.selected);
            if (next.has(x)) next.delete(x); else next.add(x);
            p.current.onSelected(next);
          } else p.current.onOpen(j);
        }}
        onContextMenu={(e) => { e.preventDefault(); const i = indexAt(e); if (i != null) props.onMenu(i, e); }}>
        <div ref={spacer} className="zoom-grid-spacer">
          <div ref={footer} className="zoom-grid-footer">{props.footer}</div>
        </div>
      </div>
    </div>
  );
});

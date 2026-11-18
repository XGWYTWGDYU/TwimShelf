// The media behind the zoomable grid's tiles and the two animations that change its layout without
// a zoom: a port of GridScene.swift. Re-aligning the first row (a conveyor shift, only near the
// top: the first row is never partly empty), and a removal (later tiles slide straight to their
// new places, the removed ones fade out in place; cubic-bezier(0.25, 0.9, 0.3, 1), 0.36 s).
import type { FeedItem } from '@twimshelf/core';
import { clampf, GridConfig, posmod, ZoomEngine, type RestState, type Tile } from './zoom';

export interface ZoomGridTile {
  item: FeedItem;
  /** Media in the post (grouped); a badge shows it when more than one. */
  count: number;
}

const now = () => performance.now() / 1000;

export class GridScene {
  readonly engine: ZoomEngine;
  tiles: ZoomGridTile[] = [];
  private keys = new Map<string, number>();
  private tileByKey = new Map<number, ZoomGridTile>();
  private nextKey = 0;
  selecting = false;
  selected = new Set<string>();
  private reflow: { from: RestState; to: RestState; start: number } | null = null;
  private deletion: { oldItems: number[]; removed: Set<number>; rest: RestState; start: number } | null = null;
  private pending: ZoomGridTile[] | null = null;
  private lastScroll: { offset: number; time: number } | null = null;
  static glideBelow = 300;

  /** The resting layout changed without a scroll: the view sets its content size and offset. */
  onRestChanged?: () => void;
  /** The content height changed while the offset stays. */
  onContentHeightChanged?: () => void;

  constructor(cfg: GridConfig, level: number) {
    this.engine = new ZoomEngine(cfg, { level: Math.min(Math.max(level, 0), cfg.levels - 1), phase: 0, offset: 0 });
    this.engine.items = [];
  }

  get isAnimating(): boolean { return this.engine.isZooming || this.reflow != null || this.deletion != null; }
  get isBusy(): boolean { return this.engine.isZooming || this.deletion != null; }

  tileOf(key: number): ZoomGridTile | undefined { return this.tileByKey.get(key); }
  tileAt(index: number): ZoomGridTile | undefined { return this.tiles[index]; }
  isSelected(key: number): boolean { const t = this.tileByKey.get(key); return this.selecting && !!t && this.selected.has(t.item.media_id); }

  private key(id: string): number {
    const k = this.keys.get(id);
    if (k != null) return k;
    this.nextKey++;
    this.keys.set(id, this.nextKey);
    return this.nextKey;
  }

  /** A new list. Only removals animate; anything else keeps the media in the middle where it is. */
  setTiles(t: ZoomGridTile[]): void {
    if (this.isBusy) { this.pending = t; return; }
    const newKeys = t.map((x) => this.key(x.item.media_id));
    const old = this.engine.items;
    newKeys.forEach((k, i) => this.tileByKey.set(k, t[i]));
    const ids = new Set(t.map((x) => x.item.media_id));
    for (const s of [...this.selected]) if (!ids.has(s)) this.selected.delete(s);
    if (newKeys.length === old.length && newKeys.every((k, i) => k === old[i])) { this.tiles = t; return; }
    if (old.length && newKeys.length < old.length) {
      const removed = GridScene.removal(old, newKeys);
      if (removed) { this.tiles = t; this.startDeletion(removed); return; }
    }
    this.replace(t, newKeys);
  }

  private static removal(old: number[], next: number[]): Set<number> | null {
    const removed = new Set<number>();
    let j = 0;
    old.forEach((k, i) => { if (j < next.length && next[j] === k) j++; else removed.add(i); });
    return j === next.length ? removed : null;
  }

  private replace(t: ZoomGridTile[], newKeys: number[]): void {
    const e = this.engine, cfg = e.cfg, r = e.rest;
    const mid = { x: cfg.width / 2, y: cfg.insetTop + (cfg.height - cfg.insetTop - cfg.insetBottom) / 2 };
    const ai = e.restIndex(mid) ?? (e.items.length ? 0 : null);
    const anchor = ai != null ? { k: e.items[ai], f: e.restFrame(ai, r) } : null;
    this.tiles = t;
    e.items = newKeys;
    this.reflow = null;
    const rest: RestState = { level: r.level, phase: 0, offset: 0 };
    const j = anchor ? newKeys.indexOf(anchor.k) : -1;
    if (anchor && j >= 0) {
      const n = cfg.columns[r.level];
      const col = Math.round(anchor.f.x / cfg.pitch(r.level));
      rest.phase = posmod(col - j, n);
      const row = Math.floor((j + rest.phase) / n);
      rest.offset = clampf(cfg.insetTop + row * cfg.pitch(r.level) - anchor.f.y, 0, cfg.maxOffset(r.level, rest.phase));
      if (rest.offset < cfg.insetTop + cfg.side(r.level) + cfg.pitch(r.level)) {
        const row0 = Math.floor(j / n);
        rest.phase = 0;
        rest.offset = clampf(cfg.insetTop + row0 * cfg.pitch(r.level) - anchor.f.y, 0, cfg.maxOffset(r.level, 0));
      }
    }
    e.rest = rest;
    this.onRestChanged?.();
  }

  /** The view's size or insets changed: same level, the media in the middle stays. */
  setConfig(c: GridConfig): void {
    if (this.isBusy) return;
    const e = this.engine;
    const cfg = c.clone();
    cfg.count = e.items.length;
    if (cfg.width === e.cfg.width && cfg.scale === e.cfg.scale && cfg.columns.join() === e.cfg.columns.join()) {
      e.cfg = cfg;
      const r = e.rest;
      e.rest = { ...r, offset: clampf(r.offset, 0, cfg.maxOffset(r.level, r.phase)) };
      this.onRestChanged?.();
      return;
    }
    const level = e.rest.level;
    const midIndex = e.items.length ? (e.restIndex({ x: e.cfg.width / 2, y: e.cfg.insetTop + 1 }) ?? 0) : null;
    const hadOffset = e.rest.offset > 0;
    e.cfg = cfg;
    const rest: RestState = { level: Math.min(level, cfg.levels - 1), phase: 0, offset: 0 };
    if (midIndex != null && hadOffset) {
      const row = Math.floor(midIndex / cfg.columns[rest.level]);
      rest.offset = clampf(cfg.insetTop + row * cfg.pitch(rest.level) - cfg.insetTop, 0, cfg.maxOffset(rest.level, 0));
    }
    e.rest = rest;
    this.reflow = null;
    this.onRestChanged?.();
  }

  /** While scrolling near the top: a grid left with a phase by a zoom re-aligns. */
  realignBeforeTopShows(): void {
    const cfg = this.engine.cfg, r = this.engine.rest;
    const t = now();
    let speed = 0;
    const last = this.lastScroll;
    if (last && t - last.time > 0 && t - last.time < 0.1) speed = Math.abs(r.offset - last.offset) / (t - last.time);
    this.lastScroll = { offset: r.offset, time: t };
    if (r.phase === 0 || this.reflow) return;
    if (r.offset < cfg.insetTop + 3 * cfg.pitch(r.level)) this.realignToTop(speed < GridScene.glideBelow);
  }

  realignToTop(animated = true): void {
    if (this.engine.isZooming || this.reflow || this.deletion) return;
    const r = this.engine.rest;
    if (r.phase === 0) return;
    if (animated) this.reflow = { from: { ...r }, to: { level: r.level, phase: 0, offset: r.offset }, start: now() };
    this.engine.rest = { ...r, phase: 0 };
    this.onContentHeightChanged?.();
  }

  private startDeletion(removed: Set<number>): void {
    const old = this.engine.items;
    this.reflow = null;
    this.deletion = { oldItems: old, removed, rest: { ...this.engine.rest }, start: now() };
    this.engine.items = old.filter((_, i) => !removed.has(i));
  }

  private finishDeletion(): void {
    this.deletion = null;
    this.onContentHeightChanged?.();
    if (this.pending) { const p = this.pending; this.pending = null; this.setTiles(p); }
  }

  private zoomEnded(): void {
    const r = this.engine.rest;
    this.reflow = null;
    this.onRestChanged?.();
    if (r.phase !== 0 && r.offset < this.engine.cfg.insetTop + this.engine.cfg.side(r.level)) this.realignToTop();
    if (this.pending) { const p = this.pending; this.pending = null; this.setTiles(p); }
  }

  /** A settling zoom jumps to its end (the user started scrolling). Returns whether it ended. */
  finishZoomNow(): boolean {
    if (this.engine.finishNow()) { this.zoomEnded(); return true; }
    return false;
  }

  /** Tiles to draw now, back to front (advances the zoom and the animations). Returns whether a zoom ended. */
  frame(t: number, out: Tile[]): boolean {
    out.length = 0;
    let ended = false;
    const e = this.engine;
    if (e.isZooming) {
      if (this.deletion) this.finishDeletion();
      if (e.tick(t)) { this.zoomEnded(); ended = true; }
    }
    if (e.isZooming) e.zoomTiles(out);
    else if (this.deletion) this.deletionTiles(this.deletion, t, out);
    else if (this.reflow) this.reflowTiles(this.reflow, t, out);
    else e.restTiles(e.rest, out);
    return ended;
  }

  private reflowTiles(rf: { from: RestState; to: RestState; start: number }, tm: number, out: Tile[]): void {
    const t = Math.min(1, (tm - rf.start) / 0.3);
    const ez = 1 - Math.pow(1 - t, 3);
    const e = this.engine, cfg = e.cfg;
    const l = rf.to.level, n = cfg.columns[l];
    const p = cfg.pitch(l), side = cfg.side(l);
    const phase = rf.from.phase + (rf.to.phase - rf.from.phase) * ez;
    const offset = e.rest.offset;
    const rowMin = Math.floor((offset - cfg.insetTop) / p) - 1;
    const rowMax = Math.floor((offset - cfg.insetTop + cfg.height) / p) + 1;
    const iMin = Math.max(0, rowMin * n - rf.from.phase - 1);
    const iMax = Math.min(cfg.count - 1, (rowMax + 1) * n);
    if (t >= 1) this.reflow = null;
    if (iMin > iMax) return;
    const add = (col: number, row: number, index: number) => {
      const x = col * p, y = cfg.insetTop + row * p - offset;
      if (x + side <= 0 || x >= cfg.width || y + side <= 0 || y >= cfg.height) return;
      out.push({ x, y, side, alpha: 1, index, photo: e.items[index], radii: e.radii(x, side, true, true) });
    };
    for (let i = iMin; i <= iMax; i++) {
      const k = i + phase;
      const row = Math.floor(k / n);
      const col = k - row * n;
      add(col, row, i);
      if (col > n - 1) add(col - n, row + 1, i);
    }
  }

  private deletionTiles(d: { oldItems: number[]; removed: Set<number>; rest: RestState; start: number }, tm: number, out: Tile[]): void {
    const t = Math.min(1, (tm - d.start) / 0.36);
    const ez = cubicBezier(0.25, 0.9, 0.3, 1, t);
    const e = this.engine, cfg = e.cfg;
    const r = { ...d.rest, offset: e.rest.offset };
    const n = cfg.columns[r.level], p = cfg.pitch(r.level), side = cfg.side(r.level);
    const rowMin = Math.floor((r.offset - cfg.insetTop) / p) - 1;
    const rowMax = Math.floor((r.offset - cfg.insetTop + cfg.height) / p) + 1;
    const lo = Math.max(0, rowMin * n - r.phase), hi = Math.min(d.oldItems.length - 1, (rowMax + 1) * n - r.phase);
    const frame = (i: number) => {
      const c = cfg.cell(i, r.level, r.phase);
      return { x: c.col * p, y: cfg.insetTop + c.row * p - r.offset };
    };
    const tile = (f: { x: number; y: number }, index: number, key: number, alpha: number): Tile =>
      ({ x: f.x, y: f.y, side, alpha, index, photo: key, radii: e.radii(f.x, side, true, true) });
    if (lo <= hi) {
      for (let i = lo; i <= hi; i++) if (d.removed.has(i)) out.push(tile(frame(i), i, d.oldItems[i], 1 - ez));
      let before = 0;
      for (const x of d.removed) if (x < lo) before++;
      for (let i = lo; i <= hi; i++) {
        if (d.removed.has(i)) { before++; continue; }
        const j = i - before;
        const f0 = frame(i), f1 = frame(j);
        const f = { x: f0.x + (f1.x - f0.x) * ez, y: f0.y + (f1.y - f0.y) * ez };
        if (f.y + side < 0 || f.y > cfg.height) continue;
        out.push(tile(f, j, d.oldItems[i], 1));
      }
    }
    if (t >= 1) this.finishDeletion();
  }

  /** Tiles a little beyond the screen (above and below) at rest, to load ahead of a scroll. */
  nearbyKeys(screens: number): number[] {
    const e = this.engine;
    const out: Tile[] = [];
    const h = e.cfg.height;
    for (let k = -screens; k <= screens; k++) {
      if (k === 0) continue;
      e.restTiles({ ...e.rest, offset: e.rest.offset + k * h }, out);
    }
    return out.map((t) => t.photo);
  }
}

/** CSS-style cubic-bezier timing function, y for a given x = t. */
export function cubicBezier(x1: number, y1: number, x2: number, y2: number, t: number): number {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  const bx = (s: number) => 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s;
  const by = (s: number) => 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s;
  let lo = 0, hi = 1;
  for (let i = 0; i < 30; i++) { const mid = (lo + hi) / 2; if (bx(mid) < t) lo = mid; else hi = mid; }
  return by((lo + hi) / 2);
}

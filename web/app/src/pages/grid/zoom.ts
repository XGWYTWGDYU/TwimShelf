// The zoomable grid's geometry and its pinch-zoom state machine: a port of the native apps'
// GridConfig.swift and ZoomEngine.swift (measured from the Photos app, research/FINDINGS.md), kept
// line for line so the web grid zooms exactly as the Mac's and the iPhone's.

export interface Tile {
  x: number;
  y: number;
  side: number;
  alpha: number;
  /** position in the item list (layout) */
  index: number;
  /** photo identity (appearance) */
  photo: number;
  /** top-left, top-right, bottom-right, bottom-left */
  radii: [number, number, number, number];
}

export interface RestState {
  level: number;
  phase: number;
  /** Scroll offset: content y shown at the top inset line. */
  offset: number;
}

export const clampf = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
export const posmod = (a: number, n: number) => ((a % n) + n) % n;

/** Geometry and the constants measured from the Photos app. */
export class GridConfig {
  width: number;
  height: number;
  scale: number;
  insetTop: number;
  insetBottom: number;
  count: number;
  /** Column counts the zoom settles on, densest first. Level index = position here. */
  columns: number[] = [5, 3, 1];

  constructor(o: { width: number; height: number; scale: number; insetTop: number; insetBottom: number; count: number; columns?: number[] }) {
    this.width = o.width; this.height = o.height; this.scale = o.scale;
    this.insetTop = o.insetTop; this.insetBottom = o.insetBottom; this.count = o.count;
    if (o.columns) this.columns = o.columns;
  }

  clone(): GridConfig { return new GridConfig({ ...this, columns: [...this.columns] }); }

  /** The three levels for a width: 5 / 3 / 1 up to a large phone, then as many columns as keep
   *  the tiles about as big as the phone's (80 / 134 / 402 pt). */
  static columnsForWidth(w: number): number[] {
    if (!(w > 500)) return [5, 3, 1];
    const one = Math.max(1, Math.round(w / 402));
    const three = Math.max(one + 1, Math.round(w / 134));
    const five = Math.max(three + 1, Math.round(w / 80.4));
    return [five, three, one];
  }

  static gapPixelsAt3x = 5;
  static cornerRadius = 2.5;
  /** Direction-latched layer switch thresholds, as log-fractions between adjacent rest sides. */
  static upFraction = [0.118, 0.423];
  static downFraction = [0.931, 0.893];
  static fadeBase = 1.0;
  static fadeGain = 0.9;
  static rubberC = 0.467;
  static rubberDepth = 0.0566;
  static maxSideFactor = 1.2214;
  static springOmega = 12;
  static releaseProjection = 0.08;

  get gap(): number { return Math.max(1, Math.round((GridConfig.gapPixelsAt3x * this.scale) / 3)) / this.scale; }
  get levels(): number { return this.columns.length; }

  side(level: number): number {
    const n = this.columns[level];
    // (at least a point: a view not laid out yet has no width, and zooming divides by this)
    return Math.max(Math.floor(((this.width - this.gap * (n - 1)) / n) * this.scale) / this.scale, 1);
  }
  pitch(level: number): number { return this.side(level) + this.gap; }
  /** Side above which zooming in latches level+1. */
  up(level: number): number { return this.side(level) * Math.pow(this.side(level + 1) / this.side(level), GridConfig.upFraction[level]); }
  /** Side below which zooming out latches `level` again (coming from level+1). */
  down(level: number): number { return this.side(level) * Math.pow(this.side(level + 1) / this.side(level), GridConfig.downFraction[level]); }
  get minSide(): number { return this.side(0); }
  get maxSide(): number { return this.side(this.levels - 1) * GridConfig.maxSideFactor; }

  rows(level: number, phase: number): number { const n = this.columns[level]; return Math.floor((this.count + phase + n - 1) / n); }
  contentHeight(level: number, phase: number): number { return this.count === 0 ? 0 : this.rows(level, phase) * this.pitch(level) - this.gap; }
  maxOffset(level: number, phase: number): number { return Math.max(0, this.contentHeight(level, phase) + this.insetTop + this.insetBottom - this.height); }
  cell(index: number, level: number, phase: number): { col: number; row: number } {
    const n = this.columns[level];
    const k = index + phase;
    return { col: k % n, row: Math.floor(k / n) };
  }

  /** Displayed side for a raw (finger-driven) side: rubber band below, hard stop above. */
  displaySide(lnRaw: number): number {
    const raw = Math.exp(lnRaw);
    if (raw < this.minSide) {
      const u = Math.log(this.minSide / raw);
      const d = GridConfig.rubberDepth;
      return this.minSide * Math.exp(-d * (1 - 1 / ((GridConfig.rubberC * u) / d + 1)));
    }
    return Math.min(raw, this.maxSide);
  }

  equals(o: GridConfig): boolean {
    return this.width === o.width && this.height === o.height && this.insetTop === o.insetTop && this.insetBottom === o.insetBottom && this.scale === o.scale;
  }
}

interface Zoom {
  anchor: number;
  rel: { x: number; y: number };
  cols: number[];
  anchors: number[];
  phases: number[];
  finger: { x: number; y: number };
  fingerOffset: { x: number; y: number };
  lnBase: number;
  lnRaw: number;
  lnVel: number;
  level: number;
  target: number;
  pinching: boolean;
  prevLnRaw: number;
  prevLnSide: number;
  sideRate: number;
  lastTime: number;
}

/** The pinch-zoom state machine reverse-engineered from Photos (FINDINGS.md §2–§7). One lattice
 *  of cells anchored at the photo under the fingers; every column count is a layer that only
 *  decides which photo sits in which cell; layers cross-fade over each other. Times in seconds. */
export class ZoomEngine {
  cfg: GridConfig;
  rest: RestState;
  zoom: Zoom | null = null;
  private _items: number[] = [];
  hiddenPhoto: number | null = null;

  constructor(cfg: GridConfig, rest: RestState) {
    this.cfg = cfg;
    this.rest = rest;
    this.items = Array.from({ length: cfg.count }, (_, i) => i);
  }

  get items(): number[] { return this._items; }
  set items(v: number[]) { this._items = v; this.cfg.count = v.length; }
  get isZooming(): boolean { return this.zoom != null; }

  beginPinch(finger: { x: number; y: number }, time: number): void {
    const z0 = this.zoom;
    if (z0) {
      z0.fingerOffset = { x: z0.finger.x - finger.x, y: z0.finger.y - finger.y };
      z0.lnBase = z0.lnRaw;
      z0.lnVel = 0;
      z0.pinching = true;
      z0.lastTime = time;
      return;
    }
    const cfg = this.cfg, lv = this.rest.level;
    const n = cfg.columns[lv];
    const side = cfg.side(lv), pitch = cfg.pitch(lv);
    const cy = finger.y - cfg.insetTop + this.rest.offset;
    const col = Math.min(Math.max(Math.floor(finger.x / pitch), 0), n - 1);
    const row = Math.max(0, Math.floor(cy / pitch));
    const index = Math.min(Math.max(row * n + col - this.rest.phase, 0), Math.max(cfg.count - 1, 0));
    const c = cfg.cell(index, lv, this.rest.phase);
    const rel = { x: (finger.x - c.col * pitch) / side, y: (cy - c.row * pitch) / side };
    const cols = new Array(cfg.levels).fill(0), phases = new Array(cfg.levels).fill(0), anchors = new Array(cfg.levels).fill(index);
    for (let l = 0; l < cfg.levels; l++) {
      if (l === lv) continue;
      const r = this.chooseColumn(l, index, rel, finger);
      cols[l] = r.col; phases[l] = r.phase; anchors[l] = r.photo;
    }
    cols[lv] = c.col; phases[lv] = this.rest.phase;
    const ln0 = Math.log(side);
    this.zoom = {
      anchor: index, rel, cols, anchors, phases, finger, fingerOffset: { x: 0, y: 0 },
      lnBase: ln0, lnRaw: ln0, lnVel: 0, level: lv, target: lv, pinching: true,
      prevLnRaw: ln0, prevLnSide: ln0, sideRate: 0, lastTime: time,
    };
  }

  pinchChanged(scale: number, finger: { x: number; y: number }): void {
    const z = this.zoom;
    if (!z || !z.pinching) return;
    z.finger = { x: finger.x + z.fingerOffset.x, y: finger.y + z.fingerOffset.y };
    z.lnRaw = z.lnBase + Math.log(Math.max(scale, 1e-3));
  }

  /** `velocity` is the scale velocity (scale/s). */
  release(velocity: number, scale: number): void {
    const z = this.zoom;
    if (!z) return;
    const v = clampf(velocity / Math.max(scale, 1e-3), -8, 8);
    const projected = this.cfg.displaySide(z.lnRaw + v * GridConfig.releaseProjection);
    z.target = this.latch(z.target, projected, v);
    z.pinching = false;
    z.lnVel = v;
  }

  /** Advances the zoom. Returns the new resting state when the zoom has finished. */
  tick(time: number): RestState | null {
    const z = this.zoom;
    if (!z) return null;
    const cfg = this.cfg;
    const dt = Math.min(Math.max(time - z.lastTime, 0), 1 / 30);
    z.lastTime = time;
    if (!z.pinching) {
      const goal = Math.log(cfg.side(z.target));
      const w = GridConfig.springOmega;
      let t = dt;
      while (t > 1e-6) {
        const h = Math.min(t, 1 / 480);
        const a = -w * w * (z.lnRaw - goal) - 2 * w * z.lnVel;
        z.lnVel += a * h;
        z.lnRaw += z.lnVel * h;
        t -= h;
      }
    }
    const s = cfg.displaySide(z.lnRaw);
    const lnS = Math.log(s);
    if (dt > 0) {
      const inst = Math.abs(lnS - z.prevLnSide) / dt;
      z.sideRate += (inst - z.sideRate) * Math.min(1, dt * 30);
    }
    if (z.pinching) z.target = this.latch(z.target, s, z.lnRaw - z.prevLnRaw);
    z.prevLnRaw = z.lnRaw;
    z.prevLnSide = lnS;
    const rate = GridConfig.fadeBase + GridConfig.fadeGain * z.sideRate;
    const diff = z.target - z.level;
    z.level += (diff > 0 ? 1 : -1) * Math.min(Math.abs(diff), rate * dt);
    const remaining = Math.abs(z.lnRaw - Math.log(cfg.side(z.target))) * cfg.side(z.target);
    if (!z.pinching && remaining < 0.33 / cfg.scale && Math.abs(z.lnVel) < 0.02 && Math.abs(z.level - z.target) < 0.02) return this.finish();
    return null;
  }

  /** Jumps a settling zoom to its end state (the user started scrolling mid-settle). */
  finishNow(): RestState | null {
    const z = this.zoom;
    if (!z || z.pinching) return null;
    z.lnRaw = Math.log(this.cfg.side(z.target));
    z.lnVel = 0;
    z.level = z.target;
    return this.finish();
  }

  private latch(target: number, s: number, direction: number): number {
    let t = target;
    if (direction > 0) { while (t < this.cfg.levels - 1 && s > this.cfg.up(t)) t++; }
    else if (direction < 0) { while (t > 0 && s < this.cfg.down(t - 1)) t--; }
    return t;
  }

  private finish(): RestState | null {
    const z = this.zoom;
    if (!z) return null;
    const cfg = this.cfg, l = z.target;
    const r = this.restAnchorPoint(l, z);
    const n = cfg.columns[l];
    const row = Math.floor((z.anchors[l] + z.phases[l]) / n);
    const contentY = row * cfg.pitch(l) + z.rel.y * cfg.side(l);
    const offset = clampf(cfg.insetTop + contentY - r.y, 0, cfg.maxOffset(l, z.phases[l]));
    this.rest = { level: l, phase: z.phases[l], offset };
    this.zoom = null;
    return this.rest;
  }

  /** Anchor cell of a layer, as Photos does it (experiments J and TOP). */
  private chooseColumn(l: number, anchor: number, rel: { x: number; y: number }, finger: { x: number; y: number }): { col: number; phase: number; photo: number } {
    const cfg = this.cfg, n = cfg.columns[l];
    const side = cfg.side(l), pitch = cfg.pitch(l);
    const col = Math.min(Math.max(Math.round((finger.x - rel.x * side) / pitch), 0), n - 1);
    const phase = posmod(col - anchor, n);
    const row = Math.floor((anchor + phase) / n);
    const o = clampf(cfg.insetTop + row * pitch + rel.y * side - finger.y, 0, cfg.maxOffset(l, phase));
    if (o < cfg.insetTop + side) {
      const photo = Math.min(Math.floor(anchor / n) * n + col, Math.max(cfg.count - 1, 0));
      return { col: photo % n, phase: 0, photo };
    }
    return { col, phase, photo: anchor };
  }

  /** Where the anchor point would be on screen if the grid came to rest in layer `l`. */
  private restAnchorPoint(l: number, z: Zoom): { x: number; y: number } {
    const cfg = this.cfg, n = cfg.columns[l];
    const side = cfg.side(l), pitch = cfg.pitch(l);
    const row = Math.floor((z.anchors[l] + z.phases[l]) / n);
    const x = z.cols[l] * pitch + z.rel.x * side;
    const contentY = row * pitch + z.rel.y * side;
    const o = clampf(cfg.insetTop + contentY - z.finger.y, 0, cfg.maxOffset(l, z.phases[l]));
    return { x, y: cfg.insetTop + contentY - o };
  }

  /** Anchor position: linear in side between the resting positions of the bracketing layers. */
  private anchorPoint(s: number, z: Zoom): { x: number; y: number } {
    const cfg = this.cfg;
    if (s <= cfg.side(0)) return this.restAnchorPoint(0, z);
    for (let l = 0; l < cfg.levels - 1; l++) {
      if (s <= cfg.side(l + 1)) {
        const a = this.restAnchorPoint(l, z), b = this.restAnchorPoint(l + 1, z);
        const t = (s - cfg.side(l)) / (cfg.side(l + 1) - cfg.side(l));
        return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
      }
    }
    return this.restAnchorPoint(cfg.levels - 1, z);
  }

  info(): { side: number; level: number; target: number; columns: number } {
    const z = this.zoom, cfg = this.cfg;
    if (z) return { side: cfg.displaySide(z.lnRaw), level: z.level, target: z.target, columns: cfg.columns[Math.round(z.level)] };
    return { side: cfg.side(this.rest.level), level: this.rest.level, target: this.rest.level, columns: cfg.columns[this.rest.level] };
  }

  /** Tiles for the current zoom frame, back to front. */
  zoomTiles(out: Tile[]): void {
    const z = this.zoom;
    if (!z) return;
    const cfg = this.cfg;
    const s = cfg.displaySide(z.lnRaw);
    const p = s + cfg.gap;
    const anchorPt = this.anchorPoint(s, z);
    const ax = anchorPt.x - z.rel.x * s, ay = anchorPt.y - z.rel.y * s;
    const alpha = new Array(cfg.levels).fill(1);
    for (let j = 1; j < cfg.levels; j++) {
      const v = clampf(z.level - (j - 1), 0, 1);
      alpha[j] = v * v;
    }
    const drMin = Math.floor(-ay / p), drMax = Math.floor((cfg.height - ay) / p);
    const dcScreenMin = Math.floor(-ax / p), dcScreenMax = Math.floor((cfg.width - ax) / p);
    for (let l = 0; l < cfg.levels; l++) {
      if (l > 0 && alpha[l] <= 0.001) continue;
      const n = cfg.columns[l];
      const c = z.cols[l];
      const opaqueAbove: number[] = [];
      for (let m = l + 1; m < cfg.levels; m++) if (alpha[m] >= 0.999) opaqueAbove.push(m);
      const lo = Math.max(-c, dcScreenMin), hi = Math.min(n - 1 - c, dcScreenMax);
      if (lo > hi) continue;
      for (let dr = drMin; dr <= drMax; dr++) {
        for (let dc = lo; dc <= hi; dc++) {
          let covered = false;
          for (const m of opaqueAbove) {
            const cm = z.cols[m], nm = cfg.columns[m];
            const im = z.anchors[m] + dr * nm + dc;
            if (dc >= -cm && dc <= nm - 1 - cm && im >= 0 && im < cfg.count) { covered = true; break; }
          }
          if (covered) continue;
          const idx = z.anchors[l] + dr * n + dc;
          if (idx < 0 || idx >= cfg.count) continue;
          const x = ax + dc * p, y = ay + dr * p;
          if (this._items[idx] === this.hiddenPhoto) continue;
          out.push({ x, y, side: s, alpha: alpha[l], index: idx, photo: this._items[idx], radii: this.radii(x, s, dc === -c, dc === n - 1 - c) });
        }
      }
    }
  }

  /** Tiles of a resting layout. */
  restTiles(r: RestState, out: Tile[], alpha = 1): void {
    const cfg = this.cfg, l = r.level, n = cfg.columns[l];
    const s = cfg.side(l), p = cfg.pitch(l);
    const rowMin = Math.max(0, Math.floor((r.offset - cfg.insetTop) / p));
    const rowMax = Math.floor((r.offset - cfg.insetTop + cfg.height) / p);
    if (rowMin > rowMax) return;
    for (let row = rowMin; row <= rowMax; row++) {
      for (let col = 0; col < n; col++) {
        const idx = row * n + col - r.phase;
        if (idx < 0 || idx >= cfg.count) continue;
        const x = col * p, y = cfg.insetTop + row * p - r.offset;
        if (this._items[idx] === this.hiddenPhoto) continue;
        out.push({ x, y, side: s, alpha, index: idx, photo: this._items[idx], radii: this.radii(x, s, col === 0, col === n - 1) });
      }
    }
  }

  /** Screen frame of a photo in a resting layout. */
  restFrame(index: number, r: RestState): { x: number; y: number; w: number; h: number } {
    const c = this.cfg.cell(index, r.level, r.phase);
    const p = this.cfg.pitch(r.level), s = this.cfg.side(r.level);
    return { x: c.col * p, y: this.cfg.insetTop + c.row * p - r.offset, w: s, h: s };
  }

  /** Index of the photo whose tile contains a screen point in the resting layout. */
  restIndex(pt: { x: number; y: number }): number | null {
    const cfg = this.cfg, l = this.rest.level, n = cfg.columns[l], p = cfg.pitch(l), side = cfg.side(l);
    const cy = pt.y - cfg.insetTop + this.rest.offset;
    if (pt.x < 0 || cy < 0) return null;
    const col = Math.floor(pt.x / p), row = Math.floor(cy / p);
    if (col >= n || pt.x - col * p > side || cy - row * p > side) return null;
    const i = row * n + col - this.rest.phase;
    return i >= 0 && i < cfg.count ? i : null;
  }

  /** Inner corners are rounded; a layer's outer corners square off as they reach the screen edge. */
  radii(x: number, side: number, leftEdge: boolean, rightEdge: boolean): [number, number, number, number] {
    const r = GridConfig.cornerRadius;
    const l = leftEdge ? r * clampf(x / r, 0, 1) : r;
    const rr = rightEdge ? r * clampf((this.cfg.width - x - side) / r, 0, 1) : r;
    return [l, rr, rr, l];
  }
}

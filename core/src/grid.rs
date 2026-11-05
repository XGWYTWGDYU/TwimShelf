//! The photo grid's pinch zoom, shared by every front end: one lattice of cells anchored at the
//! photo under the fingers, a layer per column count that cross-fades over the others, a
//! direction-latched choice of the final layer, and a critically damped settle. A line-for-line
//! port of the Swift `GridConfig` / `ZoomEngine` (native/Shared/Grid), whose constants were measured
//! from the Photos app; `core/tests/grid_engine.rs` replays recorded gestures against both.
//!
//! The engine only does geometry: front ends feed it pinch events and frame times and draw the
//! tiles it lists (screen points, back to front), each naming its index in the item list.

/// Geometry of the grid and the measured constants.
#[derive(Clone, Debug, PartialEq)]
pub struct GridConfig {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pub inset_top: f64,
    pub inset_bottom: f64,
    pub count: usize,
    /// Column counts the zoom settles on, densest first; a level is a position here.
    pub columns: Vec<usize>,
}

pub const GAP_PIXELS_AT_3X: f64 = 5.0;
pub const CORNER_RADIUS: f64 = 2.5;
/// Direction-latched layer switch thresholds, as log-fractions between adjacent rest sides.
pub const UP_FRACTION: [f64; 2] = [0.118, 0.423];
pub const DOWN_FRACTION: [f64; 2] = [0.931, 0.893];
/// Cross-fade progress rate: base + gain·|d ln(side)/dt| per second; layer alpha = progress².
pub const FADE_BASE: f64 = 1.0;
pub const FADE_GAIN: f64 = 0.9;
/// Rubber band below the densest side (log space).
pub const RUBBER_C: f64 = 0.467;
pub const RUBBER_DEPTH: f64 = 0.0566;
/// Hard limit above the sparsest side.
pub const MAX_SIDE_FACTOR: f64 = 1.2214;
/// Critically damped settle spring on ln(raw side).
pub const SPRING_OMEGA: f64 = 12.0;
/// How far a release velocity is projected when deciding the final layer.
pub const RELEASE_PROJECTION: f64 = 0.08;

fn clampf(v: f64, lo: f64, hi: f64) -> f64 { v.max(lo).min(hi) }
fn posmod(a: i64, n: i64) -> i64 { ((a % n) + n) % n }

impl GridConfig {
    pub fn new(width: f64, height: f64, scale: f64, inset_top: f64, inset_bottom: f64, count: usize) -> Self {
        GridConfig { width, height, scale, inset_top, inset_bottom, count, columns: Self::columns_for_width(width) }
    }

    /// 5 / 3 / 1 up to a large phone, then as many columns as keep the tiles about as big as
    /// the phone's (80 / 134 / 402 pt).
    pub fn columns_for_width(w: f64) -> Vec<usize> {
        if w <= 500.0 { return vec![5, 3, 1]; }
        let one = ((w / 402.0).round() as usize).max(1);
        let three = ((w / 134.0).round() as usize).max(one + 1);
        let five = ((w / 80.4).round() as usize).max(three + 1);
        vec![five, three, one]
    }

    pub fn gap(&self) -> f64 { (GAP_PIXELS_AT_3X * self.scale / 3.0).round().max(1.0) / self.scale }
    pub fn levels(&self) -> usize { self.columns.len() }

    pub fn side(&self, level: usize) -> f64 {
        let n = self.columns[level] as f64;
        ((self.width - self.gap() * (n - 1.0)) / n * self.scale).floor() / self.scale
    }
    pub fn pitch(&self, level: usize) -> f64 { self.side(level) + self.gap() }

    /// Side above which zooming in latches level+1.
    pub fn up(&self, level: usize) -> f64 {
        self.side(level) * (self.side(level + 1) / self.side(level)).powf(UP_FRACTION[level.min(1)])
    }
    /// Side below which zooming out latches `level` again (coming from level+1).
    pub fn down(&self, level: usize) -> f64 {
        self.side(level) * (self.side(level + 1) / self.side(level)).powf(DOWN_FRACTION[level.min(1)])
    }
    pub fn min_side(&self) -> f64 { self.side(0) }
    pub fn max_side(&self) -> f64 { self.side(self.levels() - 1) * MAX_SIDE_FACTOR }

    pub fn rows(&self, level: usize, phase: usize) -> usize {
        let n = self.columns[level];
        (self.count + phase + n - 1) / n
    }
    pub fn content_height(&self, level: usize, phase: usize) -> f64 {
        if self.count == 0 { 0.0 } else { self.rows(level, phase) as f64 * self.pitch(level) - self.gap() }
    }
    pub fn max_offset(&self, level: usize, phase: usize) -> f64 {
        (self.content_height(level, phase) + self.inset_top + self.inset_bottom - self.height).max(0.0)
    }
    /// Phase that makes the last row full.
    pub fn bottom_phase(&self, level: usize) -> usize {
        let n = self.columns[level];
        (n - self.count % n) % n
    }
    pub fn cell(&self, index: usize, level: usize, phase: usize) -> (usize, usize) {
        let n = self.columns[level];
        let k = index + phase;
        (k % n, k / n)
    }

    /// Displayed side for a raw (finger-driven) side: rubber band below, hard stop above.
    pub fn display_side(&self, ln_raw: f64) -> f64 {
        let raw = ln_raw.exp();
        let min = self.min_side();
        if raw < min {
            let u = (min / raw).ln();
            let d = RUBBER_DEPTH;
            return min * (-d * (1.0 - 1.0 / (RUBBER_C * u / d + 1.0))).exp();
        }
        raw.min(self.max_side())
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RestState {
    pub level: usize,
    pub phase: usize,
    /// Scroll offset: content y shown at the top inset line.
    pub offset: f64,
}

/// One drawn tile, in screen points.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub struct Tile {
    pub x: f64,
    pub y: f64,
    pub side: f64,
    pub alpha: f64,
    /// Position in the item list.
    pub index: usize,
    /// Corner radii: top-left, top-right, bottom-right, bottom-left.
    pub radii: [f64; 4],
}

#[derive(Clone, Debug)]
struct Zoom {
    rel: (f64, f64),
    cols: Vec<usize>,
    anchors: Vec<usize>,
    phases: Vec<usize>,
    finger: (f64, f64),
    finger_offset: (f64, f64),
    ln_base: f64,
    ln_raw: f64,
    ln_vel: f64,
    level: f64,
    target: usize,
    pinching: bool,
    prev_ln_raw: f64,
    prev_ln_side: f64,
    side_rate: f64,
    last_time: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub struct FrameInfo {
    pub side: f64,
    pub level: f64,
    pub target: usize,
    pub columns: usize,
}

/// The pinch-zoom state machine.
#[derive(Clone, Debug)]
pub struct ZoomEngine {
    pub cfg: GridConfig,
    pub rest: RestState,
    zoom: Option<Zoom>,
    /// An item not drawn (lifted out by a context menu).
    pub hidden: Option<usize>,
}

impl ZoomEngine {
    pub fn new(cfg: GridConfig, rest: RestState) -> Self { ZoomEngine { cfg, rest, zoom: None, hidden: None } }
    pub fn is_zooming(&self) -> bool { self.zoom.is_some() }

    /// A resting grid never shows empty places in its first row: a phase a zoom left (to keep the
    /// fingers' point still) is dropped once the first row is within `rows` rows of the screen —
    /// 1 when a zoom has just ended, 3 while scrolling (as the native `GridScene`). The offset is
    /// clamped to the new content. True when the layout changed.
    pub fn realign_near_top(&mut self, rows: f64) -> bool {
        if self.zoom.is_some() || self.rest.phase == 0 { return false; }
        let l = self.rest.level;
        if self.rest.offset >= self.cfg.inset_top + rows * self.cfg.pitch(l) { return false; }
        self.rest.phase = 0;
        self.rest.offset = clampf(self.rest.offset, 0.0, self.cfg.max_offset(l, 0));
        true
    }

    // ---------- gesture ----------

    pub fn begin_pinch(&mut self, finger: (f64, f64), time: f64) {
        if let Some(z) = self.zoom.as_mut() {
            // a pinch during the settle continues from the current state; the picture stays still
            z.finger_offset = (z.finger.0 - finger.0, z.finger.1 - finger.1);
            z.ln_base = z.ln_raw;
            z.ln_vel = 0.0;
            z.pinching = true;
            z.last_time = time;
            return;
        }
        let cfg = &self.cfg;
        let lv = self.rest.level;
        let n = cfg.columns[lv];
        let (side, pitch) = (cfg.side(lv), cfg.pitch(lv));
        let cy = finger.1 - cfg.inset_top + self.rest.offset;
        let col = ((finger.0 / pitch).floor() as i64).clamp(0, n as i64 - 1);
        let row = ((cy / pitch).floor() as i64).max(0);
        let index = (row * n as i64 + col - self.rest.phase as i64).clamp(0, (cfg.count as i64 - 1).max(0)) as usize;
        let (ccol, crow) = cfg.cell(index, lv, self.rest.phase);
        let rel = ((finger.0 - ccol as f64 * pitch) / side, (cy - crow as f64 * pitch) / side);
        let levels = cfg.levels();
        let mut cols = vec![0; levels];
        let mut phases = vec![0; levels];
        let mut anchors = vec![index; levels];
        for l in 0..levels {
            if l == lv { continue; }
            let (c, p, a) = self.choose_column(l, index, rel, finger);
            cols[l] = c; phases[l] = p; anchors[l] = a;
        }
        cols[lv] = ccol;
        phases[lv] = self.rest.phase;
        let ln0 = side.ln();
        self.zoom = Some(Zoom {
            rel, cols, anchors, phases, finger, finger_offset: (0.0, 0.0),
            ln_base: ln0, ln_raw: ln0, ln_vel: 0.0, level: lv as f64, target: lv, pinching: true,
            prev_ln_raw: ln0, prev_ln_side: ln0, side_rate: 0.0, last_time: time,
        });
    }

    pub fn pinch_changed(&mut self, scale: f64, finger: (f64, f64)) {
        if let Some(z) = self.zoom.as_mut() {
            if !z.pinching { return; }
            z.finger = (finger.0 + z.finger_offset.0, finger.1 + z.finger_offset.1);
            z.ln_raw = z.ln_base + scale.max(1e-3).ln();
        }
    }

    /// `velocity` is the recognizer's scale velocity (scale/s).
    pub fn release(&mut self, velocity: f64, scale: f64) {
        let Some(mut z) = self.zoom.take() else { return };
        let v = clampf(velocity / scale.max(1e-3), -8.0, 8.0);
        // a fling carries the latch one step further, by the same directional rule
        let projected = self.cfg.display_side(z.ln_raw + v * RELEASE_PROJECTION);
        z.target = self.latch(z.target, projected, v);
        z.pinching = false;
        z.ln_vel = v;
        self.zoom = Some(z);
    }

    // ---------- per frame ----------

    /// Advances the zoom; returns the resting state when it has finished.
    pub fn tick(&mut self, time: f64) -> Option<RestState> {
        let mut z = self.zoom.take()?;
        let dt = (time - z.last_time).clamp(0.0, 1.0 / 30.0);
        z.last_time = time;
        if !z.pinching {
            let goal = self.cfg.side(z.target).ln();
            let w = SPRING_OMEGA;
            let mut t = dt;
            while t > 1e-6 {
                let h = t.min(1.0 / 480.0);
                let a = -w * w * (z.ln_raw - goal) - 2.0 * w * z.ln_vel;
                z.ln_vel += a * h;
                z.ln_raw += z.ln_vel * h;
                t -= h;
            }
        }
        let s = self.cfg.display_side(z.ln_raw);
        let ln_s = s.ln();
        if dt > 0.0 {
            let inst = (ln_s - z.prev_ln_side).abs() / dt;
            z.side_rate += (inst - z.side_rate) * (dt * 30.0).min(1.0);
        }
        if z.pinching {
            z.target = self.latch(z.target, s, z.ln_raw - z.prev_ln_raw);
        }
        z.prev_ln_raw = z.ln_raw;
        z.prev_ln_side = ln_s;
        // cross-fade progress: time plus gesture motion, toward the latched layer
        let rate = FADE_BASE + FADE_GAIN * z.side_rate;
        let diff = z.target as f64 - z.level;
        z.level += if diff > 0.0 { 1.0 } else { -1.0 } * diff.abs().min(rate * dt);
        let target_side = self.cfg.side(z.target);
        let remaining = (z.ln_raw - target_side.ln()).abs() * target_side;
        let done = !z.pinching && remaining < 0.33 / self.cfg.scale && z.ln_vel.abs() < 0.02 && (z.level - z.target as f64).abs() < 0.02;
        self.zoom = Some(z);
        if done { self.finish() } else { None }
    }

    /// Jumps a settling zoom to its end (the user started scrolling mid-settle).
    pub fn finish_now(&mut self) -> Option<RestState> {
        let z = self.zoom.as_mut()?;
        if z.pinching { return None; }
        z.ln_raw = self.cfg.side(z.target).ln();
        z.ln_vel = 0.0;
        z.level = z.target as f64;
        self.finish()
    }

    fn latch(&self, target: usize, s: f64, direction: f64) -> usize {
        let mut t = target;
        if direction > 0.0 {
            while t < self.cfg.levels() - 1 && s > self.cfg.up(t) { t += 1; }
        } else if direction < 0.0 {
            while t > 0 && s < self.cfg.down(t - 1) { t -= 1; }
        }
        t
    }

    fn finish(&mut self) -> Option<RestState> {
        let z = self.zoom.take()?;
        let l = z.target;
        let r = self.rest_anchor_point(l, &z);
        let n = self.cfg.columns[l];
        let row = (z.anchors[l] + z.phases[l]) / n;
        let content_y = row as f64 * self.cfg.pitch(l) + z.rel.1 * self.cfg.side(l);
        let offset = clampf(self.cfg.inset_top + content_y - r.1, 0.0, self.cfg.max_offset(l, z.phases[l]));
        self.rest = RestState { level: l, phase: z.phases[l], offset };
        Some(self.rest)
    }

    // ---------- anchor geometry ----------

    /// The column whose resting x is nearest the finger, holding the anchor photo; if the first
    /// row would be on screen there, the layer is top-aligned instead (its first row full) and the
    /// anchor cell holds the photo that sits there, on the anchor's row.
    fn choose_column(&self, l: usize, anchor: usize, rel: (f64, f64), finger: (f64, f64)) -> (usize, usize, usize) {
        let cfg = &self.cfg;
        let n = cfg.columns[l];
        let (side, pitch) = (cfg.side(l), cfg.pitch(l));
        let col = (((finger.0 - rel.0 * side) / pitch).round() as i64).clamp(0, n as i64 - 1) as usize;
        let phase = posmod(col as i64 - anchor as i64, n as i64) as usize;
        let row = (anchor + phase) / n;
        let o = clampf(cfg.inset_top + row as f64 * pitch + rel.1 * side - finger.1, 0.0, cfg.max_offset(l, phase));
        if o < cfg.inset_top + side {
            let photo = ((anchor / n) * n + col).min(cfg.count.saturating_sub(1));
            return (photo % n, 0, photo);
        }
        (col, phase, anchor)
    }

    /// Where the anchor point would be on screen if the grid came to rest in layer `l`.
    fn rest_anchor_point(&self, l: usize, z: &Zoom) -> (f64, f64) {
        let cfg = &self.cfg;
        let n = cfg.columns[l];
        let (side, pitch) = (cfg.side(l), cfg.pitch(l));
        let row = (z.anchors[l] + z.phases[l]) / n;
        let x = z.cols[l] as f64 * pitch + z.rel.0 * side;
        let content_y = row as f64 * pitch + z.rel.1 * side;
        let o = clampf(cfg.inset_top + content_y - z.finger.1, 0.0, cfg.max_offset(l, z.phases[l]));
        (x, cfg.inset_top + content_y - o)
    }

    /// Anchor position: linear in side between the resting positions of the bracketing layers.
    fn anchor_point(&self, s: f64, z: &Zoom) -> (f64, f64) {
        let cfg = &self.cfg;
        if s <= cfg.side(0) { return self.rest_anchor_point(0, z); }
        for l in 0..cfg.levels() - 1 {
            if s <= cfg.side(l + 1) {
                let a = self.rest_anchor_point(l, z);
                let b = self.rest_anchor_point(l + 1, z);
                let t = (s - cfg.side(l)) / (cfg.side(l + 1) - cfg.side(l));
                return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
            }
        }
        self.rest_anchor_point(cfg.levels() - 1, z)
    }

    // ---------- frame ----------

    pub fn info(&self) -> FrameInfo {
        match &self.zoom {
            Some(z) => FrameInfo { side: self.cfg.display_side(z.ln_raw), level: z.level, target: z.target, columns: self.cfg.columns[z.level.round() as usize] },
            None => FrameInfo { side: self.cfg.side(self.rest.level), level: self.rest.level as f64, target: self.rest.level, columns: self.cfg.columns[self.rest.level] },
        }
    }

    /// Tiles of the current frame, back to front: the zoom's layers while zooming, else the
    /// resting layout.
    pub fn tiles(&self, out: &mut Vec<Tile>) {
        if self.zoom.is_some() { self.zoom_tiles(out) } else { self.rest_tiles(self.rest, out, 1.0) }
    }

    pub fn zoom_tiles(&self, out: &mut Vec<Tile>) {
        let Some(z) = &self.zoom else { return };
        let cfg = &self.cfg;
        let s = cfg.display_side(z.ln_raw);
        let p = s + cfg.gap();
        let a = self.anchor_point(s, z);
        let (ax, ay) = (a.0 - z.rel.0 * s, a.1 - z.rel.1 * s);
        let levels = cfg.levels();
        let mut alpha = vec![1.0; levels];
        for (j, al) in alpha.iter_mut().enumerate().skip(1) {
            let v = clampf(z.level - (j as f64 - 1.0), 0.0, 1.0);
            *al = v * v;
        }
        let dr_min = (-ay / p).floor() as i64;
        let dr_max = ((cfg.height - ay) / p).floor() as i64;
        let dc_screen_min = (-ax / p).floor() as i64;
        let dc_screen_max = ((cfg.width - ax) / p).floor() as i64;
        for l in 0..levels {
            if l > 0 && alpha[l] <= 0.001 { continue; }
            let n = cfg.columns[l] as i64;
            let c = z.cols[l] as i64;
            // cells covered by an opaque sparser layer above need not be drawn
            let opaque_above: Vec<usize> = ((l + 1)..levels).filter(|&m| alpha[m] >= 0.999).collect();
            let lo = (-c).max(dc_screen_min);
            let hi = (n - 1 - c).min(dc_screen_max);
            if lo > hi { continue; }
            for dr in dr_min..=dr_max {
                for dc in lo..=hi {
                    let covered = opaque_above.iter().any(|&m| {
                        let cm = z.cols[m] as i64;
                        let nm = cfg.columns[m] as i64;
                        let im = z.anchors[m] as i64 + dr * nm + dc;
                        dc >= -cm && dc <= nm - 1 - cm && im >= 0 && im < cfg.count as i64
                    });
                    if covered { continue; }
                    let idx = z.anchors[l] as i64 + dr * n + dc;
                    if idx < 0 || idx >= cfg.count as i64 { continue; }
                    let idx = idx as usize;
                    if self.hidden == Some(idx) { continue; }
                    let x = ax + dc as f64 * p;
                    let y = ay + dr as f64 * p;
                    out.push(Tile { x, y, side: s, alpha: alpha[l], index: idx, radii: self.radii(x, s, dc == -c, dc == n - 1 - c) });
                }
            }
        }
    }

    /// Tiles of a resting layout.
    pub fn rest_tiles(&self, r: RestState, out: &mut Vec<Tile>, alpha: f64) {
        let cfg = &self.cfg;
        let l = r.level;
        let n = cfg.columns[l];
        let (s, p) = (cfg.side(l), cfg.pitch(l));
        let row_min = (((r.offset - cfg.inset_top) / p).floor() as i64).max(0);
        let row_max = ((r.offset - cfg.inset_top + cfg.height) / p).floor() as i64;
        if row_min > row_max { return; }
        for row in row_min..=row_max {
            for col in 0..n {
                let idx = row * n as i64 + col as i64 - r.phase as i64;
                if idx < 0 || idx >= cfg.count as i64 { continue; }
                let idx = idx as usize;
                if self.hidden == Some(idx) { continue; }
                let x = col as f64 * p;
                let y = cfg.inset_top + row as f64 * p - r.offset;
                out.push(Tile { x, y, side: s, alpha, index: idx, radii: self.radii(x, s, col == 0, col == n - 1) });
            }
        }
    }

    /// Screen frame (x, y, side) of an item in a resting layout.
    pub fn rest_frame(&self, index: usize, r: RestState) -> (f64, f64, f64) {
        let (c, row) = self.cfg.cell(index, r.level, r.phase);
        let (p, s) = (self.cfg.pitch(r.level), self.cfg.side(r.level));
        (c as f64 * p, self.cfg.inset_top + row as f64 * p - r.offset, s)
    }

    /// The item whose tile contains a screen point in the resting layout.
    pub fn rest_index(&self, pt: (f64, f64)) -> Option<usize> {
        let cfg = &self.cfg;
        let l = self.rest.level;
        let (n, p, side) = (cfg.columns[l], cfg.pitch(l), cfg.side(l));
        let cy = pt.1 - cfg.inset_top + self.rest.offset;
        if pt.0 < 0.0 || cy < 0.0 { return None; }
        let (col, row) = ((pt.0 / p) as usize, (cy / p) as usize);
        if col >= n || pt.0 - col as f64 * p > side || cy - row as f64 * p > side { return None; }
        let i = (row * n + col) as i64 - self.rest.phase as i64;
        (i >= 0 && (i as usize) < cfg.count).then_some(i as usize)
    }

    /// Inner corners are rounded; a layer's outer corners square off as they reach the screen edge.
    pub fn radii(&self, x: f64, side: f64, left_edge: bool, right_edge: bool) -> [f64; 4] {
        let r = CORNER_RADIUS;
        let l = if left_edge { r * clampf(x / r, 0.0, 1.0) } else { r };
        let rr = if right_edge { r * clampf((self.cfg.width - x - side) / r, 0.0, 1.0) } else { r };
        [l, rr, rr, l]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(count: usize) -> ZoomEngine {
        let cfg = GridConfig::new(390.0, 844.0, 3.0, 47.0, 34.0, count);
        let rest = RestState { level: 1, phase: cfg.bottom_phase(1), offset: 0.0 };
        ZoomEngine::new(cfg, rest)
    }

    /// Pinches with a scale curve, releases, and runs frames until the engine rests.
    fn pinch(e: &mut ZoomEngine, finger: (f64, f64), to: f64, release_velocity: f64) -> RestState {
        let mut t = 0.0;
        e.begin_pinch(finger, t);
        for i in 1..=30 {
            t += 1.0 / 120.0;
            e.pinch_changed(1.0 + (to - 1.0) * i as f64 / 30.0, finger);
            assert!(e.tick(t).is_none());
        }
        e.release(release_velocity, to);
        for _ in 0..2000 {
            t += 1.0 / 120.0;
            if let Some(r) = e.tick(t) { return r; }
        }
        panic!("the zoom never came to rest");
    }

    #[test]
    fn a_phase_left_by_a_zoom_is_dropped_near_the_top_only() {
        let mut e = engine(1000);
        e.rest = RestState { level: 1, phase: 2, offset: 0.0 };
        assert!(e.realign_near_top(1.0));
        assert_eq!(e.rest.phase, 0);
        // far from the top the phase stays (dropping it would move what is on screen)
        let pitch = e.cfg.pitch(1);
        e.rest = RestState { level: 1, phase: 2, offset: 10.0 * pitch };
        assert!(!e.realign_near_top(3.0));
        assert_eq!(e.rest.phase, 2);
        // scrolling up to within three rows drops it
        e.rest.offset = 2.0 * pitch;
        assert!(e.realign_near_top(3.0));
        assert_eq!(e.rest.phase, 0);
        assert!(e.rest.offset <= e.cfg.max_offset(1, 0));
    }

    #[test]
    fn levels_and_sides_match_the_phone() {
        let e = engine(1000);
        assert_eq!(e.cfg.columns, vec![5, 3, 1]);
        assert!((e.cfg.gap() - 5.0 / 3.0).abs() < 1e-9);
        assert!(e.cfg.side(0) < e.cfg.side(1) && e.cfg.side(1) < e.cfg.side(2));
        assert_eq!(GridConfig::columns_for_width(1200.0), vec![15, 9, 3]);
    }

    #[test]
    fn spreading_fingers_goes_one_level_sparser_and_keeps_the_photo_under_them() {
        let mut e = engine(1000);
        let finger = (200.0, 400.0);
        let before = e.rest_index(finger).unwrap();
        let r = pinch(&mut e, finger, 1.8, 0.0);
        assert_eq!(r.level, 2);
        // the photo under the fingers is still under them (the finger may be near its edge)
        let (x, y, s) = e.rest_frame(before, r);
        assert!(finger.0 >= x - 1.0 && finger.0 <= x + s + 1.0 && finger.1 >= y - 1.0 && finger.1 <= y + s + 1.0, "{before} moved");
    }

    #[test]
    fn pinching_in_goes_denser_and_a_small_pinch_springs_back() {
        let mut e = engine(1000);
        let r = pinch(&mut e, (100.0, 300.0), 0.6, 0.0);
        assert_eq!(r.level, 0);
        let mut e = engine(1000);
        let r = pinch(&mut e, (100.0, 300.0), 1.05, 0.0);
        assert_eq!(r.level, 1, "a small spread does not latch the next level");
    }

    #[test]
    fn a_fling_carries_one_level_further() {
        let mut e = engine(1000);
        let r = pinch(&mut e, (100.0, 300.0), 1.1, 6.0);
        assert_eq!(r.level, 2);
    }

    #[test]
    fn tiles_cover_the_screen_without_overlap_at_rest_and_stay_on_screen_while_zooming() {
        let mut e = engine(5000);
        e.rest.offset = 3000.0;
        let mut tiles = vec![];
        e.tiles(&mut tiles);
        let mut seen = std::collections::HashSet::new();
        for t in &tiles { assert!(seen.insert(t.index), "drawn twice: {}", t.index); }
        assert!(tiles.len() >= 3 * ((844.0 / e.cfg.pitch(1)) as usize));
        e.begin_pinch((195.0, 420.0), 0.0);
        e.pinch_changed(1.4, (195.0, 420.0));
        e.tick(1.0 / 120.0);
        tiles.clear();
        e.tiles(&mut tiles);
        assert!(!tiles.is_empty());
        for t in &tiles {
            assert!(t.x + t.side > -1.0 && t.x < 391.0 && t.y + t.side > -1.0 && t.y < 845.0);
            assert!(t.alpha >= 0.0 && t.alpha <= 1.0);
        }
    }

    #[test]
    fn the_rubber_band_never_goes_below_its_depth() {
        let e = engine(10);
        let min = e.cfg.min_side();
        for k in 1..50 {
            let s = e.cfg.display_side((min * 0.9f64.powi(k)).ln());
            assert!(s <= min && s >= min * (-RUBBER_DEPTH).exp() - 1e-9);
        }
        assert!((e.cfg.display_side((e.cfg.max_side() * 3.0).ln()) - e.cfg.max_side()).abs() < 1e-9);
    }

    #[test]
    fn a_hundred_thousand_items_cost_only_the_visible_tiles() {
        let mut e = engine(100_000);
        e.rest.offset = 1_000_000.0f64.min(e.cfg.max_offset(1, e.rest.phase));
        let mut tiles = vec![];
        e.tiles(&mut tiles);
        assert!(tiles.len() < 100, "{} tiles", tiles.len());
        let mut z = e.clone();
        z.begin_pinch((195.0, 420.0), 0.0);
        z.pinch_changed(0.7, (195.0, 420.0));
        z.tick(0.01);
        tiles.clear();
        z.tiles(&mut tiles);
        assert!(tiles.len() < 400, "{} tiles while zooming", tiles.len());
    }
}

//! The shared grid engine against recordings of the Photos app: the same fixtures and limits as
//! the Swift replay tests (native/GridTests), so the Rust port is held to what the native grid was
//! measured against. Every recorded frame is replayed by its displayed side; every recorded tile
//! must be where the engine draws that photo.
use std::collections::HashMap;
use tl_core::grid::{GridConfig, RestState, Tile, ZoomEngine, RUBBER_C, RUBBER_DEPTH};

#[derive(serde::Deserialize)]
struct Start { level: usize, phase: usize, offset: f64 }
#[derive(serde::Deserialize)]
struct Frame { t: f64, s: f64, tiles: Vec<Vec<f64>> }
#[derive(serde::Deserialize)]
struct Fixture { items: Vec<usize>, finger: Vec<f64>, start: Start, frames: Vec<Frame> }

fn photos_config(count: usize) -> GridConfig {
    let mut c = GridConfig::new(402.0, 874.0, 3.0, 136.0, 93.0, count);
    c.columns = vec![5, 3, 1];
    c
}

/// ln(raw side) whose displayed side is `s` (inverse of the rubber band).
fn ln_raw(s: f64, cfg: &GridConfig) -> f64 {
    let m = cfg.min_side();
    if s >= m { return s.ln(); }
    let q = (-(s / m).ln() / RUBBER_DEPTH).min(0.999);
    m.ln() - RUBBER_DEPTH / RUBBER_C * (1.0 / (1.0 - q) - 1.0)
}

#[derive(Default)]
struct Report { errors: Vec<f64>, unmatched: usize, gestures: usize }

fn is_blend(o: &[f64], tiles: &[Tile]) -> bool {
    let here: Vec<&Tile> = tiles.iter().filter(|t| (t.x - o[1]).abs() < 3.0 && (t.y - o[2]).abs() < 3.0).collect();
    here.len() >= 2 && here.iter().any(|t| t.alpha > 0.005 && t.alpha < 0.995)
}

fn compare(fr: &Frame, tiles: &[Tile], items: &[usize], r: &mut Report) {
    let mut by_photo: HashMap<usize, Vec<&Tile>> = HashMap::new();
    for t in tiles.iter().filter(|t| t.alpha > 0.02) { by_photo.entry(items[t.index]).or_default().push(t); }
    for o in &fr.tiles {
        let Some(c) = by_photo.get(&(o[0] as usize)) else { r.unmatched += 1; continue };
        let e = c.iter().map(|t| (t.x - o[1]).hypot(t.y - o[2])).fold(f64::MAX, f64::min);
        if e > 10.0 && is_blend(o, tiles) { r.unmatched += 1; continue; }
        r.errors.push(e);
    }
}

fn replay(f: &Fixture) -> Report {
    let cfg = photos_config(f.items.len());
    let mut e = ZoomEngine::new(cfg.clone(), RestState { level: f.start.level, phase: f.start.phase, offset: f.start.offset });
    let finger = (f.finger[0], f.finger[1]);
    let mut r = Report::default();
    let mut tiles = vec![];
    let mut rest_since: Option<f64> = None;
    let mut side0 = cfg.side(f.start.level);
    let is_rest_side = |s: f64| (0..cfg.levels()).any(|l| (cfg.side(l) - s).abs() < 0.4);
    for fr in &f.frames {
        if e.is_zooming() {
            if is_rest_side(fr.s) { rest_since.get_or_insert(fr.t); } else { rest_since = None; }
            let info = e.info();
            if let Some(r0) = rest_since {
                if fr.t - r0 >= 0.35 && (info.level - info.target as f64).abs() < 0.02 && (fr.s - cfg.side(info.target)).abs() < 0.4 {
                    e.release(0.0, 1.0);
                    e.finish_now();
                    rest_since = None;
                }
            }
        }
        if !e.is_zooming() {
            if (fr.s - cfg.side(e.rest.level)).abs() < 0.4 {
                tiles.clear();
                e.rest_tiles(e.rest, &mut tiles, 1.0);
                compare(fr, &tiles, &f.items, &mut r);
                continue;
            }
            e.begin_pinch(finger, fr.t);
            side0 = cfg.side(e.rest.level);
            r.gestures += 1;
        }
        e.pinch_changed((ln_raw(fr.s, &cfg) - side0.ln()).exp(), finger);
        e.tick(fr.t);
        tiles.clear();
        e.zoom_tiles(&mut tiles);
        compare(fr, &tiles, &f.items, &mut r);
    }
    r
}

fn percentile(e: &[f64], p: f64) -> f64 {
    let mut s = e.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    s[((s.len() - 1) as f64 * p) as usize]
}

#[test]
fn every_photos_recording_replays_within_the_native_limits() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/GridTests/Fixtures");
    let mut names: Vec<_> = std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
    names.sort();
    assert_eq!(names.len(), 9);
    for p in names {
        let f: Fixture = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
        let r = replay(&f);
        let name = p.file_stem().unwrap().to_string_lossy().into_owned();
        let (med, p95, p99) = (percentile(&r.errors, 0.5), percentile(&r.errors, 0.95), percentile(&r.errors, 0.99));
        let unmatched = r.unmatched as f64 / (r.unmatched + r.errors.len()).max(1) as f64;
        let gross = r.errors.iter().filter(|&&e| e > 10.0).count() as f64 / r.errors.len() as f64;
        println!("{name}: {} gestures, {} tiles, median {med:.2} p95 {p95:.2} p99 {p99:.2}, unmatched {:.1}%, gross {:.2}%", r.gestures, r.errors.len(), unmatched * 100.0, gross * 100.0);
        assert!(r.errors.len() > 200, "{name}: too few tiles");
        assert!(med <= 0.6 && p95 <= 2.0 && p99 <= 3.0, "{name}: median {med} p95 {p95} p99 {p99}");
        assert!(unmatched <= 0.03 && gross <= 0.002, "{name}: unmatched {unmatched} gross {gross}");
    }
}

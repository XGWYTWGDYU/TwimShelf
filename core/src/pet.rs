//! The little Clawd of the mascot mode: where it is, what it does and how it looks, shared by every
//! app. It answers each frame with plain rectangles (it is pixel art, drawn from code); a front end
//! paints them and passes on the pointer and the taps.
//!
//! Sits at home in the bottom-right corner. Its eyes follow the pointer; a pointer shaken about
//! makes it dizzy, eyes going round; afterwards it may walk to the pointer, do something there
//! (glare, stare, be pleased), walk home and maybe sleep. A tap always gets a reaction.

/// Points per pixel of the sprite, and the sprite's size in pixels.
pub const UNIT: f64 = 3.0;
pub const SPRITE_W: f64 = 15.0;
pub const SPRITE_H: f64 = 9.0;

const BODY: u32 = 0xFFDE886D;
const DARK: u32 = 0xFF141414;
const HEART: u32 = 0xFFE5484D;
const ANGER: u32 = 0xFFD92D20;
const MARK: u32 = 0xFF6E6E73;

const WALK_SPEED: f64 = 150.0;
/// Direction changes of the pointer within SHAKE_WINDOW seconds that make it dizzy.
const SHAKE_TURNS: usize = 6;
const SHAKE_WINDOW: f64 = 1.6;
/// A stretch of movement shorter than this is not a turn (a hand resting on the mouse).
const SHAKE_MIN_RUN: f64 = 30.0;
const DIZZY_SECONDS: f64 = 2.6;
const SHAKE_COOLDOWN: f64 = 4.0;
/// How likely it is to go after the pointer once the dizziness has passed.
const CHASE_CHANCE: f64 = 0.5;
const ACT_SECONDS: f64 = 3.0;
const IDLE_BEFORE_SLEEP: f64 = 45.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Act { Glare, Stare, Pleased }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reaction { Hop, Wave, Startle, Spin, Annoyed }

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Idle,
    Dizzy { left: f64 },
    ToPointer,
    Acting { act: Act, left: f64 },
    Home,
    Stretch { left: f64 },
    Sleep { left: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PetRect { pub x: f64, pub y: f64, pub w: f64, pub h: f64, pub color: u32 }

#[derive(Clone, Copy)]
enum Mote { Heart, Zed, Anger, Question, Bang }
#[derive(Clone, Copy)]
struct Particle { x: f64, y: f64, age: f64, life: f64, kind: Mote }

#[derive(Clone, Copy, PartialEq)]
enum Eyes { Open, Blink, Closed, Round, Wide, Happy, Cross }

pub struct Pet {
    width: f64, height: f64, margin_right: f64, margin_bottom: f64,
    x: f64, y: f64,
    /// Where the walk is going, and which way it faces (-1 left, 1 right).
    target: (f64, f64), facing: f64,
    pub state: State,
    pub reaction: Option<(Reaction, f64)>,
    pointer: Option<(f64, f64)>,
    gaze: (f64, f64),
    clock: f64, walk_phase: f64, idle_for: f64, next_blink: f64, blink_left: f64,
    run_from: Option<(f64, f64)>, run_dir: (f64, f64), turns: Vec<f64>, cooldown_until: f64,
    taps: Vec<f64>,
    particles: Vec<Particle>, mote_timer: f64,
    rng: u64,
    /// Overrides the chance of chasing (tests).
    pub chase_chance: f64,
}

impl Pet {
    pub fn new(seed: u64) -> Self {
        Pet {
            width: 0.0, height: 0.0, margin_right: 0.0, margin_bottom: 0.0, x: 0.0, y: 0.0, target: (0.0, 0.0), facing: 1.0,
            state: State::Idle, reaction: None, pointer: None, gaze: (0.0, 0.0),
            clock: 0.0, walk_phase: 0.0, idle_for: 0.0, next_blink: 2.5, blink_left: 0.0,
            run_from: None, run_dir: (0.0, 0.0), turns: vec![], cooldown_until: 0.0, taps: vec![],
            particles: vec![], mote_timer: 0.0, rng: seed | 1, chase_chance: CHASE_CHANCE,
        }
    }

    fn random(&mut self) -> f64 {
        // xorshift: looks only, and a fixed seed makes a run repeatable in the tests
        self.rng ^= self.rng << 13; self.rng ^= self.rng >> 7; self.rng ^= self.rng << 17;
        (self.rng % 1_000_000) as f64 / 1_000_000.0
    }

    pub fn sprite_size() -> (f64, f64) { (SPRITE_W * UNIT, SPRITE_H * UNIT) }
    fn home(&self) -> (f64, f64) {
        let (w, h) = Self::sprite_size();
        ((self.width - w - self.margin_right).max(0.0), (self.height - h - self.margin_bottom).max(0.0))
    }
    fn at_home(&self) -> bool { matches!(self.state, State::Idle | State::Stretch { .. } | State::Sleep { .. }) }

    /// The view's size and how far from its corner home is.
    pub fn set_bounds(&mut self, width: f64, height: f64, margin_right: f64, margin_bottom: f64) {
        let first = self.width == 0.0;
        (self.width, self.height, self.margin_right, self.margin_bottom) = (width, height, margin_right, margin_bottom);
        let home = self.home();
        if first || self.at_home() { (self.x, self.y) = home; }
        let (w, h) = Self::sprite_size();
        self.x = self.x.clamp(0.0, (width - w).max(0.0));
        self.y = self.y.clamp(0.0, (height - h).max(0.0));
    }

    /// The pointer moved, inside a window in the foreground.
    pub fn pointer_moved(&mut self, x: f64, y: f64) {
        self.note_shake(x, y);
        self.pointer = Some((x, y));
    }

    /// The pointer left, or the window went to the background: it looks straight ahead again.
    pub fn pointer_gone(&mut self) {
        self.pointer = None;
        self.run_from = None;
        self.turns.clear();
    }

    fn note_shake(&mut self, x: f64, y: f64) {
        let Some(from) = self.run_from else { self.run_from = Some((x, y)); return };
        let (dx, dy) = (x - from.0, y - from.1);
        let len = (dx * dx + dy * dy).sqrt();
        if len < SHAKE_MIN_RUN { return; }
        let dir = (dx / len, dy / len);
        if dir.0 * self.run_dir.0 + dir.1 * self.run_dir.1 < -0.2 { self.turns.push(self.clock); }
        self.run_dir = dir;
        self.run_from = Some((x, y));
        let now = self.clock;
        self.turns.retain(|t| now - t <= SHAKE_WINDOW);
        if self.turns.len() >= SHAKE_TURNS && now >= self.cooldown_until && !matches!(self.state, State::Dizzy { .. } | State::Sleep { .. }) {
            self.state = State::Dizzy { left: DIZZY_SECONDS };
            self.turns.clear();
            self.reaction = None;
        }
    }

    pub fn frame(&self) -> (f64, f64, f64, f64) { let (w, h) = Self::sprite_size(); (self.x, self.y, w, h) }
    /// Whether a point is on it (a little generously: it is small).
    pub fn hit(&self, x: f64, y: f64) -> bool {
        let (fx, fy, w, h) = self.frame();
        x >= fx - 6.0 && x <= fx + w + 6.0 && y >= fy - 6.0 && y <= fy + h + 6.0
    }

    /// A tap on it. False when the tap missed.
    pub fn tap(&mut self, x: f64, y: f64) -> bool {
        if !self.hit(x, y) { return false; }
        let now = self.clock;
        self.taps.retain(|t| now - t < 2.0);
        self.taps.push(now);
        self.idle_for = 0.0;
        let (cx, cy, ..) = self.frame();
        let top = (cx + SPRITE_W * UNIT / 2.0, cy - 2.0);
        let woken = matches!(self.state, State::Sleep { .. });
        if woken { self.state = State::Idle; }
        let kind = if woken { Reaction::Startle }
            else if self.taps.len() >= 5 { self.taps.clear(); Reaction::Annoyed }
            else { match (self.random() * 3.0) as u32 { 0 => Reaction::Hop, 1 => Reaction::Wave, _ => Reaction::Spin } };
        self.reaction = Some((kind, 0.0));
        match kind {
            Reaction::Hop | Reaction::Wave => self.spawn(Mote::Heart, top, 1.0),
            Reaction::Startle => self.spawn(Mote::Bang, top, 0.9),
            Reaction::Annoyed => self.spawn(Mote::Anger, top, 1.0),
            Reaction::Spin => {}
        }
        true
    }

    fn spawn(&mut self, kind: Mote, at: (f64, f64), life: f64) { self.particles.push(Particle { x: at.0, y: at.1, age: 0.0, life, kind }); }

    fn reaction_length(r: Reaction) -> f64 {
        match r { Reaction::Hop => 0.55, Reaction::Wave => 1.1, Reaction::Startle => 0.6, Reaction::Spin => 0.7, Reaction::Annoyed => 1.2 }
    }

    /// Advances by `dt` seconds.
    pub fn tick(&mut self, dt: f64) {
        let dt = dt.clamp(0.0, 0.1);
        self.clock += dt;
        self.update_gaze(dt);
        self.update_blink(dt);
        for p in &mut self.particles { p.age += dt; p.y -= 14.0 * dt; }
        self.particles.retain(|p| p.age < p.life);
        if let Some((r, t)) = self.reaction {
            let t = t + dt;
            // a reaction holds everything else for its moment
            self.reaction = (t < Self::reaction_length(r)).then_some((r, t));
            return;
        }
        self.step_state(dt);
    }

    fn step_state(&mut self, dt: f64) {
        match self.state {
            State::Idle => {
                self.idle_for += dt;
                if self.idle_for > IDLE_BEFORE_SLEEP { self.state = State::Sleep { left: 15.0 + self.random() * 15.0 }; }
            }
            State::Dizzy { left } => {
                let left = left - dt;
                if left > 0.0 { self.state = State::Dizzy { left }; return; }
                self.cooldown_until = self.clock + SHAKE_COOLDOWN;
                self.idle_for = 0.0;
                let chase = self.random() < self.chase_chance;
                self.state = match (chase, self.pointer) {
                    (true, Some(_)) => State::ToPointer,
                    _ => self.back_home_state(),
                };
            }
            State::ToPointer => {
                let Some(p) = self.pointer else { self.state = State::Home; return };
                // beside the pointer, on the side it came from, inside the window
                let (w, h) = Self::sprite_size();
                let side = if self.x + w / 2.0 < p.0 { -1.0 } else { 1.0 };
                let tx = (p.0 + side * (w / 2.0 + 14.0) - w / 2.0).clamp(0.0, (self.width - w).max(0.0));
                let ty = (p.1 - h / 2.0).clamp(0.0, (self.height - h).max(0.0));
                self.target = (tx, ty);
                if self.walk(dt) {
                    let act = match (self.random() * 3.0) as u32 { 0 => Act::Glare, 1 => Act::Stare, _ => Act::Pleased };
                    let (cx, cy, ..) = self.frame();
                    let top = (cx + w / 2.0, cy - 2.0);
                    match act { Act::Glare => self.spawn(Mote::Anger, top, ACT_SECONDS), Act::Stare => self.spawn(Mote::Question, top, ACT_SECONDS), Act::Pleased => {} }
                    self.state = State::Acting { act, left: ACT_SECONDS };
                }
            }
            State::Acting { act, left } => {
                let left = left - dt;
                if act == Act::Pleased {
                    self.mote_timer -= dt;
                    if self.mote_timer <= 0.0 {
                        self.mote_timer = 0.7;
                        let (cx, cy, w, _) = self.frame();
                        self.spawn(Mote::Heart, (cx + w / 2.0, cy - 2.0), 1.0);
                    }
                }
                self.state = if left > 0.0 { State::Acting { act, left } } else { State::Home };
            }
            State::Home => {
                self.target = self.home();
                if self.walk(dt) {
                    self.idle_for = 0.0;
                    self.state = self.back_home_state();
                }
            }
            State::Stretch { left } => {
                let left = left - dt;
                self.state = if left > 0.0 { State::Stretch { left } } else { State::Idle };
            }
            State::Sleep { left } => {
                let left = left - dt;
                self.mote_timer -= dt;
                if self.mote_timer <= 0.0 {
                    self.mote_timer = 1.3;
                    let (cx, cy, w, _) = self.frame();
                    self.spawn(Mote::Zed, (cx + w - 6.0, cy - 2.0), 2.2);
                }
                if left > 0.0 { self.state = State::Sleep { left }; } else { self.idle_for = 0.0; self.state = State::Stretch { left: 1.4 }; }
            }
        }
    }

    /// At home: what it does on arriving. Away: walk back first.
    fn back_home_state(&mut self) -> State {
        let home = self.home();
        if (self.x - home.0).abs() > 1.0 || (self.y - home.1).abs() > 1.0 { return State::Home; }
        if self.random() < 0.6 { State::Sleep { left: 10.0 + self.random() * 12.0 } } else { State::Stretch { left: 1.4 } }
    }

    /// A step towards the target; true on arrival.
    fn walk(&mut self, dt: f64) -> bool {
        let (dx, dy) = (self.target.0 - self.x, self.target.1 - self.y);
        let d = (dx * dx + dy * dy).sqrt();
        if dx.abs() > 1.0 { self.facing = dx.signum(); }
        let step = WALK_SPEED * dt;
        if d <= step.max(0.5) { (self.x, self.y) = self.target; return true; }
        self.x += dx / d * step;
        self.y += dy / d * step;
        self.walk_phase += dt * 9.0;
        false
    }

    fn update_gaze(&mut self, dt: f64) {
        let want = if matches!(self.state, State::ToPointer | State::Home) { (self.facing, 0.0) }
            else if let Some(p) = self.pointer {
                let (fx, fy, w, h) = self.frame();
                let (dx, dy) = (p.0 - (fx + w / 2.0), p.1 - (fy + h * 0.35));
                let d = (dx * dx + dy * dy).sqrt().max(1.0);
                // close to it the eyes come back towards the middle, as they would
                let near = (d / 40.0).min(1.0);
                (dx / d * near, dy / d * near)
            } else { (0.0, 0.0) };
        let k = (dt * 14.0).min(1.0);
        self.gaze.0 += (want.0 - self.gaze.0) * k;
        self.gaze.1 += (want.1 - self.gaze.1) * k;
    }

    fn update_blink(&mut self, dt: f64) {
        self.blink_left = (self.blink_left - dt).max(0.0);
        self.next_blink -= dt;
        if self.next_blink <= 0.0 {
            self.blink_left = 0.12;
            self.next_blink = 2.0 + self.random() * 4.0;
        }
    }

    /// The picture of this moment, back to front, in view coordinates.
    pub fn draw(&self, out: &mut Vec<PetRect>) {
        out.clear();
        let t = self.clock;
        let (mut ox, mut oy, mut sx) = (0.0, 0.0, 1.0_f64);
        let (mut left_hand, mut right_hand, mut legs, mut breath) = (0.0, 0.0, 0.0, 0.0);
        let mut eyes = if self.blink_left > 0.0 { Eyes::Blink } else { Eyes::Open };
        let mut brows = false;
        match self.state {
            State::Idle => {}
            State::Dizzy { .. } => { eyes = Eyes::Round; ox = (t * 7.0).sin() * 3.0; oy = (t * 14.0).sin().abs() * -1.0; }
            State::ToPointer | State::Home => { legs = self.walk_phase; oy = -(self.walk_phase * 2.0).sin().abs() * 1.5; }
            State::Acting { act: Act::Glare, .. } => { brows = true; ox = (t * 40.0).sin() * 1.2; left_hand = 1.0; right_hand = 1.0; }
            State::Acting { act: Act::Stare, .. } => { eyes = Eyes::Wide; oy = (t * 2.0).sin() * 1.0; }
            State::Acting { act: Act::Pleased, .. } => { eyes = Eyes::Happy; oy = -(t * 8.0).sin().abs() * 3.0; right_hand = (t * 8.0).sin().abs(); left_hand = right_hand; }
            State::Stretch { left } => { let up = (1.0 - (left / 1.4 - 0.5).abs() * 2.0).clamp(0.0, 1.0); left_hand = up * 2.0; right_hand = up * 2.0; eyes = Eyes::Closed; breath = -up; }
            State::Sleep { .. } => { eyes = Eyes::Closed; breath = ((t * 1.6).sin() + 1.0) / 2.0; }
        }
        if let Some((r, p)) = self.reaction {
            let q = (p / Self::reaction_length(r)).clamp(0.0, 1.0);
            match r {
                Reaction::Hop => { oy = -(q * std::f64::consts::PI).sin() * 16.0; eyes = Eyes::Happy; left_hand = 1.0; right_hand = 1.0; }
                Reaction::Wave => { right_hand = 1.0 + (p * 16.0).sin(); eyes = Eyes::Happy; }
                Reaction::Startle => { oy = -(q * std::f64::consts::PI).sin() * 12.0; eyes = Eyes::Wide; left_hand = 2.0; right_hand = 2.0; }
                Reaction::Spin => { sx = (q * std::f64::consts::TAU).cos(); oy = -(q * std::f64::consts::PI).sin() * 6.0; eyes = Eyes::Open; }
                Reaction::Annoyed => { eyes = Eyes::Cross; ox = (p * 45.0).sin() * 1.6; }
            }
        }
        let u = UNIT;
        let (bx, by) = (self.x + ox, self.y + oy);
        let centre = SPRITE_W / 2.0;
        // a pixel of the sprite to view coordinates (a turn narrows it about its middle)
        let px = |out: &mut Vec<PetRect>, gx: f64, gy: f64, gw: f64, gh: f64, color: u32| {
            let (a, b) = (centre + (gx - centre) * sx, centre + (gx + gw - centre) * sx);
            let (l, r) = (a.min(b), a.max(b));
            if r - l > 0.01 { out.push(PetRect { x: bx + l * u, y: by + gy * u, w: (r - l) * u, h: gh * u, color }); }
        };
        // feet stay on the ground line; in a walk they take turns
        for (i, fx) in [3.0, 5.0, 9.0, 11.0].iter().enumerate() {
            let lift = if legs != 0.0 { (((legs + i as f64 * std::f64::consts::PI).sin()) * 0.7).max(0.0) } else { 0.0 };
            px(out, *fx, 7.0, 1.0, 2.0 - lift, BODY);
        }
        px(out, 0.0, 3.0 - left_hand, 2.0, 2.0, BODY);
        px(out, 13.0, 3.0 - right_hand, 2.0, 2.0, BODY);
        px(out, 2.0, breath * 0.6, 11.0, 7.0 - breath * 0.6, BODY);
        let (gx, gy) = (self.gaze.0 * 0.8, self.gaze.1 * 0.6);
        match eyes {
            Eyes::Open => { px(out, 4.0 + gx, 2.0 + gy, 1.0, 2.0, DARK); px(out, 10.0 + gx, 2.0 + gy, 1.0, 2.0, DARK); }
            Eyes::Blink | Eyes::Closed => { px(out, 3.5, 3.0 + breath * 0.3, 2.0, 1.0, DARK); px(out, 9.5, 3.0 + breath * 0.3, 2.0, 1.0, DARK); }
            Eyes::Wide => { px(out, 3.5 + gx, 1.5 + gy, 2.0, 2.5, DARK); px(out, 9.5 + gx, 1.5 + gy, 2.0, 2.5, DARK); }
            Eyes::Round => {
                // a ring of dots going round with a gap in it, the two eyes in opposite directions
                for (cx, dir) in [(4.5, 1.0), (10.5, -1.0)] {
                    for k in 0..7 {
                        let a = t * 7.0 * dir + k as f64 * std::f64::consts::TAU / 8.0;
                        px(out, cx + a.cos() * 1.45 - 0.35, 3.0 + a.sin() * 1.45 - 0.35, 0.7, 0.7, DARK);
                    }
                    px(out, cx - 0.3, 2.7, 0.6, 0.6, DARK);
                }
            }
            Eyes::Happy => {
                for cx in [4.5, 10.5] {
                    px(out, cx - 1.5, 3.0, 1.0, 1.0, DARK); px(out, cx - 0.5, 2.0, 1.0, 1.0, DARK); px(out, cx + 0.5, 3.0, 1.0, 1.0, DARK);
                }
            }
            Eyes::Cross => {
                for cx in [4.5, 10.5] {
                    px(out, cx - 1.0, 2.0, 0.7, 0.7, DARK); px(out, cx + 0.3, 2.0, 0.7, 0.7, DARK);
                    px(out, cx - 0.35, 2.7, 0.7, 0.7, DARK);
                    px(out, cx - 1.0, 3.4, 0.7, 0.7, DARK); px(out, cx + 0.3, 3.4, 0.7, 0.7, DARK);
                }
            }
        }
        if brows {
            for (x, step) in [(3.0, 0.5), (12.0, -0.5)] {
                for k in 0..3 { let k = k as f64; px(out, x + step * 2.0 * k * 0.7, 0.2 + k * 0.35, 1.0, 0.6, DARK); }
            }
        }
        for p in &self.particles { Self::draw_mote(out, p); }
    }

    fn draw_mote(out: &mut Vec<PetRect>, p: &Particle) {
        let fade = (((p.life - p.age) / 0.3).min(1.0) * 255.0) as u32;
        let shade = |c: u32| (fade << 24) | (c & 0x00FF_FFFF);
        let (rows, color): (&[&str], u32) = match p.kind {
            Mote::Heart => (&[".X.X.", "XXXXX", "XXXXX", ".XXX.", "..X.."], HEART),
            Mote::Zed => (&["XXXX", "..X.", ".X..", "XXXX"], MARK),
            Mote::Anger => (&["X.X.X", ".X.X.", "X...X", ".X.X.", "X.X.X"], ANGER),
            Mote::Question => (&[".XX.", "X..X", "..X.", ".X..", "....", ".X.."], MARK),
            Mote::Bang => (&["X", "X", "X", ".", "X"], ANGER),
        };
        let size = 2.0;
        let w = rows[0].len() as f64 * size;
        for (j, row) in rows.iter().enumerate() {
            for (i, c) in row.bytes().enumerate() {
                if c == b'X' {
                    out.push(PetRect { x: p.x - w / 2.0 + i as f64 * size, y: p.y - (rows.len() - j) as f64 * size, w: size, h: size, color: shade(color) });
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pet() -> Pet { let mut p = Pet::new(42); p.set_bounds(1000.0, 800.0, 16.0, 16.0); p }
    fn run(p: &mut Pet, seconds: f64) { for _ in 0..(seconds * 60.0) as usize { p.tick(1.0 / 60.0); } }
    fn shake(p: &mut Pet) {
        for i in 0..40 {
            p.pointer_moved(if i % 2 == 0 { 300.0 } else { 500.0 }, 300.0);
            p.tick(0.02);
        }
    }
    fn dark(p: &Pet) -> Vec<PetRect> { let mut v = vec![]; p.draw(&mut v); v.into_iter().filter(|r| r.color == DARK).collect() }

    /// Writes the poses for looking at them: PET_DUMP=<file> cargo test --lib pet::tests::dump -- --ignored
    #[test]
    #[ignore]
    fn dump() {
        let mut out = String::new();
        let mut shot = |name: &str, p: &Pet| {
            let mut v = vec![];
            p.draw(&mut v);
            let (x, y, ..) = p.frame();
            out += &format!("#{name}\n");
            for r in v { out += &format!("{} {} {} {} {}\n", r.x - x, r.y - y, r.w, r.h, r.color); }
        };
        let mut p = pet();
        p.next_blink = 1000.0;
        run(&mut p, 0.2); shot("idle", &p);
        p.pointer_moved(100.0, 100.0); run(&mut p, 0.5); shot("look left-up", &p);
        p.pointer_moved(990.0, 790.0); run(&mut p, 0.5); shot("look down-right", &p);
        p.pointer_gone(); shake(&mut p); run(&mut p, 0.13); shot("dizzy 1", &p); run(&mut p, 0.2); shot("dizzy 2", &p);
        p.state = State::ToPointer; p.pointer_moved(100.0, 100.0); run(&mut p, 0.3); shot("walk", &p);
        for (name, act) in [("glare", Act::Glare), ("stare", Act::Stare), ("pleased", Act::Pleased)] { p.particles.clear(); p.state = State::Acting { act, left: 3.0 }; run(&mut p, 0.4); shot(name, &p); }
        p.state = State::Sleep { left: 10.0 }; p.particles.clear(); p.mote_timer = 0.0; run(&mut p, 1.0); shot("sleep", &p);
        p.state = State::Stretch { left: 0.7 }; p.pointer_gone(); shot("stretch", &p);
        p.state = State::Idle; p.particles.clear();
        for (name, r, t) in [("hop", Reaction::Hop, 0.27), ("wave", Reaction::Wave, 0.1), ("startle", Reaction::Startle, 0.3), ("spin", Reaction::Spin, 0.1), ("annoyed", Reaction::Annoyed, 0.3)] {
            p.reaction = Some((r, t)); shot(name, &p);
        }
        std::fs::write(std::env::var("PET_DUMP").unwrap(), out).unwrap();
    }

    #[test]
    fn starts_at_home_in_the_corner() {
        let p = pet();
        let (x, y, w, h) = p.frame();
        assert_eq!((x + w, y + h), (984.0, 784.0));
    }

    #[test]
    fn eyes_follow_the_pointer() {
        let mut p = pet();
        p.blink_left = 0.0; p.next_blink = 100.0;
        run(&mut p, 0.5);
        let centred = dark(&p)[0].x;
        p.pointer_moved(10.0, 400.0);
        run(&mut p, 0.5);
        assert!(dark(&p)[0].x < centred, "looks left");
        p.pointer_moved(990.0, 400.0);
        run(&mut p, 0.5);
        assert!(dark(&p)[0].x > centred - 0.01);
        p.pointer_gone();
        run(&mut p, 1.0);
        assert!((dark(&p)[0].x - centred).abs() < 0.1, "straight ahead again");
    }

    #[test]
    fn slow_movement_does_not_make_it_dizzy_but_shaking_does() {
        let mut p = pet();
        for i in 0..60 { p.pointer_moved(100.0 + i as f64 * 10.0, 200.0); p.tick(0.05); }
        assert_eq!(p.state, State::Idle);
        shake(&mut p);
        assert!(matches!(p.state, State::Dizzy { .. }));
        assert!(dark(&p).len() >= 8, "both eyes go round");
    }

    #[test]
    fn after_dizziness_it_walks_to_the_pointer_acts_and_goes_home() {
        let mut p = pet();
        p.chase_chance = 1.0;
        shake(&mut p);
        p.pointer_moved(200.0, 200.0);
        run(&mut p, DIZZY_SECONDS + 0.1);
        assert_eq!(p.state, State::ToPointer);
        let mut seen = false;
        for _ in 0..60 * 20 {
            p.tick(1.0 / 60.0);
            if let State::Acting { .. } = p.state {
                let (x, y, w, h) = p.frame();
                assert!((x + w / 2.0 - 200.0).abs() < w, "beside the pointer");
                assert!((y + h / 2.0 - 200.0).abs() < h);
                seen = true;
                break;
            }
        }
        assert!(seen, "reached the pointer");
        run(&mut p, ACT_SECONDS + 0.1);
        assert_eq!(p.state, State::Home);
        run(&mut p, 15.0);
        let (x, y, w, h) = p.frame();
        assert_eq!((x + w, y + h), (984.0, 784.0), "back home");
        assert!(matches!(p.state, State::Sleep { .. } | State::Stretch { .. } | State::Idle));
    }

    #[test]
    fn never_chases_a_pointer_that_left() {
        let mut p = pet();
        p.chase_chance = 1.0;
        shake(&mut p);
        p.pointer_gone();
        run(&mut p, DIZZY_SECONDS + 0.5);
        assert_ne!(p.state, State::ToPointer);
    }

    #[test]
    fn taps_only_count_on_it_and_always_get_a_reaction() {
        let mut p = pet();
        assert!(!p.tap(10.0, 10.0));
        assert!(p.reaction.is_none());
        let (x, y, ..) = p.frame();
        assert!(p.tap(x + 5.0, y + 5.0));
        assert!(p.reaction.is_some());
        run(&mut p, 3.0);
        assert!(p.reaction.is_none());
        for _ in 0..5 { p.tap(x + 5.0, y + 5.0); }
        assert_eq!(p.reaction.map(|r| r.0), Some(Reaction::Annoyed), "five quick taps");
    }

    #[test]
    fn a_tap_wakes_it() {
        let mut p = pet();
        p.state = State::Sleep { left: 20.0 };
        let (x, y, ..) = p.frame();
        p.tap(x + 5.0, y + 5.0);
        assert_eq!(p.state, State::Idle);
        assert_eq!(p.reaction.map(|r| r.0), Some(Reaction::Startle));
    }

    #[test]
    fn falls_asleep_when_left_alone_and_wakes_by_itself() {
        let mut p = pet();
        run(&mut p, IDLE_BEFORE_SLEEP + 0.5);
        assert!(matches!(p.state, State::Sleep { .. }));
        run(&mut p, 32.0);
        assert!(!matches!(p.state, State::Sleep { .. }));
    }

    #[test]
    fn stays_inside_a_smaller_window() {
        let mut p = pet();
        p.chase_chance = 1.0;
        p.state = State::ToPointer;
        p.pointer_moved(5.0, 5.0);
        run(&mut p, 10.0);
        p.set_bounds(300.0, 200.0, 16.0, 16.0);
        let (x, y, w, h) = p.frame();
        assert!(x >= 0.0 && y >= 0.0 && x + w <= 300.0 && y + h <= 200.0);
    }
}

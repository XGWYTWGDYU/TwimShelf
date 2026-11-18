// The little Clawd of the mascot mode, as core/src/pet.rs has it for the other apps: the same
// states, timings and pixels. The core's per-frame calls (tl_pet_*) are not on the server's wire, a
// round trip for each of thirty pictures a second would make no sense, so a change there is made
// here too. It answers each frame with plain rectangles; PetLayer paints them.

export const UNIT = 3;
export const SPRITE_W = 15;
export const SPRITE_H = 9;

const BODY = 0xFFDE886D;
const DARK = 0xFF141414;
const HEART = 0xFFE5484D;
const ANGER = 0xFFD92D20;
const MARK = 0xFF6E6E73;

const WALK_SPEED = 150;
const SHAKE_TURNS = 6;
const SHAKE_WINDOW = 1.6;
const SHAKE_MIN_RUN = 30;
const DIZZY_SECONDS = 2.6;
const SHAKE_COOLDOWN = 4;
const CHASE_CHANCE = 0.5;
const ACT_SECONDS = 3;
const IDLE_BEFORE_SLEEP = 45;
const TAU = Math.PI * 2;

type Act = 'glare' | 'stare' | 'pleased';
type Reaction = 'hop' | 'wave' | 'startle' | 'spin' | 'annoyed';
type Mote = 'heart' | 'zed' | 'anger' | 'question' | 'bang';
type Eyes = 'open' | 'blink' | 'closed' | 'round' | 'wide' | 'happy' | 'cross';
type State =
  | { kind: 'idle' }
  | { kind: 'dizzy'; left: number }
  | { kind: 'toPointer' }
  | { kind: 'acting'; act: Act; left: number }
  | { kind: 'home' }
  | { kind: 'stretch'; left: number }
  | { kind: 'sleep'; left: number };
type Particle = { x: number; y: number; age: number; life: number; kind: Mote };

/** x, y, width, height and an ARGB colour. */
export type PetRect = [number, number, number, number, number];

const REACTION_LENGTH: Record<Reaction, number> = { hop: 0.55, wave: 1.1, startle: 0.6, spin: 0.7, annoyed: 1.2 };
const MOTES: Record<Mote, [string[], number]> = {
  heart: [['.X.X.', 'XXXXX', 'XXXXX', '.XXX.', '..X..'], HEART],
  zed: [['XXXX', '..X.', '.X..', 'XXXX'], MARK],
  anger: [['X.X.X', '.X.X.', 'X...X', '.X.X.', 'X.X.X'], ANGER],
  question: [['.XX.', 'X..X', '..X.', '.X..', '....', '.X..'], MARK],
  bang: [['X', 'X', 'X', '.', 'X'], ANGER],
};

const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);

export class PetEngine {
  private width = 0; private height = 0; private marginRight = 0; private marginBottom = 0;
  private x = 0; private y = 0;
  private target: [number, number] = [0, 0];
  private facing = 1;
  private state: State = { kind: 'idle' };
  private reaction: [Reaction, number] | null = null;
  private pointer: [number, number] | null = null;
  private gaze: [number, number] = [0, 0];
  private clock = 0; private walkPhase = 0; private idleFor = 0; private nextBlink = 2.5; private blinkLeft = 0;
  private runFrom: [number, number] | null = null;
  private runDir: [number, number] = [0, 0];
  private turns: number[] = [];
  private cooldownUntil = 0;
  private taps: number[] = [];
  private particles: Particle[] = [];
  private moteTimer = 0;

  private home(): [number, number] {
    return [Math.max(this.width - SPRITE_W * UNIT - this.marginRight, 0), Math.max(this.height - SPRITE_H * UNIT - this.marginBottom, 0)];
  }
  private atHome() { return this.state.kind === 'idle' || this.state.kind === 'stretch' || this.state.kind === 'sleep'; }

  /** The view's size and how far from its corner home is. */
  setBounds(width: number, height: number, marginRight: number, marginBottom: number) {
    const first = this.width === 0;
    this.width = width; this.height = height; this.marginRight = marginRight; this.marginBottom = marginBottom;
    if (first || this.atHome()) [this.x, this.y] = this.home();
    this.x = clamp(this.x, 0, Math.max(width - SPRITE_W * UNIT, 0));
    this.y = clamp(this.y, 0, Math.max(height - SPRITE_H * UNIT, 0));
  }

  pointerMoved(x: number, y: number) { this.noteShake(x, y); this.pointer = [x, y]; }

  /** The pointer left, or the window went to the background: it looks straight ahead again. */
  pointerGone() { this.pointer = null; this.runFrom = null; this.turns = []; }

  private noteShake(x: number, y: number) {
    if (!this.runFrom) { this.runFrom = [x, y]; return; }
    const dx = x - this.runFrom[0], dy = y - this.runFrom[1];
    const len = Math.hypot(dx, dy);
    if (len < SHAKE_MIN_RUN) return;
    const dir: [number, number] = [dx / len, dy / len];
    if (dir[0] * this.runDir[0] + dir[1] * this.runDir[1] < -0.2) this.turns.push(this.clock);
    this.runDir = dir;
    this.runFrom = [x, y];
    this.turns = this.turns.filter((t) => this.clock - t <= SHAKE_WINDOW);
    if (this.turns.length >= SHAKE_TURNS && this.clock >= this.cooldownUntil && this.state.kind !== 'dizzy' && this.state.kind !== 'sleep') {
      this.state = { kind: 'dizzy', left: DIZZY_SECONDS };
      this.turns = [];
      this.reaction = null;
    }
  }

  /** Whether a point is on it (a little generously: it is small). */
  hit(x: number, y: number) {
    return x >= this.x - 6 && x <= this.x + SPRITE_W * UNIT + 6 && y >= this.y - 6 && y <= this.y + SPRITE_H * UNIT + 6;
  }

  /** A tap on it. False when the tap missed. */
  tap(x: number, y: number) {
    if (!this.hit(x, y)) return false;
    this.taps = this.taps.filter((t) => this.clock - t < 2);
    this.taps.push(this.clock);
    this.idleFor = 0;
    const top: [number, number] = [this.x + SPRITE_W * UNIT / 2, this.y - 2];
    const woken = this.state.kind === 'sleep';
    if (woken) this.state = { kind: 'idle' };
    let kind: Reaction;
    if (woken) kind = 'startle';
    else if (this.taps.length >= 5) { this.taps = []; kind = 'annoyed'; }
    else kind = (['hop', 'wave', 'spin'] as const)[Math.floor(Math.random() * 3)];
    this.reaction = [kind, 0];
    if (kind === 'hop' || kind === 'wave') this.spawn('heart', top, 1);
    else if (kind === 'startle') this.spawn('bang', top, 0.9);
    else if (kind === 'annoyed') this.spawn('anger', top, 1);
    return true;
  }

  private spawn(kind: Mote, at: [number, number], life: number) { this.particles.push({ x: at[0], y: at[1], age: 0, life, kind }); }

  /** Advances by `dt` seconds. */
  tick(seconds: number) {
    const dt = clamp(seconds, 0, 0.1);
    this.clock += dt;
    this.updateGaze(dt);
    this.updateBlink(dt);
    for (const p of this.particles) { p.age += dt; p.y -= 14 * dt; }
    this.particles = this.particles.filter((p) => p.age < p.life);
    if (this.reaction) {
      const t = this.reaction[1] + dt;
      // a reaction holds everything else for its moment
      this.reaction = t < REACTION_LENGTH[this.reaction[0]] ? [this.reaction[0], t] : null;
      return;
    }
    this.stepState(dt);
  }

  private stepState(dt: number) {
    const s = this.state;
    switch (s.kind) {
      case 'idle':
        this.idleFor += dt;
        if (this.idleFor > IDLE_BEFORE_SLEEP) this.state = { kind: 'sleep', left: 15 + Math.random() * 15 };
        break;
      case 'dizzy': {
        const left = s.left - dt;
        if (left > 0) { this.state = { kind: 'dizzy', left }; return; }
        this.cooldownUntil = this.clock + SHAKE_COOLDOWN;
        this.idleFor = 0;
        this.state = Math.random() < CHASE_CHANCE && this.pointer ? { kind: 'toPointer' } : this.backHomeState();
        break;
      }
      case 'toPointer': {
        if (!this.pointer) { this.state = { kind: 'home' }; return; }
        // beside the pointer, on the side it came from, inside the window
        const w = SPRITE_W * UNIT, h = SPRITE_H * UNIT, [px, py] = this.pointer;
        const side = this.x + w / 2 < px ? -1 : 1;
        this.target = [clamp(px + side * (w / 2 + 14) - w / 2, 0, Math.max(this.width - w, 0)), clamp(py - h / 2, 0, Math.max(this.height - h, 0))];
        if (this.walk(dt)) {
          const act = (['glare', 'stare', 'pleased'] as const)[Math.floor(Math.random() * 3)];
          const top: [number, number] = [this.x + w / 2, this.y - 2];
          if (act === 'glare') this.spawn('anger', top, ACT_SECONDS);
          else if (act === 'stare') this.spawn('question', top, ACT_SECONDS);
          this.state = { kind: 'acting', act, left: ACT_SECONDS };
        }
        break;
      }
      case 'acting': {
        const left = s.left - dt;
        if (s.act === 'pleased') {
          this.moteTimer -= dt;
          if (this.moteTimer <= 0) {
            this.moteTimer = 0.7;
            this.spawn('heart', [this.x + SPRITE_W * UNIT / 2, this.y - 2], 1);
          }
        }
        this.state = left > 0 ? { kind: 'acting', act: s.act, left } : { kind: 'home' };
        break;
      }
      case 'home':
        this.target = this.home();
        if (this.walk(dt)) { this.idleFor = 0; this.state = this.backHomeState(); }
        break;
      case 'stretch': {
        const left = s.left - dt;
        this.state = left > 0 ? { kind: 'stretch', left } : { kind: 'idle' };
        break;
      }
      case 'sleep': {
        const left = s.left - dt;
        this.moteTimer -= dt;
        if (this.moteTimer <= 0) {
          this.moteTimer = 1.3;
          this.spawn('zed', [this.x + SPRITE_W * UNIT - 6, this.y - 2], 2.2);
        }
        if (left > 0) this.state = { kind: 'sleep', left };
        else { this.idleFor = 0; this.state = { kind: 'stretch', left: 1.4 }; }
        break;
      }
    }
  }

  /** At home: what it does on arriving. Away: walk back first. */
  private backHomeState(): State {
    const [hx, hy] = this.home();
    if (Math.abs(this.x - hx) > 1 || Math.abs(this.y - hy) > 1) return { kind: 'home' };
    return Math.random() < 0.6 ? { kind: 'sleep', left: 10 + Math.random() * 12 } : { kind: 'stretch', left: 1.4 };
  }

  /** A step towards the target; true on arrival. */
  private walk(dt: number) {
    const dx = this.target[0] - this.x, dy = this.target[1] - this.y;
    const d = Math.hypot(dx, dy);
    if (Math.abs(dx) > 1) this.facing = Math.sign(dx);
    const step = WALK_SPEED * dt;
    if (d <= Math.max(step, 0.5)) { [this.x, this.y] = this.target; return true; }
    this.x += dx / d * step;
    this.y += dy / d * step;
    this.walkPhase += dt * 9;
    return false;
  }

  private updateGaze(dt: number) {
    let want: [number, number] = [0, 0];
    if (this.state.kind === 'toPointer' || this.state.kind === 'home') want = [this.facing, 0];
    else if (this.pointer) {
      const dx = this.pointer[0] - (this.x + SPRITE_W * UNIT / 2), dy = this.pointer[1] - (this.y + SPRITE_H * UNIT * 0.35);
      const d = Math.max(Math.hypot(dx, dy), 1);
      // close to it the eyes come back towards the middle, as they would
      const near = Math.min(d / 40, 1);
      want = [dx / d * near, dy / d * near];
    }
    const k = Math.min(dt * 14, 1);
    this.gaze[0] += (want[0] - this.gaze[0]) * k;
    this.gaze[1] += (want[1] - this.gaze[1]) * k;
  }

  private updateBlink(dt: number) {
    this.blinkLeft = Math.max(this.blinkLeft - dt, 0);
    this.nextBlink -= dt;
    if (this.nextBlink <= 0) { this.blinkLeft = 0.12; this.nextBlink = 2 + Math.random() * 4; }
  }

  /** The picture of this moment, back to front, in view coordinates. */
  draw(): PetRect[] {
    const out: PetRect[] = [];
    const t = this.clock, s = this.state;
    let ox = 0, oy = 0, sx = 1, leftHand = 0, rightHand = 0, legs = 0, breath = 0, brows = false;
    let eyes: Eyes = this.blinkLeft > 0 ? 'blink' : 'open';
    switch (s.kind) {
      case 'idle': break;
      case 'dizzy': eyes = 'round'; ox = Math.sin(t * 7) * 3; oy = Math.abs(Math.sin(t * 14)) * -1; break;
      case 'toPointer': case 'home': legs = this.walkPhase; oy = -Math.abs(Math.sin(this.walkPhase * 2)) * 1.5; break;
      case 'acting':
        if (s.act === 'glare') { brows = true; ox = Math.sin(t * 40) * 1.2; leftHand = 1; rightHand = 1; }
        else if (s.act === 'stare') { eyes = 'wide'; oy = Math.sin(t * 2); }
        else { eyes = 'happy'; oy = -Math.abs(Math.sin(t * 8)) * 3; rightHand = Math.abs(Math.sin(t * 8)); leftHand = rightHand; }
        break;
      case 'stretch': { const up = clamp(1 - Math.abs(s.left / 1.4 - 0.5) * 2, 0, 1); leftHand = up * 2; rightHand = up * 2; eyes = 'closed'; breath = -up; break; }
      case 'sleep': eyes = 'closed'; breath = (Math.sin(t * 1.6) + 1) / 2; break;
    }
    if (this.reaction) {
      const [r, p] = this.reaction;
      const q = clamp(p / REACTION_LENGTH[r], 0, 1);
      if (r === 'hop') { oy = -Math.sin(q * Math.PI) * 16; eyes = 'happy'; leftHand = 1; rightHand = 1; }
      else if (r === 'wave') { rightHand = 1 + Math.sin(p * 16); eyes = 'happy'; }
      else if (r === 'startle') { oy = -Math.sin(q * Math.PI) * 12; eyes = 'wide'; leftHand = 2; rightHand = 2; }
      else if (r === 'spin') { sx = Math.cos(q * TAU); oy = -Math.sin(q * Math.PI) * 6; eyes = 'open'; }
      else { eyes = 'cross'; ox = Math.sin(p * 45) * 1.6; }
    }
    const bx = this.x + ox, by = this.y + oy, centre = SPRITE_W / 2;
    // a pixel of the sprite to view coordinates (a turn narrows it about its middle)
    const px = (gx: number, gy: number, gw: number, gh: number, color: number) => {
      const a = centre + (gx - centre) * sx, b = centre + (gx + gw - centre) * sx;
      const l = Math.min(a, b), r = Math.max(a, b);
      if (r - l > 0.01) out.push([bx + l * UNIT, by + gy * UNIT, (r - l) * UNIT, gh * UNIT, color]);
    };
    // feet stay on the ground line; in a walk they take turns
    [3, 5, 9, 11].forEach((fx, i) => {
      const lift = legs !== 0 ? Math.max(Math.sin(legs + i * Math.PI) * 0.7, 0) : 0;
      px(fx, 7, 1, 2 - lift, BODY);
    });
    px(0, 3 - leftHand, 2, 2, BODY);
    px(13, 3 - rightHand, 2, 2, BODY);
    px(2, breath * 0.6, 11, 7 - breath * 0.6, BODY);
    const gx = this.gaze[0] * 0.8, gy = this.gaze[1] * 0.6;
    switch (eyes) {
      case 'open': px(4 + gx, 2 + gy, 1, 2, DARK); px(10 + gx, 2 + gy, 1, 2, DARK); break;
      case 'blink': case 'closed': px(3.5, 3 + breath * 0.3, 2, 1, DARK); px(9.5, 3 + breath * 0.3, 2, 1, DARK); break;
      case 'wide': px(3.5 + gx, 1.5 + gy, 2, 2.5, DARK); px(9.5 + gx, 1.5 + gy, 2, 2.5, DARK); break;
      case 'round':
        // a ring of dots going round with a gap in it, the two eyes in opposite directions
        for (const [cx, dir] of [[4.5, 1], [10.5, -1]]) {
          for (let k = 0; k < 7; k++) {
            const a = t * 7 * dir + k * TAU / 8;
            px(cx + Math.cos(a) * 1.45 - 0.35, 3 + Math.sin(a) * 1.45 - 0.35, 0.7, 0.7, DARK);
          }
          px(cx - 0.3, 2.7, 0.6, 0.6, DARK);
        }
        break;
      case 'happy':
        for (const cx of [4.5, 10.5]) { px(cx - 1.5, 3, 1, 1, DARK); px(cx - 0.5, 2, 1, 1, DARK); px(cx + 0.5, 3, 1, 1, DARK); }
        break;
      case 'cross':
        for (const cx of [4.5, 10.5]) {
          px(cx - 1, 2, 0.7, 0.7, DARK); px(cx + 0.3, 2, 0.7, 0.7, DARK);
          px(cx - 0.35, 2.7, 0.7, 0.7, DARK);
          px(cx - 1, 3.4, 0.7, 0.7, DARK); px(cx + 0.3, 3.4, 0.7, 0.7, DARK);
        }
        break;
    }
    if (brows) {
      for (const [x, step] of [[3, 0.5], [12, -0.5]]) {
        for (let k = 0; k < 3; k++) px(x + step * 2 * k * 0.7, 0.2 + k * 0.35, 1, 0.6, DARK);
      }
    }
    for (const p of this.particles) {
      const fade = Math.floor(Math.min((p.life - p.age) / 0.3, 1) * 255);
      const [rows, color] = MOTES[p.kind];
      const size = 2, w = rows[0].length * size;
      rows.forEach((row, j) => {
        for (let i = 0; i < row.length; i++) {
          if (row[i] === 'X') out.push([p.x - w / 2 + i * size, p.y - (rows.length - j) * size, size, size, fade * 0x1000000 + (color & 0xFFFFFF)]);
        }
      });
    }
    return out;
  }
}

//! An abstract model of AI tagging, tags and sync across devices, small enough to check
//! exhaustively (unit tests) and with Kani (bounded model checking). It is the specification the
//! store follows; the SQL that implements it is covered by the replica property tests.
//!
//! State of one device:
//! - synced: per (media, label) a `TagBits` register (each origin bit its own LWW register,
//!   `crdt::merge_bits`) and the grow-only set `done` of analysed media (`ai_done`);
//! - local only: per media the number of failed analysis attempts on this device (`ai_fail`).
//!
//! Every device analyses whatever is not in `done` yet: no device owns a media, there is no
//! priority between devices, and two devices may analyse the same media at the same time.
//!
//! What is proved (see `proofs` and `tests`):
//! 1. `join` of replicas is a semilattice: idempotent, commutative, associative.
//! 2. Applying operations commutes and is idempotent, so order and duplicates of delivery do
//!    not matter (strong eventual consistency).
//! 3. Concurrent analyses of one media on two devices end, on both, with the union of the AI
//!    tags; tags you added or endorsed are never touched by an analysis.
//! 4. Progress: each success, media error or crash step strictly decreases a ranking function,
//!    so a finite queue ends under these transitions
//!    and one image that cannot be analysed never blocks the others (the old rule, "stop the
//!    run on an error", leaves the queue head unchanged forever).
//! 5. Liveness across devices: a media that any device can analyse ends up analysed on every
//!    device, whichever device downloaded it, assuming fresh retry budgets, fewer than MAX
//!    crashes per media, successful attempts on capable devices, and the final syncs below.
//!
//! Scope: this abstracts additive analysis only. It does not model replace-old tagging,
//! aliases, per-model sources, cancellation/undo, library epochs, concurrent workers, wall-clock
//! run timestamps, or newly arriving media. Those require separate implementation tests;
//! the ranking argument is not a proof that arbitrary frontend executions terminate.
use crate::crdt::{merge_bits, TagBits};
use crate::rules::MAX_AI_ATTEMPTS;

/// Media and labels in the model (small on purpose: the properties are per key, and keys are
/// independent, so a few keys show every interaction).
pub const N: usize = 3;
pub const L: usize = 2;
const MAX: u8 = MAX_AI_ATTEMPTS as u8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Replica {
    /// Grow-only set of analysed media (bit m).
    pub done: u8,
    pub tags: [[TagBits; L]; N],
}

/// Merge of two replicas: union of `done`, register-wise merge of tags.
pub fn join(a: Replica, b: Replica) -> Replica {
    let mut r = Replica { done: a.done | b.done, tags: a.tags };
    let mut m = 0;
    while m < N {
        let mut l = 0;
        while l < L { r.tags[m][l] = merge_bits(a.tags[m][l], b.tags[m][l]); l += 1; }
        m += 1;
    }
    r
}

/// The synced operations that tagging produces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// `Op::AiDone` of the op log.
    AiDone { m: usize },
    /// `Op::Tag`: write `origin` to the bits in `mask` at clock `hlc`.
    Tag { m: usize, l: usize, origin: u8, mask: u8, hlc: u64 },
}

/// Applying an op is joining the state with the op's own (singleton) state.
pub fn apply(r: Replica, op: Op) -> Replica {
    let mut s = Replica::default();
    match op {
        Op::AiDone { m } => s.done = 1 << m,
        Op::Tag { m, l, origin, mask, hlc } => s.tags[m][l] = TagBits::write(origin, mask, hlc),
    }
    join(r, s)
}

/// One analysis result of a media as ops: an AI-bit write for each proposed label (an analysis
/// that does not replace old tags only sets bits) and the analysed mark.
pub fn analysis(r: Replica, m: usize, proposed: u8, hlc: u64) -> Replica {
    let mut r = r;
    let mut l = 0;
    while l < L {
        if proposed & (1 << l) != 0 { r = apply(r, Op::Tag { m, l, origin: 2, mask: 2, hlc }); }
        l += 1;
    }
    apply(r, Op::AiDone { m })
}

// ---------- the analysis queue of one device ----------

/// Local state of a device's tagger: failed attempts per media, and media that failed during
/// the current run (skipped until the next run).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Queue { pub fail: [u8; N], pub run_failed: u8 }

/// The next media this device analyses: the first one not analysed, not given up on here and
/// not failed during this run (`Store::media_needing_ai_for`).
pub fn head(done: u8, q: &Queue) -> Option<usize> {
    let mut m = 0;
    while m < N {
        if done & (1 << m) == 0 && q.fail[m] < MAX && q.run_failed & (1 << m) == 0 { return Some(m); }
        m += 1;
    }
    None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome { Success, Error, Crash }

/// One step of the tagger on the head media (the attempt is counted before the model runs).
pub fn step(done: u8, q: Queue, m: usize, o: Outcome) -> (u8, Queue) {
    let mut q = q;
    match o {
        Outcome::Success => { q.fail[m] = 0; (done | 1 << m, q) }
        Outcome::Error => { q.fail[m] += 1; q.run_failed |= 1 << m; (done, q) }
        // the app died: the counted attempt stays, a new run starts
        Outcome::Crash => { q.fail[m] += 1; q.run_failed = 0; (done, q) }
    }
}

/// The old rule: an error stopped the run and changed nothing, so the next run started from the
/// same media.
#[cfg(test)]
pub fn step_old(done: u8, m: usize, o: Outcome) -> u8 { if o == Outcome::Success { done | 1 << m } else { done } }

/// Ranking function: what is left to try on this device. Every step lowers it (an attempt
/// weighs more than all "failed in this run" marks together, which a crash clears).
pub fn rank(done: u8, q: &Queue) -> u32 {
    let mut r = 0u32;
    let mut m = 0;
    while m < N {
        if done & (1 << m) == 0 && q.fail[m] < MAX { r += (MAX - q.fail[m]) as u32 * (N as u32 + 1) + if q.run_failed & (1 << m) == 0 { 1 } else { 0 }; }
        m += 1;
    }
    r
}

/// Runs a device's tagger until it has nothing left, given which media it can analyse
/// (`can`) and how many times it crashes on each before an attempt completes (`crashes`).
/// Returns the analysed set and the queue.
pub fn run_to_quiescence(done: u8, q: Queue, can: u8, crashes: [u8; N]) -> (u8, Queue) {
    let (mut d, mut q) = (done, q);
    let mut crashed = [0u8; N];
    // at most N * (MAX + 1) steps: the ranking function bounds it
    let mut i = 0;
    while i < N * (MAX as usize + 1) {
        let Some(m) = head(d, &q) else { break };
        let o = if crashed[m] < crashes[m] { crashed[m] += 1; Outcome::Crash }
            else if can & (1 << m) != 0 { Outcome::Success } else { Outcome::Error };
        let (d2, q2) = step(d, q, m, o);
        d = d2; q = q2;
        i += 1;
    }
    (d, q)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bits() -> Vec<TagBits> {
        let mut v = vec![TagBits::default()];
        for o in 0..4u8 { for (hu, ha) in [(1u64, 2u64), (2, 1), (3, 3)] { v.push(TagBits { origin: o, h_user: hu, h_ai: ha }); } }
        v
    }
    fn replicas() -> Vec<Replica> {
        let b = bits();
        let mut v = vec![];
        for (i, x) in b.iter().enumerate() {
            let mut r = Replica { done: (i % 8) as u8, ..Default::default() };
            r.tags[0][0] = *x;
            r.tags[1][1] = b[(i * 7 + 3) % b.len()];
            v.push(r);
        }
        v
    }

    #[test]
    fn join_is_a_semilattice() {
        let rs = replicas();
        for &a in &rs { for &b in &rs {
            assert_eq!(join(a, a), a);
            assert_eq!(join(a, b), join(b, a));
            for &c in &rs { assert_eq!(join(join(a, b), c), join(a, join(b, c))); }
        } }
    }

    fn ops() -> Vec<Op> {
        let mut v = vec![Op::AiDone { m: 0 }, Op::AiDone { m: 2 }];
        for origin in 0..4u8 { for mask in 1..4u8 { for hlc in [1u64, 2] { v.push(Op::Tag { m: 0, l: 1, origin, mask, hlc }); } } }
        v
    }

    #[test]
    fn ops_commute_and_are_idempotent() {
        let os = ops();
        for &r in &replicas() { for &a in &os {
            assert_eq!(apply(apply(r, a), a), apply(r, a));
            for &b in &os { assert_eq!(apply(apply(r, a), b), apply(apply(r, b), a)); }
        } }
    }

    #[test]
    fn concurrent_analyses_end_with_the_union() {
        for user in 0..4u8 { for pa in 0..4u8 { for pb in 0..4u8 { for (ha, hb) in [(5u64, 6u64), (6, 5), (5, 5)] {
            // the user's own tags first, then both devices analyse media 0 without seeing each other
            let mut base = Replica::default();
            for l in 0..L { if user & (1 << l) != 0 { base = apply(base, Op::Tag { m: 0, l, origin: 1, mask: 1, hlc: 1 }); } }
            let a = analysis(base, 0, pa, ha);
            let b = analysis(base, 0, pb, hb);
            let (x, y) = (join(a, b), join(b, a));
            assert_eq!(x, y);
            assert!(x.done & 1 != 0);
            for l in 0..L {
                assert_eq!(x.tags[0][l].origin & 2 != 0, (pa | pb) & (1 << l) != 0, "AI bits are the union");
                assert_eq!(x.tags[0][l].origin & 1 != 0, user & (1 << l) != 0, "your own tags untouched");
            }
        } } } }
    }

    #[test]
    fn every_step_lowers_the_rank_and_the_old_rule_does_not() {
        for done in 0..(1u8 << N) { for f0 in 0..=MAX { for f1 in 0..=MAX { for rf in 0..(1u8 << N) {
            let q = Queue { fail: [f0, f1, 0], run_failed: rf };
            let Some(m) = head(done, &q) else { continue };
            for o in [Outcome::Success, Outcome::Error, Outcome::Crash] {
                let (d2, q2) = step(done, q, m, o);
                assert!(rank(d2, &q2) < rank(done, &q), "{done} {q:?} {o:?}");
                assert!(d2 & done == done, "analysed media stay analysed");
            }
            // the old rule: an error leaves the state, so the same media is the head again
            assert_eq!(step_old(done, m, Outcome::Error), done);
        } } } }
    }

    #[test]
    fn a_media_any_device_can_analyse_ends_up_analysed_everywhere() {
        // which device can analyse which media, and how often each crashes on it (fewer than
        // the attempt limit: a device that keeps crashing on a media gives it up, by design)
        for can_a in 0..(1u8 << N) { for can_b in 0..(1u8 << N) { for ca in 0..MAX { for cb in 0..MAX {
            let crashes_a = [ca, 0, ca];
            let crashes_b = [0, cb, cb];
            // A runs first and syncs; B runs on what is left; then they sync again
            let (da, _) = run_to_quiescence(0, Queue::default(), can_a, crashes_a);
            let (db, _) = run_to_quiescence(da, Queue::default(), can_b, crashes_b);
            let done = da | db;
            assert_eq!(done & (can_a | can_b), can_a | can_b, "can_a={can_a:b} can_b={can_b:b}");
            // and in the other order
            let (db2, _) = run_to_quiescence(0, Queue::default(), can_b, crashes_b);
            let (da2, _) = run_to_quiescence(db2, Queue::default(), can_a, crashes_a);
            assert_eq!((da2 | db2) & (can_a | can_b), can_a | can_b);
            // in parallel without seeing each other, then syncing
            let (pa, _) = run_to_quiescence(0, Queue::default(), can_a, crashes_a);
            let (pb, _) = run_to_quiescence(0, Queue::default(), can_b, crashes_b);
            assert_eq!((pa | pb) & (can_a | can_b), can_a | can_b);
        } } } }
    }
}

#[cfg(kani)]
mod proofs {
    use super::*;

    fn any_bits() -> TagBits { let o: u8 = kani::any(); kani::assume(o <= 3); TagBits { origin: o, h_user: kani::any(), h_ai: kani::any() } }
    fn any_replica() -> Replica {
        let mut r = Replica { done: kani::any(), ..Default::default() };
        kani::assume(r.done < 1 << N);
        // Cover all keys independently, including off-diagonal and final-row indexing.
        for row in &mut r.tags { for cell in row { *cell = any_bits(); } }
        r
    }
    fn any_op() -> Op {
        if kani::any() { let m: usize = kani::any(); kani::assume(m < N); Op::AiDone { m } }
        else {
            let (m, l): (usize, usize) = (kani::any(), kani::any());
            kani::assume(m < N && l < L);
            let (origin, mask): (u8, u8) = (kani::any(), kani::any());
            kani::assume(origin <= 3 && mask >= 1 && mask <= 3);
            Op::Tag { m, l, origin, mask, hlc: kani::any() }
        }
    }

    #[kani::proof]
    fn replica_join_is_a_semilattice() {
        let (a, b, c) = (any_replica(), any_replica(), any_replica());
        assert_eq!(join(a, a), a);
        assert_eq!(join(a, b), join(b, a));
        assert_eq!(join(join(a, b), c), join(a, join(b, c)));
    }

    #[kani::proof]
    fn ops_commute_and_are_idempotent() {
        let r = any_replica();
        let (a, b) = (any_op(), any_op());
        assert_eq!(apply(apply(r, a), a), apply(r, a));
        assert_eq!(apply(apply(r, a), b), apply(apply(r, b), a));
    }

    #[kani::proof]
    fn concurrent_analyses_end_with_the_union_and_keep_your_tags() {
        let user: u8 = kani::any();
        let (pa, pb): (u8, u8) = (kani::any(), kani::any());
        kani::assume(user < 4 && pa < 4 && pb < 4);
        let (hu, ha, hb): (u64, u64, u64) = (kani::any(), kani::any(), kani::any());
        kani::assume(hu > 0 && ha > 0 && hb > 0);
        let mut base = Replica::default();
        if user & 1 != 0 { base = apply(base, Op::Tag { m: 0, l: 0, origin: 1, mask: 1, hlc: hu }); }
        if user & 2 != 0 { base = apply(base, Op::Tag { m: 0, l: 1, origin: 1, mask: 1, hlc: hu }); }
        let a = analysis(base, 0, pa, ha);
        let b = analysis(base, 0, pb, hb);
        let x = join(a, b);
        assert_eq!(x, join(b, a));
        assert!(x.done & 1 != 0);
        assert_eq!(x.tags[0][0].origin & 2 != 0, (pa | pb) & 1 != 0);
        assert_eq!(x.tags[0][1].origin & 2 != 0, (pa | pb) & 2 != 0);
        assert_eq!(x.tags[0][0].origin & 1 != 0, user & 1 != 0);
        assert_eq!(x.tags[0][1].origin & 1 != 0, user & 2 != 0);
    }

    #[kani::proof]
    fn every_tagger_step_makes_progress() {
        let done: u8 = kani::any();
        kani::assume(done < 1 << N);
        let q = Queue { fail: [kani::any(), kani::any(), kani::any()], run_failed: kani::any() };
        kani::assume(q.fail[0] <= MAX && q.fail[1] <= MAX && q.fail[2] <= MAX && q.run_failed < 1 << N);
        if let Some(m) = head(done, &q) {
            let o = match kani::any::<u8>() % 3 { 0 => Outcome::Success, 1 => Outcome::Error, _ => Outcome::Crash };
            let (d2, q2) = step(done, q, m, o);
            assert!(rank(d2, &q2) < rank(done, &q));
            assert!(d2 & done == done);
            // within a run a media that failed is never the head again
            if o == Outcome::Error { assert!(head(d2, &q2) != Some(m)); }
        }
    }

    #[kani::proof]
    #[kani::unwind(12)]
    fn analysable_media_end_up_analysed_on_every_device() {
        let (can_a, can_b): (u8, u8) = (kani::any(), kani::any());
        kani::assume(can_a < 1 << N && can_b < 1 << N);
        let crashes_a = [kani::any(), kani::any(), kani::any()];
        let crashes_b = [kani::any(), kani::any(), kani::any()];
        let mut k = 0;
        while k < N { kani::assume(crashes_a[k] < MAX && crashes_b[k] < MAX); k += 1; }
        let a_first: bool = kani::any();
        let (x, y) = if a_first { (can_a, can_b) } else { (can_b, can_a) };
        let (cx, cy) = if a_first { (crashes_a, crashes_b) } else { (crashes_b, crashes_a) };
        // one device runs, they sync, the other runs on what is left, they sync
        let (d1, _) = run_to_quiescence(0, Queue::default(), x, cx);
        let (d2, _) = run_to_quiescence(d1, Queue::default(), y, cy);
        let done = d1 | d2;
        assert_eq!(done & (can_a | can_b), can_a | can_b);
    }
}

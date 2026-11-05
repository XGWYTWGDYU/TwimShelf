//! Pure merge rules for sync. Kept free of I/O so they can be model-checked (see `kani` proofs).

/// Hybrid logical clock value: milliseconds << 16 | counter.
pub type Hlc = u64;

/// State of one (media, tag-label) register: who tagged it (bitset, 0 = removed) and when.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TagReg { pub origin: u8, pub hlc: Hlc }

/// Last-writer-wins merge. Ties on the clock are broken by the larger origin value so the
/// result never depends on argument order.
pub fn merge_tag(a: TagReg, b: TagReg) -> TagReg {
    if a.hlc != b.hlc { if a.hlc > b.hlc { a } else { b } } else if a.origin >= b.origin { a } else { b }
}

/// A tag on a media: each origin bit (USER = 1, AI = 2) is its own last-writer-wins register,
/// so a tag added by hand on one device and proposed by AI on another keeps both bits (a single
/// register for both lost one of them). A write changes only the bits in its mask; records of
/// older versions change both bits, which is exactly the old single-register behaviour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TagBits { pub origin: u8, pub h_user: Hlc, pub h_ai: Hlc }

impl TagBits {
    /// The latest clock of either bit (for ordering by recency).
    pub fn hlc(&self) -> Hlc { self.h_user.max(self.h_ai) }
    /// What a write of `origin` to the bits in `mask` stands for; bits outside the mask are
    /// left at the bottom value (unset at clock 0), which every merge ignores.
    pub fn write(origin: u8, mask: u8, hlc: Hlc) -> TagBits {
        TagBits { origin: origin & mask & 3, h_user: if mask & 1 != 0 { hlc } else { 0 }, h_ai: if mask & 2 != 0 { hlc } else { 0 } }
    }
}

/// One bit: the newer clock wins; on equal clocks "set" wins (so the result never depends on order).
fn merge_bit(a: (bool, Hlc), b: (bool, Hlc)) -> (bool, Hlc) {
    if a.1 != b.1 { if a.1 > b.1 { a } else { b } } else { (a.0 || b.0, a.1) }
}

pub fn merge_bits(a: TagBits, b: TagBits) -> TagBits {
    let u = merge_bit((a.origin & 1 != 0, a.h_user), (b.origin & 1 != 0, b.h_user));
    let i = merge_bit((a.origin & 2 != 0, a.h_ai), (b.origin & 2 != 0, b.h_ai));
    TagBits { origin: (u.0 as u8) | ((i.0 as u8) << 1), h_user: u.1, h_ai: i.1 }
}

/// Next clock value: strictly greater than `last` unless saturated at u64::MAX;
/// tracks wall time when it is ahead. Callers must not assume strict progress at exhaustion.
pub fn next_hlc(last: Hlc, now_ms: u64) -> Hlc {
    let wall = now_ms.saturating_mul(1 << 16);
    if wall > last { wall } else { last.saturating_add(1) }
}

/// Origin bit operations (USER = 1, AI = 2).
pub fn add_origin(current: u8, added: u8) -> u8 { (current | added) & 3 }

#[cfg(test)]
mod tests {
    use super::*;
    fn regs() -> Vec<TagReg> {
        let mut v = vec![];
        for o in 0..4u8 { for h in [0u64, 1, 5, u64::MAX] { v.push(TagReg { origin: o, hlc: h }); } }
        v
    }
    #[test]
    fn merge_is_a_semilattice_exhaustively() {
        let r = regs();
        for &a in &r { for &b in &r {
            assert_eq!(merge_tag(a, b), merge_tag(b, a));
            assert_eq!(merge_tag(a, a), a);
            for &c in &r { assert_eq!(merge_tag(merge_tag(a, b), c), merge_tag(a, merge_tag(b, c))); }
        } }
    }
    #[test]
    fn hlc_monotonic() {
        assert!(next_hlc(10, 0) > 10);
        assert!(next_hlc(0, 5) == 5 << 16);
        assert!(next_hlc(u64::MAX, 0) == u64::MAX);
    }
}

#[cfg(kani)]
mod proofs {
    use super::*;
    #[kani::proof]
    fn merge_commutative() {
        let a = TagReg { origin: kani::any(), hlc: kani::any() };
        let b = TagReg { origin: kani::any(), hlc: kani::any() };
        assert_eq!(merge_tag(a, b), merge_tag(b, a));
    }
    #[kani::proof]
    fn merge_associative() {
        let a = TagReg { origin: kani::any(), hlc: kani::any() };
        let b = TagReg { origin: kani::any(), hlc: kani::any() };
        let c = TagReg { origin: kani::any(), hlc: kani::any() };
        assert_eq!(merge_tag(merge_tag(a, b), c), merge_tag(a, merge_tag(b, c)));
    }
    #[kani::proof]
    fn merge_idempotent_and_selects_input() {
        let a = TagReg { origin: kani::any(), hlc: kani::any() };
        let b = TagReg { origin: kani::any(), hlc: kani::any() };
        assert_eq!(merge_tag(a, a), a);
        let m = merge_tag(a, b);
        assert!(m == a || m == b);
        assert!(m.hlc >= a.hlc && m.hlc >= b.hlc);
    }
    fn any_bits() -> TagBits { let o: u8 = kani::any(); kani::assume(o <= 3); TagBits { origin: o, h_user: kani::any(), h_ai: kani::any() } }

    #[kani::proof]
    fn tag_bits_merge_is_a_semilattice() {
        let (a, b, c) = (any_bits(), any_bits(), any_bits());
        assert_eq!(merge_bits(a, b), merge_bits(b, a));
        assert_eq!(merge_bits(merge_bits(a, b), c), merge_bits(a, merge_bits(b, c)));
        assert_eq!(merge_bits(a, a), a);
        // the empty state is neutral: a write that leaves a bit out never touches it
        assert_eq!(merge_bits(a, TagBits::default()), a);
    }

    #[kani::proof]
    fn concurrent_user_and_ai_tags_both_survive() {
        let (h1, h2): (u64, u64) = (kani::any(), kani::any());
        kani::assume(h1 > 0 && h2 > 0);
        // a hand-added tag on one device, the same tag from AI on another, in either order
        let m = merge_bits(TagBits::write(1, 1, h1), TagBits::write(2, 2, h2));
        assert!(m.origin == 3);
        // removing it everywhere (both bits) after both clears it
        let h3: u64 = kani::any();
        kani::assume(h3 > h1 && h3 > h2);
        assert!(merge_bits(m, TagBits::write(0, 3, h3)).origin == 0);
        // and a removal older than one of the adds keeps that add
        kani::assume(h1 > h2);
        let h4: u64 = kani::any();
        kani::assume(h4 > h2 && h4 < h1);
        assert!(merge_bits(m, TagBits::write(0, 3, h4)).origin == 1);
    }

    #[kani::proof]
    fn full_writes_behave_like_the_old_register() {
        // records from older versions write both bits; with distinct clocks the result is what
        // the single register gave (so devices that synced before the change agree after it)
        let (o1, o2): (u8, u8) = (kani::any(), kani::any());
        kani::assume(o1 <= 3 && o2 <= 3);
        let (h1, h2): (u64, u64) = (kani::any(), kani::any());
        kani::assume(h1 != h2);
        let new = merge_bits(TagBits::write(o1, 3, h1), TagBits::write(o2, 3, h2));
        let old = merge_tag(TagReg { origin: o1, hlc: h1 }, TagReg { origin: o2, hlc: h2 });
        assert!(new.origin == old.origin && new.hlc() == old.hlc);
    }

    #[kani::proof]
    fn hlc_strictly_increases_unless_saturated() {
        let last: u64 = kani::any();
        let now: u64 = kani::any();
        let n = next_hlc(last, now);
        assert!(n > last || last == u64::MAX);
    }
    #[kani::proof]
    fn endorsement_matches_every_scope() {
        let o: u8 = kani::any();
        kani::assume(o & 2 != 0);
        let e = add_origin(o, 1);
        assert!(e & 1 != 0 && e & 2 != 0);
        assert!(add_origin(o, 0) & !3 == 0);
    }
}

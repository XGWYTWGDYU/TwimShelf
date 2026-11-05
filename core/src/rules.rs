//! Pure decision rules for tags, re-tagging, export selection, sync bookkeeping and paths.
//!
//! Everything here is free of I/O and generic over the label type, so the same code that the
//! store executes is model-checked by Kani with small integer labels (see `proofs` below).
//! Origin bits: USER = 1, AI = 2; 0 is a removal tombstone.

pub const USER: u8 = 1;
pub const AI: u8 = 2;

/// Reserve a channel nonce before encryption/decryption. Exhaustion is terminal; never
/// wrap or saturate a counter and then reuse a nonce under the same session key.
pub fn take_channel_nonce(counter: &mut u64) -> Option<u64> {
    let nonce = *counter;
    *counter = nonce.checked_add(1)?;
    Some(nonce)
}

/// Does a tag with `origin` match a search scope mask (1 = mine, 2 = AI, 3 = both)?
pub fn scope_matches(origin: u8, mask: u8) -> bool { origin & mask & 3 != 0 }

/// New origin of one label after a re-tag. This per-label rule is all `retag_plan` decides;
/// it is heap-free so the model checker covers every input exhaustively.
///  * proposed again → gains the AI bit;
///  * not proposed, `replace_old`, and AI-only (unendorsed) → removed (0);
///  * otherwise unchanged (your own tags and endorsed AI tags are never touched).
pub fn retag_origin(cur: u8, proposed: bool, replace_old: bool) -> u8 {
    if proposed { (cur | AI) & 3 } else if replace_old && cur == AI { 0 } else { cur }
}

/// The change re-tagging makes to one label of one media.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetagChange<L> {
    pub label: L,
    /// New origin for the label, if it changes.
    pub origin: Option<u8>,
    /// Whether `model` should now be recorded as a source of the label.
    pub model_source: Option<bool>,
    /// Remove every model source of this label (it was dropped).
    pub clear_sources: bool,
}

/// Plans a re-tag of one media by `model` that proposed `new_labels`.
///
/// * Every proposed label gets the AI bit and `model` as a source.
/// * With `replace_old`, AI-only labels (origin == AI) that were not proposed again are removed.
/// * Labels carrying the USER bit — the user's own and endorsed AI tags — are never removed
///   and never lose a bit. Without `replace_old`, nothing is removed at all.
pub fn retag_plan<L: Clone + PartialEq>(existing: &[(L, u8)], new_labels: &[L], replace_old: bool) -> Vec<RetagChange<L>> {
    let mut out: Vec<RetagChange<L>> = Vec::new();
    for l in new_labels {
        if out.iter().any(|c| &c.label == l) { continue; }
        let cur = existing.iter().find(|(e, _)| e == l).map_or(0, |(_, o)| *o);
        let next = retag_origin(cur, true, replace_old);
        out.push(RetagChange { label: l.clone(), origin: (next != cur).then_some(next), model_source: Some(true), clear_sources: false });
    }
    for (l, o) in existing {
        if new_labels.contains(l) { continue; }
        let next = retag_origin(*o, false, replace_old);
        if next != *o {
            out.push(RetagChange { label: l.clone(), origin: Some(next), model_source: None, clear_sources: next == 0 });
        }
    }
    out
}

/// Applies a plan to an origin table (used by tests and proofs to state invariants).
pub fn apply_plan<L: Clone + PartialEq>(existing: &[(L, u8)], plan: &[RetagChange<L>]) -> Vec<(L, u8)> {
    let mut v: Vec<(L, u8)> = existing.to_vec();
    for c in plan {
        if let Some(o) = c.origin {
            match v.iter_mut().find(|(l, _)| *l == c.label) { Some(e) => e.1 = o, None => v.push((c.label.clone(), o)) }
        }
    }
    v
}

/// Merge of one post-metadata field, a last-writer-wins register over (clock, value). `None`
/// means "never set": an absent value never erases a present one. Ties on the clock are broken by
/// the larger value, so the result never depends on arrival order.
pub fn merge_field<V: Ord + Clone>(a: Option<(u64, V)>, b: Option<(u64, V)>) -> Option<(u64, V)> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some(x), Some(y)) => Some(if x >= y { x } else { y }),
    }
}

/// Which post owns a media file that appears in several posts (e.g. the same image shared twice):
/// the smallest (post id, ordinal). A pure minimum, so every device picks the same owner.
pub fn merge_owner<P: Ord + Clone>(a: (P, i64), b: (P, i64)) -> (P, i64) { if a <= b { a } else { b } }

/// Export selection for one media: excluded tags always win; an empty include list means
/// "everything"; otherwise any live include tag selects the media. Tombstones (origin 0) are ignored.
pub fn export_selected<L: PartialEq>(tags: &[(L, u8)], include: &[L], exclude: &[L]) -> bool {
    let live = |l: &L| tags.iter().any(|(t, o)| t == l && *o != 0);
    if exclude.iter().any(|l| live(l)) { return false; }
    include.is_empty() || include.iter().any(|l| live(l))
}

/// A media counts as "reviewed" once any live tag on it carries the USER bit: a tag you added
/// yourself or an AI tag you endorsed.
pub fn reviewed<L>(tags: &[(L, u8)]) -> bool { tags.iter().any(|(_, o)| o & USER != 0) }

// ---------- search ----------

/// The tag origins a search counts (1 = only mine, 2 = only the AI's, 3 = both), from its
/// scope mask (1 = mine, 2 = AI, 3 = either, 4 = both together) minus the origins written with
/// a minus: "-我的" takes away every tag I added or endorsed, "-AI" every tag the AI gave,
/// "-共同" the tags both of us gave.
pub fn origins_for(scope_mask: u8, exclude_mine: bool, exclude_ai: bool, exclude_common: bool) -> Vec<u8> {
    [1u8, 2, 3].into_iter().filter(|&o| {
        let allowed = if scope_mask == 4 { o == 3 } else { o & scope_mask & 3 != 0 };
        allowed && !(exclude_mine && o & USER != 0) && !(exclude_ai && o & AI != 0) && !(exclude_common && o == 3)
    }).collect()
}

/// What a search with plain "contains" matching selects (the SQL of `Store::feed_filtered` with
/// the label sets "every label containing the word"): every word occurs in at least one searched
/// field, and no excluded word occurs in any. Tags count only with an allowed origin; text and
/// author compare ASCII-lowercased, as SQLite's `lower` does. With neither text nor author
/// searched, the tags are.
pub fn search_matches(fields: (bool, bool, bool), origins: &[u8], tags: &[(&str, u8)], text: &str, author: &[&str], terms: &[&str], exclude: &[&str]) -> bool {
    let (tags_on, text_on, author_on) = if !fields.1 && !fields.2 { (true, false, false) } else { fields };
    let hit = |w: &str| {
        (tags_on && tags.iter().any(|(l, o)| origins.contains(&(o & 3)) && l.contains(w)))
            || (text_on && text.to_ascii_lowercase().contains(w))
            || (author_on && author.iter().any(|a| a.to_ascii_lowercase().contains(w)))
    };
    terms.iter().all(|w| hit(w)) && !exclude.iter().any(|w| hit(w))
}

/// Review filter of the feed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Review { #[default] Any, Unreviewed, Reviewed }

pub fn review_matches<L>(tags: &[(L, u8)], r: Review) -> bool {
    match r { Review::Any => true, Review::Unreviewed => !reviewed(tags), Review::Reviewed => reviewed(tags) }
}

// ---------- folders ----------

/// Which media an import (or download) into a folder puts there: every live media of every post
/// the import touched — also media of those posts that were already in the library and are not
/// in this import — and every live file of the import itself, even one that belongs to another
/// post. `media = (post index, live, file was in this import)`; `touched[p]` = import touched post p.
pub fn import_folder_member(media: (usize, bool, bool), touched: &[bool]) -> bool {
    media.1 && (media.2 || (media.0 < touched.len() && touched[media.0]))
}

/// AI analysis attempts after which this device stops trying a media (another device still can).
pub const MAX_AI_ATTEMPTS: i64 = 2;

/// Whether this device skips a media for now: it failed `MAX_AI_ATTEMPTS` times here, or once
/// during the current run (the SQL in `Store::media_needing_ai_for` is the same condition).
/// `failed_at`/`run_start` are 0 when unknown.
pub fn ai_skip(attempts: i64, failed_at: i64, run_start: i64) -> bool {
    attempts >= MAX_AI_ATTEMPTS || (attempts > 0 && run_start > 0 && failed_at >= run_start)
}



// ---------- tag renaming ----------

/// Resolves a tag through rename rules: `next[i]` is the rule "label i is now called next[i]".
/// Chains are followed to their end. Concurrent renames can form a cycle (A→B on one device,
/// B→A on another); then every member resolves to the smallest label of the cycle, so all
/// devices pick the same name whatever order the rules arrived in. Heap-free and bounded
/// (at most `next.len()` steps per walk) so the model checker covers it exhaustively.
pub fn resolve_alias(start: usize, next: &[Option<usize>]) -> usize {
    let n = next.len();
    let mut cur = start;
    let mut steps = 0;
    while steps < n {
        match next[cur] { None => return cur, Some(x) => { cur = x; steps += 1; } }
    }
    // n steps without reaching an end: `cur` lies on a cycle; return its smallest member.
    let mut m = cur;
    let mut x = next[cur].unwrap_or(cur);
    let mut guard = 0;
    while x != cur && guard < n { if x < m { m = x; } x = next[x].unwrap_or(cur); guard += 1; }
    m
}

/// Rename-rule register: LWW over (clock, target); `None` = no rule (renaming undone).
pub fn merge_alias<V: Ord + Clone>(a: (u64, Option<V>), b: (u64, Option<V>)) -> (u64, Option<V>) { if a >= b { a } else { b } }

// ---------- file content sniffing ----------

/// What a file's first bytes say it is. Imports and downloads check content, never trust the
/// extension: a downloader may save an HTML error page as "photo.jpg".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sniff { Jpeg, Png, Gif, Webp, Heif, Mp4, Mov, Html, Text, Empty, Unknown }

/// ISO-BMFF brands of still images (HEIC / HEIF / AVIF, as saved by iPhone cameras and Photos).
fn heif_brand(b: &[u8]) -> bool {
    matches!(b, b"heic" | b"heix" | b"heim" | b"heis" | b"hevc" | b"hevx" | b"mif1" | b"msf1" | b"avif" | b"avis")
}

/// First-box types of QuickTime movies written without an `ftyp` box (older cameras, some editors).
fn qt_box(b: &[u8]) -> bool { matches!(b, b"moov" | b"mdat" | b"wide" | b"free" | b"skip" | b"pnot") }

/// Classifies a file by its first bytes (pass at least 12 when the file has them).
pub fn sniff(h: &[u8]) -> Sniff {
    let n = h.len();
    if n == 0 { return Sniff::Empty; }
    if n >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF { return Sniff::Jpeg; }
    if n >= 8 && h[0] == 0x89 && h[1] == b'P' && h[2] == b'N' && h[3] == b'G' && h[4] == 0x0D && h[5] == 0x0A && h[6] == 0x1A && h[7] == 0x0A { return Sniff::Png; }
    if n >= 6 && h[0] == b'G' && h[1] == b'I' && h[2] == b'F' && h[3] == b'8' && (h[4] == b'7' || h[4] == b'9') && h[5] == b'a' { return Sniff::Gif; }
    if n >= 12 && h[0] == b'R' && h[1] == b'I' && h[2] == b'F' && h[3] == b'F' && h[8] == b'W' && h[9] == b'E' && h[10] == b'B' && h[11] == b'P' { return Sniff::Webp; }
    // ISO-BMFF: a small first box (size < 64 KiB, so its two high bytes are 0) of type `ftyp`;
    // the major brand tells HEIC/AVIF stills, QuickTime movies and MP4 apart
    if n >= 8 && h[0] == 0 && h[1] == 0 && h[4] == b'f' && h[5] == b't' && h[6] == b'y' && h[7] == b'p' {
        if n >= 12 && heif_brand(&h[8..12]) { return Sniff::Heif; }
        if n >= 12 && &h[8..12] == b"qt  " { return Sniff::Mov; }
        return Sniff::Mp4;
    }
    // QuickTime without `ftyp`: a known first box whose 32-bit size is 1 (64-bit size follows) or ≥ 8
    if n >= 8 && qt_box(&h[4..8]) && h[0] == 0 && (h[1] != 0 || h[2] != 0 || h[3] == 1 || h[3] >= 8) { return Sniff::Mov; }
    // skip a UTF-8 BOM and leading whitespace, then look for markup
    let mut i = 0;
    if n >= 3 && h[0] == 0xEF && h[1] == 0xBB && h[2] == 0xBF { i = 3; }
    while i < n && (h[i] == b' ' || h[i] == b'\t' || h[i] == b'\r' || h[i] == b'\n') { i += 1; }
    if i < n && h[i] == b'<' { return Sniff::Html; }
    let mut text = true;
    let mut k = i;
    while k < n { let c = h[k]; if c < 0x09 || (c > 0x0D && c < 0x20) { text = false; } k += 1; }
    if text { Sniff::Text } else { Sniff::Unknown }
}

/// Whether a sniffed file may be stored as a photo / as a video (MP4 or QuickTime).
pub fn sniff_ok(s: Sniff, photo: bool) -> bool {
    if photo { matches!(s, Sniff::Jpeg | Sniff::Png | Sniff::Gif | Sniff::Webp | Sniff::Heif) } else { matches!(s, Sniff::Mp4 | Sniff::Mov) }
}

/// Whether a stored file (by its blob path) holds a video.
pub fn is_video_path(rel: &str) -> bool {
    let r = rel.as_bytes();
    let n = r.len();
    n >= 4 && r[n - 4] == b'.' && ((r[n - 3] | 0x20 == b'm' && r[n - 2] | 0x20 == b'p' && r[n - 1] == b'4') || (r[n - 3] | 0x20 == b'm' && r[n - 2] | 0x20 == b'o' && r[n - 1] | 0x20 == b'v'))
}

// ---------- "最近添加" (recently added) ----------

/// A post batch-downloaded from a bookmarks JSON carries the time it was added. The mark is a
/// grow-only register (merge = max), so it never needs a deletion op: every device decides from
/// its own clock whether the mark is still active, and nothing has to be synced when it expires.
pub const RECENT_MS: u64 = 5 * 86_400_000;
/// Marks more than a day ahead of this device's clock (a peer with a wrong clock) are ignored.
pub const RECENT_MAX_FUTURE_MS: u64 = 86_400_000;

pub fn merge_recent(a: u64, b: u64) -> u64 { if a >= b { a } else { b } }

/// Whether a mark made at `at` (ms, 0 = none) is shown at `now`.
pub fn recent_active(at: u64, now: u64) -> bool {
    at != 0 && at <= now.saturating_add(RECENT_MAX_FUTURE_MS) && now < at.saturating_add(RECENT_MS)
}

// ---------- import records, backup restore, download jobs ----------

/// A path (as components) lies strictly inside a root (the root itself never does). Deleting an
/// import record deletes its source only when this holds for one of the app's own folders.
pub fn strictly_inside<T: PartialEq>(path: &[T], root: &[T]) -> bool {
    path.len() > root.len() && path[..root.len()] == root[..]
}

/// Backup restore: a media the backup had in the bin goes back into the bin only when this
/// library has never seen it — a restore never bins something that exists here.
pub fn restore_to_bin(trashed_in_backup: bool, row_here: bool, reg_here: TrashReg) -> bool {
    trashed_in_backup && !row_here && reg_here == TrashReg::default()
}

/// A download worker finishing a link marks it done only when nobody asked for it again since
/// the worker started it (each request bumps the epoch); otherwise it stays queued.
pub fn job_finishes(epoch_now: i64, epoch_started: i64) -> bool { epoch_now == epoch_started }

// ---------- recycle bin ----------

pub const LIVE: u8 = 0;
pub const TRASHED: u8 = 1;
pub const PURGED: u8 = 2;

/// Recycle-bin register of one media. Field order is the merge order: (incarnation, state, clock).
/// Within an incarnation the state only moves forward, Live → Trashed → Purged; restoring or
/// re-importing starts a new incarnation. So the merge (the lexicographic maximum) is a
/// semilattice, a permanent deletion is final for its incarnation, and a stale or concurrent
/// delete from another device can never undo a restore.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct TrashReg { pub inc: u32, pub state: u8, pub hlc: u64 }

pub fn merge_trash(a: TrashReg, b: TrashReg) -> TrashReg { if a >= b { a } else { b } }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrashAction {
    /// Move a live media to the recycle bin.
    Trash,
    /// Bring a media back from the recycle bin.
    Restore,
    /// Delete a media in the recycle bin permanently (its file is removed on every device).
    Purge,
    /// The user explicitly imported or downloaded the file again: it comes back even after a purge.
    Reimport,
}

/// The local state change for an action, or None when the action does not apply.
/// `hlc` is a fresh clock value (greater than any clock seen so far).
pub fn trash_step(cur: TrashReg, a: TrashAction, hlc: u64) -> Option<TrashReg> {
    match (a, cur.state) {
        (TrashAction::Trash, LIVE) => Some(TrashReg { inc: cur.inc, state: TRASHED, hlc }),
        (TrashAction::Purge, TRASHED) => Some(TrashReg { inc: cur.inc, state: PURGED, hlc }),
        (TrashAction::Restore, TRASHED) | (TrashAction::Reimport, TRASHED | PURGED) =>
            Some(TrashReg { inc: cur.inc.checked_add(1)?, state: LIVE, hlc }),
        _ => None,
    }
}

/// Whether a trashed media is due for automatic deletion. `keep_ms == 0` means never.
/// The time a media entered the bin is the wall-clock part of its clock (ms << 16).
pub fn trash_expired(r: TrashReg, now_ms: u64, keep_ms: u64) -> bool {
    r.state == TRASHED && keep_ms > 0 && now_ms.saturating_sub(r.hlc >> 16) >= keep_ms
}

/// Clock difference to a peer worth warning about (the recycle bin and LWW use wall time).
pub const SKEW_WARN_MS: i64 = 5 * 60 * 1000;
pub fn skew_warning(mine_ms: u64, theirs_ms: u64) -> bool {
    theirs_ms != 0 && (theirs_ms as i128 - mine_ms as i128).abs() > SKEW_WARN_MS as i128
}

/// For one device's log: the sequence range the peer is missing, as (first, last) inclusive.
pub fn missing_range(mine_max: i64, theirs_have: i64) -> Option<(i64, i64)> {
    (mine_max > theirs_have).then(|| (theirs_have.max(0) + 1, mine_max))
}

/// Version-vector entry after receiving an op with `seq` (vectors only grow).
pub fn vv_advance(have: i64, seq: i64) -> i64 { have.max(seq) }

/// What to do with a received op of a device whose log here ends at `have`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeqVerdict { Duplicate, Next, Gap }

/// Each device's log is kept contiguous (1, 2, 3, …): only the next number is applied. A gap
/// or a forged number (say `i64::MAX`) is refused, so a peer can never make this device skip
/// another device's ops or exhaust its own numbering. Peers send ops in order from our
/// version vector, so honest traffic is always `Next` or `Duplicate`.
pub fn accept_seq(have: i64, seq: i64) -> SeqVerdict {
    if seq <= have { SeqVerdict::Duplicate } else if have.checked_add(1) == Some(seq) { SeqVerdict::Next } else { SeqVerdict::Gap }
}

/// Device ids are generated as 16 hex digits; accept short ids of letters, digits, '-' and '_'.
pub fn valid_device_id(d: &[u8]) -> bool {
    if d.is_empty() || d.len() > 64 { return false; }
    let mut i = 0;
    while i < d.len() { if !(d[i].is_ascii_alphanumeric() || d[i] == b'-' || d[i] == b'_') { return false; } i += 1; }
    true
}

/// A media id is the SHA-256 of its file in lowercase hex (64 characters).
pub fn valid_blob_id(id: &[u8]) -> bool {
    if id.len() != 64 { return false; }
    let mut i = 0;
    while i < id.len() { if !(id[i].is_ascii_digit() || (b'a'..=b'f').contains(&id[i])) { return false; } i += 1; }
    true
}

/// A stored file's extension: 1–8 ASCII letters or digits (no separator, dot or NUL).
pub fn valid_ext(e: &[u8]) -> bool {
    if e.is_empty() || e.len() > 8 { return false; }
    let mut i = 0;
    while i < e.len() { if !e[i].is_ascii_alphanumeric() { return false; } i += 1; }
    true
}

/// A media path inside the library as stored in the database: `blobs/<2 hex>/<id>.<ext>`.
/// Anything else is never opened or deleted (an older or forged row cannot point outside).
pub fn is_blob_path(p: &[u8]) -> bool {
    // "blobs/" + 2 + "/" + 64 + "." + ext
    if p.len() < 6 + 2 + 1 + 64 + 1 + 1 || p.len() > 6 + 2 + 1 + 64 + 1 + 8 { return false; }
    if &p[..6] != b"blobs/" || p[8] != b'/' || p[73] != b'.' { return false; }
    let id = &p[9..73];
    valid_blob_id(id) && p[6] == id[0] && p[7] == id[1] && valid_ext(&p[74..])
}

/// Media are fetched from X's media servers only (`https://…twimg.com/…`): an answer from the
/// mirror or the Cookie module that points anywhere else (a local address, another site) is refused.
pub fn media_url_ok(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    // no user info or port tricks: the host part is plain letters, digits, dots and dashes
    if host.is_empty() || !host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') { return false; }
    let host = host.to_ascii_lowercase();
    host == "twimg.com" || host.ends_with(".twimg.com")
}

/// How far in the future a peer's clock may be before it is ignored for our own clock: a device
/// with a wrong date (or a forged op) must not push this device's clock to the end of time,
/// which would make every later local edit tie or lose.
pub const MAX_FUTURE_MS: u64 = 24 * 60 * 60 * 1000;
pub fn hlc_ceiling(now_ms: u64) -> u64 { now_ms.saturating_add(MAX_FUTURE_MS).saturating_mul(1 << 16) | 0xFFFF }

/// Our clock after seeing a remote one: it moves forward to it only within the ceiling.
/// Applied before materializing a remote LWW write, not merely before observing its clock.
/// Future records stay pending: dropping them based on local wall time would break convergence.
pub fn remote_clock_ready(remote: u64, now_ms: u64) -> bool {
    remote < u64::MAX && remote <= hlc_ceiling(now_ms)
}
pub fn observe_clock(last: u64, remote: u64, now_ms: u64) -> u64 {
    if remote > last && remote <= hlc_ceiling(now_ms) { remote } else { last }
}

/// Path sanitizer for archive entries, over raw bytes: returns the normalized relative path
/// (empty and "." components dropped) or None when the entry is absolute, contains a `..`
/// component, a NUL or a backslash, or normalizes to nothing. Written as a plain index scan so
/// the model checker can explore it exhaustively.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Component { Skip, Keep, Reject }

/// Classifies one path component (the bytes between two '/'): empty and "." are skipped,
/// ".." or anything containing NUL or a backslash rejects the whole path.
pub fn classify_component(c: &[u8]) -> Component {
    let mut i = 0;
    while i < c.len() {
        if c[i] == 0 || c[i] == b'\\' || c[i] == b'/' { return Component::Reject; }
        i += 1;
    }
    match c.len() {
        0 => Component::Skip,
        1 if c[0] == b'.' => Component::Skip,
        2 if c[0] == b'.' && c[1] == b'.' => Component::Reject,
        _ => Component::Keep,
    }
}

pub fn safe_relative_bytes(p: &[u8]) -> Option<Vec<u8>> {
    if p.first() == Some(&b'/') { return None; }
    let mut out: Vec<u8> = Vec::with_capacity(p.len());
    let mut i = 0;
    while i < p.len() {
        let start = i;
        while i < p.len() && p[i] != b'/' { i += 1; }
        match classify_component(&p[start..i]) {
            Component::Reject => return None,
            Component::Skip => {}
            Component::Keep => {
                if !out.is_empty() { out.push(b'/'); }
                out.extend_from_slice(&p[start..i]);
            }
        }
        i += 1; // skip the separator
    }
    if out.is_empty() { None } else { Some(out) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retag_keeps_user_and_endorsed() {
        let existing = [("墙", AI), ("猫", USER | AI), ("我的", USER), ("天空", AI)];
        let plan = retag_plan(&existing, &["天空", "海"], true);
        let after = apply_plan(&existing, &plan);
        let get = |l: &str| after.iter().find(|(x, _)| *x == l).map(|(_, o)| *o);
        assert_eq!(get("墙"), Some(0), "unendorsed old AI tag removed");
        assert_eq!(get("猫"), Some(3), "endorsed kept");
        assert_eq!(get("我的"), Some(1), "user tag kept");
        assert_eq!(get("天空"), Some(AI));
        assert_eq!(get("海"), Some(AI));
        let keep = apply_plan(&existing, &retag_plan(&existing, &["海"], false));
        assert_eq!(keep.iter().find(|(x, _)| *x == "墙").unwrap().1, AI, "nothing removed without replace");
    }

    #[test]
    fn export_exclude_wins() {
        let tags = [("A", USER), ("B", AI)];
        assert!(export_selected(&tags, &["A"], &[]));
        assert!(!export_selected(&tags, &["A"], &["B"]));
        assert!(export_selected(&tags, &[], &[]));
        assert!(!export_selected(&[("A", 0u8)], &["A"], &[]), "tombstone is not a tag");
    }

    #[test]
    fn alias_resolution() {
        // 0→1→2, 3 alone
        assert_eq!(resolve_alias(0, &[Some(1), Some(2), None, None]), 2);
        assert_eq!(resolve_alias(3, &[Some(1), Some(2), None, None]), 3);
        // concurrent opposite renames: 1↔2 → both resolve to 1
        assert_eq!(resolve_alias(2, &[None, Some(2), Some(1), None]), 1);
        assert_eq!(resolve_alias(1, &[None, Some(2), Some(1), None]), 1);
        // a tail into a cycle
        assert_eq!(resolve_alias(0, &[Some(3), None, Some(3), Some(2)]), 2);
    }

    #[test]
    fn sniffing() {
        assert_eq!(sniff(b"<!DOCTYPE html><html>"), Sniff::Html);
        assert_eq!(sniff(b"\xEF\xBB\xBF  <html>"), Sniff::Html);
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), Sniff::Jpeg);
        assert_eq!(sniff(b"\0\0\0\x18ftypisom"), Sniff::Mp4);
        assert_eq!(sniff(b"\0\0\0\x18ftypheic\0\0\0\0"), Sniff::Heif);
        assert_eq!(sniff(b"\0\0\0\x1cftypmif1\0\0\0\0"), Sniff::Heif);
        assert_eq!(sniff(b"\0\0\0\x14ftypqt  \0\0\0\0"), Sniff::Mov);
        assert_eq!(sniff(b"\0\0\0\x08wide\0\0\0\0"), Sniff::Mov);
        assert_eq!(sniff(b"\0\0\0\x00wide"), Sniff::Unknown, "a zero-size box is not a movie");
        assert!(sniff_ok(Sniff::Heif, true) && !sniff_ok(Sniff::Heif, false));
        assert!(sniff_ok(Sniff::Mov, false) && !sniff_ok(Sniff::Mov, true));
        assert!(is_video_path("blobs/ab/x.mp4") && is_video_path("blobs/ab/x.mov") && is_video_path("x.MOV"));
        assert!(!is_video_path("x.heic") && !is_video_path("x.jpg") && !is_video_path("mp4"));
        assert_eq!(sniff(b""), Sniff::Empty);
        assert_eq!(sniff(b"hello"), Sniff::Text);
        assert!(!sniff_ok(sniff(b"<!DOCTYPE html>"), true));
    }

    #[test]
    fn paths() {
        assert_eq!(safe_relative_bytes(b"a/./b//c").unwrap(), b"a/b/c");
        assert!(safe_relative_bytes(b"../x").is_none());
        assert!(safe_relative_bytes(b"/etc").is_none());
        assert!(safe_relative_bytes(b"a/../../b").is_none());
        assert!(safe_relative_bytes(b"./").is_none());
    }
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    fn channel_nonces_never_wrap_or_repeat() {
        let initial: u64 = kani::any();
        let mut counter = initial;
        let first = take_channel_nonce(&mut counter);
        if initial == u64::MAX {
            assert_eq!(first, None);
            assert_eq!(counter, initial);
            assert_eq!(take_channel_nonce(&mut counter), None);
        } else {
            assert_eq!(first, Some(initial));
            assert_eq!(counter, initial + 1);
            if let Some(second) = take_channel_nonce(&mut counter) {
                assert!(second > initial);
            } else {
                assert_eq!(initial, u64::MAX - 1);
            }
        }
    }

    /// Up to three tag registers with distinct labels from {0..3} and any origin 0…3 (no heap).
    fn any_table() -> [(u8, u8); 3] {
        let t: [(u8, u8); 3] = [(kani::any(), kani::any()), (kani::any(), kani::any()), (kani::any(), kani::any())];
        for (l, o) in t.iter() { kani::assume(*l < 4 && *o <= 3); }
        kani::assume(t[0].0 != t[1].0 && t[0].0 != t[2].0 && t[1].0 != t[2].0);
        t
    }

    #[kani::proof]
    fn retag_rule_never_removes_user_bits() {
        let cur: u8 = kani::any();
        kani::assume(cur <= 3);
        let proposed: bool = kani::any();
        let replace: bool = kani::any();
        let next = retag_origin(cur, proposed, replace);
        assert!(next <= 3);
        // Your own tags and endorsed AI tags keep the USER bit.
        if cur & USER != 0 { assert!(next & USER != 0); }
        // Without replace, origins only grow.
        if !replace { assert!(next & cur == cur); }
        // Proposed labels carry the AI bit.
        if proposed { assert!(next & AI != 0); }
        // Only unendorsed AI-only tags are ever removed, and only with replace.
        if next == 0 && cur != 0 { assert!(cur == AI && replace && !proposed); }
    }

    #[kani::proof]
    fn retag_rule_is_idempotent() {
        let cur: u8 = kani::any();
        kani::assume(cur <= 3);
        let proposed: bool = kani::any();
        let replace: bool = kani::any();
        let once = retag_origin(cur, proposed, replace);
        assert_eq!(retag_origin(once, proposed, replace), once);
    }

    #[kani::proof]
    #[kani::unwind(6)]
    fn export_selection_rules() {
        let tags = any_table();
        let inc: [u8; 1] = [kani::any()];
        let exc: [u8; 1] = [kani::any()];
        let sel = export_selected(&tags, &inc, &exc);
        let live = |l: u8| tags.iter().any(|(t, o)| *t == l && *o != 0);
        // Exclusion dominates.
        if live(exc[0]) { assert!(!sel); }
        // Selected media always carries an include tag and no exclude tag.
        if sel { assert!(live(inc[0]) && !live(exc[0])); }
        // Without filters everything is exported.
        assert!(export_selected(&tags, &[] as &[u8], &[] as &[u8]));
        // Adding an exclusion can only shrink the selection.
        if export_selected(&tags, &inc, &exc) { assert!(export_selected(&tags, &inc, &[] as &[u8])); }
    }

    #[kani::proof]
    fn post_field_merge_is_a_semilattice() {
        let pick = || -> Option<(u64, u8)> { if kani::any() { Some((kani::any(), kani::any())) } else { None } };
        let (a, b, c) = (pick(), pick(), pick());
        assert_eq!(merge_field(a, b), merge_field(b, a));
        assert_eq!(merge_field(merge_field(a, b), c), merge_field(a, merge_field(b, c)));
        assert_eq!(merge_field(a, a), a);
        // a present value is never erased by an absent one, and the result is one of the inputs
        if a.is_some() { assert!(merge_field(a, None).is_some()); }
        let m = merge_field(a, b);
        assert!(m == a || m == b);
    }

    #[kani::proof]
    fn media_owner_merge_is_a_semilattice() {
        let a: (u8, i64) = (kani::any(), kani::any());
        let b: (u8, i64) = (kani::any(), kani::any());
        let c: (u8, i64) = (kani::any(), kani::any());
        assert_eq!(merge_owner(a, b), merge_owner(b, a));
        assert_eq!(merge_owner(merge_owner(a, b), c), merge_owner(a, merge_owner(b, c)));
        assert_eq!(merge_owner(a, a), a);
        let m = merge_owner(a, b);
        assert!((m == a || m == b) && m <= a && m <= b);
    }


    /// "最近添加": the mark merges as a semilattice (sync order never matters), is active only
    /// inside its window, and once expired it stays expired until a newer mark arrives; a newer
    /// mark from a sane clock never hides an older active one.
    #[kani::proof]
    fn recent_mark_rules() {
        let (a, b, c, now, later): (u64, u64, u64, u64, u64) = (kani::any(), kani::any(), kani::any(), kani::any(), kani::any());
        assert_eq!(merge_recent(a, b), merge_recent(b, a));
        assert_eq!(merge_recent(merge_recent(a, b), c), merge_recent(a, merge_recent(b, c)));
        assert_eq!(merge_recent(a, a), a);
        let m = merge_recent(a, b);
        assert!(m == a || m == b);
        assert!(m >= a && m >= b);
        if recent_active(a, now) {
            assert!(a != 0);
            assert!(now < a.saturating_add(RECENT_MS));
            assert!(a <= now.saturating_add(RECENT_MAX_FUTURE_MS));
        }
        // expired stays expired
        if a != 0 && now >= a.saturating_add(RECENT_MS) && later >= now { assert!(!recent_active(a, later)); }
        // merging in a mark that is not from the future keeps an active mark active
        if recent_active(a, now) && b <= now { assert!(recent_active(merge_recent(a, b), now)); }
        // a fresh mark made now is active now, and for the whole window
        if now != 0 && now < u64::MAX - RECENT_MS { assert!(recent_active(now, now)); assert!(recent_active(now, now + RECENT_MS - 1)); assert!(!recent_active(now, now + RECENT_MS)); }
        // no mark, nothing shown
        assert!(!recent_active(0, now));
    }

    /// Deleting records: only strictly inside an owned folder, never the folder itself, never a
    /// path that merely shares a name prefix with it.
    #[kani::proof]
    #[kani::unwind(6)]
    fn record_deletion_stays_inside_owned_folders() {
        let p: [u8; 4] = kani::any(); let r: [u8; 4] = kani::any();
        let (pn, rn): (usize, usize) = (kani::any(), kani::any());
        kani::assume(pn <= 4 && rn <= 4 && rn >= 1);
        let (path, root) = (&p[..pn], &r[..rn]);
        if strictly_inside(path, root) {
            assert!(path.len() > root.len());
            assert!(path != root);
            assert!(!strictly_inside(root, path));
            let mut i = 0; while i < rn { assert!(path[i] == root[i]); i += 1; }
        }
        assert!(!strictly_inside(root, root));
    }

    /// A backup restore never puts into the bin a media that exists in this library; a
    /// re-request of a download link made while it runs is never lost.
    #[kani::proof]
    fn restore_and_job_rules() {
        let reg = TrashReg { inc: kani::any(), state: kani::any(), hlc: kani::any() };
        let (t, row): (bool, bool) = (kani::any(), kani::any());
        if restore_to_bin(t, row, reg) { assert!(t && !row && reg.inc == 0 && reg.state == LIVE && reg.hlc == 0); }
        if row || reg != TrashReg::default() { assert!(!restore_to_bin(t, row, reg)); }
        let (start, k): (i64, i64) = (kani::any(), kani::any());
        kani::assume(start >= 0 && start < i64::MAX / 2 && k >= 0 && k < 1000);
        let now = start + k;   // k requests arrived while the worker ran
        assert_eq!(job_finishes(now, start), k == 0);
    }

    #[kani::proof]
    #[kani::unwind(6)]
    fn folder_rules() {
        // import into a folder: exactly the live media of touched posts
        let touched: [bool; 3] = [kani::any(), kani::any(), kani::any()];
        let post: usize = kani::any();
        let live: bool = kani::any();
        let imported: bool = kani::any();
        kani::assume(post < 3);
        let m = import_folder_member((post, live, imported), &touched);
        // never anything deleted or binned; always every imported file and every media of a touched post
        if m { assert!(live); }
        if live && (imported || touched[post]) { assert!(m); }
        if !imported && !touched[post] { assert!(!m); }
    }

    fn any_aliases() -> [Option<usize>; 4] {
        let mut a: [Option<usize>; 4] = [None; 4];
        for i in 0..4 { if kani::any() { let t: usize = kani::any(); kani::assume(t < 4); a[i] = Some(t); } }
        a
    }

    #[kani::proof]
    #[kani::unwind(10)]
    fn renames_resolve_consistently() {
        let next = any_aliases();
        let s: usize = kani::any();
        kani::assume(s < 4);
        let r = resolve_alias(s, &next);
        assert!(r < 4);
        // the result is final: resolving it again gives itself
        assert_eq!(resolve_alias(r, &next), r);
        // a rule never splits a tag: a label and its rename target resolve to the same name
        if let Some(t) = next[s] { assert_eq!(resolve_alias(t, &next), r); }
        // the result is the end of the chain, or the smallest member of a cycle
        match next[r] {
            None => {}
            Some(_) => { let mut x = next[r].unwrap(); let mut k = 0; while x != r && k < 4 { assert!(x > r); x = next[x].unwrap_or(r); k += 1; } }
        }
    }

    #[kani::proof]
    fn rename_rule_merge_is_a_semilattice() {
        let pick = || -> (u64, Option<u8>) { (kani::any(), if kani::any() { Some(kani::any()) } else { None }) };
        let (a, b, c) = (pick(), pick(), pick());
        assert_eq!(merge_alias(a, b), merge_alias(b, a));
        assert_eq!(merge_alias(merge_alias(a, b), c), merge_alias(a, merge_alias(b, c)));
        assert_eq!(merge_alias(a, a), a);
    }

    #[kani::proof]
    #[kani::unwind(14)]
    fn sniffed_media_really_has_its_signature() {
        let h: [u8; 12] = kani::any();
        let n: usize = kani::any();
        kani::assume(n <= 12);
        let b = &h[..n];
        let s = sniff(b);
        let ftyp = n >= 8 && b[0] == 0 && b[1] == 0 && b[4] == b'f' && b[5] == b't' && b[6] == b'y' && b[7] == b'p';
        if sniff_ok(s, true) {
            // an accepted photo starts with a JPEG, PNG, GIF or WebP signature, or is an ISO-BMFF
            // file whose major brand is a still-image brand
            assert!((n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) || (n >= 8 && b[0] == 0x89 && b[1] == b'P')
                || (n >= 6 && b[0] == b'G' && b[1] == b'I' && b[2] == b'F') || (n >= 12 && b[0] == b'R' && b[8] == b'W')
                || (ftyp && n >= 12 && heif_brand(&b[8..12])));
        }
        if sniff_ok(s, false) {
            // an accepted video is an ISO-BMFF file that is not a still image, or a QuickTime box
            assert!((ftyp && !(n >= 12 && heif_brand(&b[8..12]))) || (n >= 8 && b[0] == 0 && qt_box(&b[4..8])));
        }
        // a photo is never a video and vice versa
        assert!(!(sniff_ok(s, true) && sniff_ok(s, false)));
        // markup, text and empty files are never media
        if n > 0 && b[0] == b'<' { assert!(s == Sniff::Html && !sniff_ok(s, true) && !sniff_ok(s, false)); }
        if n == 0 { assert!(!sniff_ok(s, true) && !sniff_ok(s, false)); }
    }

    fn any_trash() -> TrashReg {
        let r = TrashReg { inc: kani::any(), state: kani::any(), hlc: kani::any() };
        kani::assume(r.state <= PURGED);
        r
    }

    #[kani::proof]
    fn trash_merge_is_a_semilattice() {
        let (a, b, c) = (any_trash(), any_trash(), any_trash());
        assert_eq!(merge_trash(a, b), merge_trash(b, a));
        assert_eq!(merge_trash(merge_trash(a, b), c), merge_trash(a, merge_trash(b, c)));
        assert_eq!(merge_trash(a, a), a);
        let m = merge_trash(a, b);
        assert!(m == a || m == b);
    }

    #[kani::proof]
    fn trash_steps_take_effect_and_restores_win() {
        let cur = any_trash();
        let h: u64 = kani::any();
        kani::assume(h > cur.hlc);
        let a = match kani::any::<u8>() % 4 { 0 => TrashAction::Trash, 1 => TrashAction::Restore, 2 => TrashAction::Purge, _ => TrashAction::Reimport };
        if let Some(n) = trash_step(cur, a, h) {
            // A local action is never undone by the state it was made from.
            assert!(n > cur && merge_trash(cur, n) == n && n.state <= PURGED);
            // Restore / re-import beat every write of the incarnation they came from (or older):
            // a concurrent or stale trash/purge from another device cannot undo them.
            if n.state == LIVE {
                let x = any_trash();
                kani::assume(x.inc <= cur.inc);
                assert_eq!(merge_trash(n, x), n);
            }
            // Only the bin can be purged; restore only applies to binned media.
            if a == TrashAction::Purge { assert!(cur.state == TRASHED); }
            if a == TrashAction::Restore { assert!(cur.state == TRASHED); }
            if a == TrashAction::Trash { assert!(cur.state == LIVE && n.inc == cur.inc); }
        } else {
            // Invalid actions change nothing (e.g. restoring a purged media; only re-import revives).
            // (or the incarnation counter is exhausted: 2^32 restores, unreachable in practice)
            assert!(match a { TrashAction::Trash => cur.state != LIVE, TrashAction::Purge => cur.state != TRASHED,
                TrashAction::Restore => cur.state != TRASHED || cur.inc == u32::MAX,
                TrashAction::Reimport => cur.state == LIVE || cur.inc == u32::MAX });
        }
    }

    #[kani::proof]
    fn purge_is_final_within_its_incarnation() {
        let p = any_trash();
        kani::assume(p.state == PURGED);
        let x = any_trash();
        kani::assume(x.inc <= p.inc);
        assert_eq!(merge_trash(p, x).state, PURGED);
        // and only an explicit re-import can follow it locally
        let h: u64 = kani::any();
        assert!(trash_step(p, TrashAction::Restore, h).is_none() && trash_step(p, TrashAction::Trash, h).is_none() && trash_step(p, TrashAction::Purge, h).is_none());
    }

    #[kani::proof]
    fn trash_expiry_rules() {
        let r = any_trash();
        let now: u64 = kani::any();
        let keep: u64 = kani::any();
        if trash_expired(r, now, keep) { assert!(r.state == TRASHED && keep > 0 && now >= (r.hlc >> 16)); }
        assert!(!trash_expired(r, now, 0));
        if r.state != TRASHED { assert!(!trash_expired(r, now, keep)); }
        // a longer retention never expires something a shorter one keeps
        let keep2: u64 = kani::any();
        if keep2 >= keep && keep > 0 && trash_expired(r, now, keep2) { assert!(trash_expired(r, now, keep)); }
    }

    #[kani::proof]
    #[kani::unwind(6)]
    fn review_filter_partitions() {
        let tags = any_table();
        let u = review_matches(&tags, Review::Unreviewed);
        let r = review_matches(&tags, Review::Reviewed);
        assert!(u != r, "every media is exactly one of reviewed / unreviewed");
        assert!(review_matches(&tags, Review::Any));
        assert_eq!(r, tags.iter().any(|(_, o)| o & USER != 0));
        let inc: [u8; 1] = [kani::any()];
        let exc: [u8; 1] = [kani::any()];
    }

    #[kani::proof]
    fn clock_skew_warning() {
        let a: u64 = kani::any();
        let b: u64 = kani::any();
        if a != 0 && b != 0 { assert_eq!(skew_warning(a, b), skew_warning(b, a)); }
        assert!(!skew_warning(a, 0), "no reading from the peer: no warning");
        if b != 0 { assert_eq!(skew_warning(a, b), a.abs_diff(b) > SKEW_WARN_MS as u64); }
    }

    #[kani::proof]
    fn scope_matching() {
        let o: u8 = kani::any();
        kani::assume(o <= 3);
        assert_eq!(scope_matches(o, 3), o != 0);
        if o == USER | AI { assert!(scope_matches(o, USER) && scope_matches(o, AI)); }
        assert!(!scope_matches(0, kani::any()));
    }

    #[kani::proof]
    fn contiguous_logs_only_take_the_next_number() {
        let have: i64 = kani::any();
        let seq: i64 = kani::any();
        kani::assume(have >= 0);
        match accept_seq(have, seq) {
            SeqVerdict::Next => { assert!(seq == have + 1); assert!(vv_advance(have, seq) == have + 1); }
            SeqVerdict::Duplicate => assert!(seq <= have),
            SeqVerdict::Gap => assert!(seq > have + 1 || (have == i64::MAX)),
        }
        // a forged huge number is never applied unless the log already reached the number before it
        if have < i64::MAX - 1 { assert!(accept_seq(have, i64::MAX) == SeqVerdict::Gap); }
    }

    #[kani::proof]
    #[kani::unwind(66)]
    fn valid_blob_paths_stay_inside_blobs() {
        let id: [u8; 64] = kani::any();
        let n: usize = kani::any();
        kani::assume(n >= 1 && n <= 8);
        let ext: [u8; 8] = kani::any();
        let ext = &ext[..n];
        if valid_blob_id(&id) && valid_ext(ext) {
            // every component is a plain name: no separator, no "..", no NUL
            assert!(classify_component(&id) == Component::Keep);
            assert!(classify_component(ext) == Component::Keep);
            assert!(classify_component(&id[..2]) == Component::Keep);
            let mut i = 0;
            while i < n { assert!(ext[i] != b'.' && ext[i] != b'/' && ext[i] != 0); i += 1; }
        }
        // a rejected id or extension can be anything: those are never turned into paths
    }

    #[kani::proof]
    #[kani::unwind(84)]
    fn stored_paths_are_recognized_exactly() {
        let p: [u8; 82] = kani::any();
        let n: usize = kani::any();
        kani::assume(n <= 82);
        let p = &p[..n];
        if is_blob_path(p) {
            assert!(&p[..6] == b"blobs/");
            let mut i = 6;
            // nothing after "blobs/" can climb out: the only separator is the one at index 8
            while i < n { assert!(p[i] != 0 && p[i] != b'\\' && (p[i] != b'/' || i == 8)); i += 1; }
            assert!(!(p[9] == b'.' && p[10] == b'.'));
        }
    }

    #[kani::proof]
    fn remote_clocks_are_bounded() {
        let last: u64 = kani::any();
        let remote: u64 = kani::any();
        let now: u64 = kani::any();
        kani::assume(now < 1 << 46);   // wall time in ms until ~4200 AD
        let n = observe_clock(last, remote, now);
        assert!(n >= last);
        assert!(n == last || (n == remote && n <= hlc_ceiling(now)));
        // a clock at u64::MAX from a peer never becomes ours (unless ours already was)
        if last < u64::MAX { assert!(observe_clock(last, u64::MAX, now) == last); }
    }

    /// Verifies the actual admission predicate used by Store::apply_op. The older
    /// observe_clock proof alone says nothing about materialized remote writes.
    #[kani::proof]
    fn remote_write_admission() {
        let remote: u64 = kani::any();
        let now: u64 = kani::any();
        let later: u64 = kani::any();
        assert!(!remote_clock_ready(u64::MAX, now));
        if remote_clock_ready(remote, now) {
            assert!(remote <= hlc_ceiling(now));
            if later >= now { assert!(remote_clock_ready(remote, later)); }
        }
        if remote > hlc_ceiling(now) { assert!(!remote_clock_ready(remote, now)); }
    }

    #[kani::proof]
    fn missing_range_exact() {
        let mine: i64 = kani::any();
        let have: i64 = kani::any();
        kani::assume(mine >= 0 && have >= 0);
        match missing_range(mine, have) {
            Some((a, b)) => { assert!(a == have + 1 && b == mine && a <= b); }
            None => assert!(mine <= have),
        }
        let s: i64 = kani::any();
        kani::assume(s >= 0);
        let n = vv_advance(have, s);
        assert!(n >= have && n >= s && (n == have || n == s));
    }

    #[kani::proof]
    #[kani::unwind(5)]
    fn path_components_are_classified_safely() {
        let c: [u8; 3] = kani::any();
        let n: usize = kani::any();
        kani::assume(n <= 3);
        let seg = &c[..n];
        match classify_component(seg) {
            Component::Keep => {
                // a kept component is never empty, ".", "..", and has no NUL, '\\' or '/'
                assert!(n > 0);
                assert!(!(n == 1 && seg[0] == b'.'));
                assert!(!(n == 2 && seg[0] == b'.' && seg[1] == b'.'));
                for b in seg { assert!(*b != 0 && *b != b'\\' && *b != b'/'); }
            }
            Component::Skip => assert!(n == 0 || (n == 1 && seg[0] == b'.')),
            Component::Reject => {
                assert!((n == 2 && seg[0] == b'.' && seg[1] == b'.') || seg.iter().any(|b| *b == 0 || *b == b'\\' || *b == b'/'));
            }
        }
    }
}

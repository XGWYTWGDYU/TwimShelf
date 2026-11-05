//! Replicated operation log. Each device appends ops under (device, seq); peers exchange
//! the ops the other lacks according to version vectors, and every device materializes
//! state by applying ops idempotently. Post upserts merge field-wise (non-null wins),
//! media rows are insert-once (content-addressed), tags use one LWW register per origin bit (`crdt::merge_bits`).
use crate::crdt::TagReg;
use crate::model::{MediaKind, PostMeta};
use crate::store::Store;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Op {
    /// Post metadata; each present field is a LWW register stamped with `hlc`.
    Post { meta: PostMeta, #[serde(default)] hlc: u64 },
    Media { id: String, post_id: String, ordinal: i64, kind: MediaKind, ext: String },
    /// `mask`: the origin bits this write sets (1 USER, 2 AI); absent in older records = both.
    Tag { media_id: String, label: String, origin: u8, #[serde(default = "both_bits", skip_serializing_if = "is_both_bits")] mask: u8, hlc: u64 },
    /// Provenance: `model` proposed (present) or no longer proposes `label` for a media.
    TagSrc { media_id: String, label: String, model: String, present: bool, hlc: u64 },
    /// A media was analysed by a model (grow-only).
    AiDone { media_id: String, model: String },
    /// Recycle-bin register of a media (`rules::merge_trash`): incarnation, state, clock.
    Trash { media_id: String, inc: u32, state: u8, hlc: u64 },
    /// Rename rule: label `src` is shown as `dst` (None = rule removed). LWW register.
    Alias { src: String, dst: Option<String>, hlc: u64 },
    /// Folder register (deleted or not) and folder membership register of a media. LWW.
    Folder { name: String, deleted: bool, hlc: u64 },
    FolderMedia { folder: String, media_id: String, present: bool, hlc: u64 },
    /// "最近添加" mark of a post: wall-clock ms when it was batch-downloaded (grow-only, max).
    Recent { post_id: String, at: u64 },
    /// A media came in through a share extension (从相册导入); grow-only.
    Album { media_id: String },
    /// An app setting shared by every device (e.g. the AI prompt): a last-writer-wins register
    /// over (clock, value), `None` = back to the default (`rules::merge_alias`).
    Setting { key: String, value: Option<String>, hlc: u64 },
    /// A change made by a newer version of the app (its kind is unknown here). It is stored and
    /// passed on unchanged, so devices in between never lose it, and applied once this device
    /// is updated (`Store::retry_pending_ops`). Never created locally.
    #[serde(skip)]
    Unknown(serde_json::Value),
}

/// Kinds this version understands (the `t` field). A record of any other kind is a newer
/// app's and is kept as `Op::Unknown`; a record of a known kind that does not parse is an
/// error (never skipped silently).
pub const KNOWN_OPS: &[&str] = &["post", "media", "tag", "tagsrc", "aidone", "trash", "alias", "folder", "foldermedia", "recent", "setting", "album"];

/// Parses a stored or received record.
fn both_bits() -> u8 { 3 }
fn is_both_bits(m: &u8) -> bool { *m == 3 }

pub fn parse_op(v: serde_json::Value) -> Result<Op, String> {
    let kind = v.get("t").and_then(|t| t.as_str()).map(str::to_string);
    match kind {
        Some(k) if !KNOWN_OPS.contains(&k.as_str()) => Ok(Op::Unknown(v)),
        _ => serde_json::from_value::<Op>(v).map_err(|e| e.to_string()),
    }
}

/// The record as JSON (an unknown one exactly as it arrived).
pub fn op_value(op: &Op) -> serde_json::Value {
    match op { Op::Unknown(v) => v.clone(), o => serde_json::to_value(o).expect("known ops serialize") }
}

fn ser_op<S: serde::Serializer>(op: &Op, s: S) -> Result<S::Ok, S::Error> { op_value(op).serialize(s) }
fn de_op<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Op, D::Error> {
    parse_op(serde_json::Value::deserialize(d)?).map_err(serde::de::Error::custom)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LoggedOp { pub device: String, pub seq: i64, #[serde(serialize_with = "ser_op", deserialize_with = "de_op")] pub op: Op }

/// device → highest seq known. Logs are kept contiguous (`rules::accept_seq`), so this is
/// also the highest contiguous seq.
pub type VersionVector = BTreeMap<String, i64>;

impl Store {
    pub fn version_vector(&self) -> rusqlite::Result<VersionVector> {
        let mut st = self.conn().prepare("SELECT device, max(seq) FROM op GROUP BY device")?;
        let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect();
        v
    }

    /// Ops the holder of `theirs` is missing, in (device, seq) order, at most `limit`.
    pub fn ops_since(&self, theirs: &VersionVector, limit: usize) -> rusqlite::Result<Vec<LoggedOp>> {
        self.ops_since_until(theirs, &self.version_vector()?, limit)
    }

    pub fn ops_since_until(&self, theirs: &VersionVector, mine: &VersionVector, limit: usize) -> rusqlite::Result<Vec<LoggedOp>> {
        let mut out = vec![];
        let mut st = self.conn().prepare_cached("SELECT seq, body FROM op WHERE device=?1 AND seq>?2 AND seq<=?4 ORDER BY seq LIMIT ?3")?;
        for (dev, &max) in mine {
            let have = theirs.get(dev).copied().unwrap_or(0);
            let Some((first, _)) = crate::rules::missing_range(max, have) else { continue };
            let rows = st.query_map(params![dev, first - 1, (limit - out.len()) as i64, max], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
            for row in rows {
                let (seq, body) = row?;
                // Never skip an entry silently: the peer would advance past it and never get it.
                // Records of a newer app's kinds are passed on as they are.
                let op = serde_json::from_str::<serde_json::Value>(&body).map_err(|e| e.to_string()).and_then(parse_op).map_err(|e| rusqlite::Error::ToSqlConversionFailure(
                    tr!("oplog.damaged", dev = dev, seq = seq, e = e).into()))?;
                out.push(LoggedOp { device: dev.clone(), seq, op });
            }
            if out.len() >= limit { break; }
        }
        Ok(out)
    }

    /// Stores and applies remote ops. Media whose blob is not on disk are queued in `want_blob`.
    /// `blob_exists(id, ext)` tells whether the blob file is present.
    /// Ops are taken only as the next number of their device's log (see `rules::accept_seq`);
    /// duplicates are skipped and gaps or malformed device ids are refused (counted in the
    /// returned `Applied`, never applied).
    pub fn apply_remote(&self, ops: &[LoggedOp], blob_exists: impl Fn(&str, &str) -> bool) -> rusqlite::Result<usize> {
        Ok(self.apply_remote_counted(ops, blob_exists)?.applied)
    }

    pub fn apply_remote_counted(&self, ops: &[LoggedOp], blob_exists: impl Fn(&str, &str) -> bool) -> rusqlite::Result<Applied> {
        use crate::rules::{accept_seq, SeqVerdict};
        let tx = self.conn().unchecked_transaction()?;
        let mut out = Applied::default();
        let mut have: BTreeMap<String, i64> = BTreeMap::new();
        for lo in ops {
            if !crate::rules::valid_device_id(lo.device.as_bytes()) { out.refused += 1; continue; }
            let h = match have.get(&lo.device) {
                Some(h) => *h,
                None => self.conn().query_row("SELECT coalesce(max(seq),0) FROM op WHERE device=?1", [&lo.device], |r| r.get(0))?,
            };
            match accept_seq(h, lo.seq) {
                SeqVerdict::Duplicate => { have.insert(lo.device.clone(), h); continue; }
                SeqVerdict::Gap => { out.refused += 1; have.insert(lo.device.clone(), h); continue; }
                SeqVerdict::Next => {}
            }
            self.conn().execute("INSERT INTO op VALUES(?1,?2,?3)", params![lo.device, lo.seq, op_value(&lo.op).to_string()])?;
            have.insert(lo.device.clone(), lo.seq);
            out.applied += 1;
            if !self.apply_op(&lo.device, lo.seq, &lo.op, &blob_exists)? { out.invalid += 1; }
        }
        tx.commit()?;
        Ok(out)
    }

    /// Records of a newer app version stored here, not applied yet.
    pub fn pending_op_count(&self) -> rusqlite::Result<i64> { self.conn().query_row("SELECT count(*) FROM op_pending", [], |r| r.get(0)) }

    /// After an update: applies stored records whose kind this version now understands.
    pub fn retry_pending_ops(&self, blob_exists: impl Fn(&str, &str) -> bool) -> rusqlite::Result<usize> {
        let rows: Vec<(String, i64, String)> = {
            let mut st = self.conn().prepare("SELECT p.device, p.seq, o.body FROM op_pending p JOIN op o ON o.device=p.device AND o.seq=p.seq ORDER BY p.device, p.seq")?;
            let v = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_, _>>()?;
            v
        };
        let tx = self.conn().unchecked_transaction()?;
        let mut n = 0;
        for (dev, seq, body) in rows {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) else { continue };
            match parse_op(v) {
                Ok(Op::Unknown(_)) | Err(_) => continue,
                Ok(op) => {
                    self.conn().execute("DELETE FROM op_pending WHERE device=?1 AND seq=?2", params![dev, seq])?;
                    let _ = self.apply_op(&dev, seq, &op, &blob_exists)?;
                    if !self.conn().prepare_cached("SELECT 1 FROM op_pending WHERE device=?1 AND seq=?2")?.exists(params![dev, seq])? { n += 1; }
                }
            }
        }
        tx.commit()?;
        Ok(n)
    }

    /// Applies one record to the materialized state (idempotent). Returns false for a record
    /// that is stored (it is part of the device's log) but has no effect because it is invalid:
    /// a media whose id is not a SHA-256 or whose extension could form a path.
    fn apply_op(&self, device: &str, seq: i64, op: &Op, blob_exists: &impl Fn(&str, &str) -> bool) -> rusqlite::Result<bool> {
        {
            let clock = match op {
                Op::Post { hlc, .. } | Op::Tag { hlc, .. } | Op::TagSrc { hlc, .. } |
                Op::Trash { hlc, .. } | Op::Alias { hlc, .. } | Op::Folder { hlc, .. } |
                Op::FolderMedia { hlc, .. } | Op::Setting { hlc, .. } => Some(*hlc),
                _ => None,
            };
            if clock.is_some_and(|h| !crate::rules::remote_clock_ready(h, crate::store::now_ms())) {
                self.conn().execute("INSERT OR IGNORE INTO op_pending VALUES(?1,?2)", params![device, seq])?;
                return Ok(true);
            }
            match op {
                Op::Post { meta, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_post(meta, *hlc)?;
                    self.post_arrived(&meta.id, blob_exists)?;
                }
                Op::Media { id, ext, .. } if !crate::rules::valid_blob_id(id.as_bytes()) || !crate::rules::valid_ext(ext.as_bytes()) => return Ok(false),
                Op::Media { id, post_id, ordinal, kind, ext } => {
                    // every claim is kept; the owner is the smallest one whose post is known
                    self.add_claim(id, post_id, *ordinal)?;
                    // the file is already here (perhaps under another extension: the same content
                    // imported as .mov on one device and .mp4 on another): only the owner changes
                    let stored: bool = self.conn().prepare_cached("SELECT 1 FROM media WHERE id=?1")?.exists([id])?;
                    let owner = self.known_owner(id)?;
                    if stored {
                        self.refresh_owner(id)?;
                    } else if let (Some(o), true) = (owner, blob_exists(id, ext)) {
                        self.apply_media(id, &o.0, o.1, kind, &blob_rel(id, ext))?;
                    } else {
                        let k = if *kind == MediaKind::Video { "video" } else { "photo" };
                        // Keep the winning claim (smallest post, ordinal) while the blob is pending.
                        self.conn().execute("INSERT INTO want_blob VALUES(?1,?2,?3,?4,?5) ON CONFLICT(media_id) DO UPDATE SET post_id=excluded.post_id, ordinal=excluded.ordinal
                            WHERE (excluded.post_id, excluded.ordinal) < (want_blob.post_id, want_blob.ordinal)", params![id, post_id, ordinal, k, ext])?;
                    }
                }
                Op::Tag { media_id, label, origin, mask, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_tag(media_id, label, crate::crdt::TagBits::write(*origin, *mask, *hlc))?;
                }
                Op::TagSrc { media_id, label, model, present, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_tag_source(media_id, label, model, TagReg { origin: *present as u8, hlc: *hlc })?;
                }
                Op::AiDone { media_id, model } => self.apply_ai_done(media_id, model)?,
                Op::Folder { name, deleted, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_folder(name, TagReg { origin: *deleted as u8, hlc: *hlc })?;
                }
                Op::FolderMedia { folder, media_id, present, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_member(folder, media_id, TagReg { origin: *present as u8, hlc: *hlc })?;
                }
                Op::Recent { post_id, at } => self.apply_recent(post_id, *at)?,
                Op::Album { media_id } => self.apply_album(media_id)?,
                Op::Setting { key, value, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_setting(key, (*hlc, value.clone()))?;
                }
                Op::Alias { src, dst, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_alias(src, (*hlc, dst.clone()))?;
                }
                Op::Trash { media_id, inc, state, hlc } => {
                    self.observe_hlc(*hlc)?;
                    self.apply_trash(media_id, crate::rules::TrashReg { inc: *inc, state: (*state).min(crate::rules::PURGED), hlc: *hlc })?;
                }
                Op::Unknown(_) => { self.conn().execute("INSERT OR IGNORE INTO op_pending VALUES(?1,?2)", params![device, seq])?; }
            }
        }
        Ok(true)
    }

    /// A post became known here (it arrived from a peer, or was imported or downloaded here):
    /// claims on it that were recorded before it follow it. Stored media may get a smaller owner;
    /// awaited media whose file is already here appear (unless they were permanently deleted
    /// meanwhile). Remote and local arrival must do the same, or two devices with the same log
    /// would show a media under different posts.
    pub(crate) fn post_arrived(&self, post_id: &str, blob_exists: &dyn Fn(&str, &str) -> bool) -> rusqlite::Result<()> {
        let claimed: Vec<String> = {
            let mut st = self.conn().prepare_cached("SELECT DISTINCT media_id FROM media_claim WHERE post_id=?1")?;
            let v = st.query_map([post_id], |r| r.get(0))?.collect::<Result<_, _>>()?;
            v
        };
        for id in claimed {
            let stored: bool = self.conn().prepare_cached("SELECT 1 FROM media WHERE id=?1")?.exists([&id])?;
            if stored { self.refresh_owner(&id)?; continue; }
            // a permanently deleted media must not come back as a row (its file is removed)
            if self.trash_reg(&id)?.state == crate::rules::PURGED { continue; }
            use rusqlite::OptionalExtension;
            let w: Option<(String, String)> = self.conn().query_row("SELECT kind, ext FROM want_blob WHERE media_id=?1", [&id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
            if let (Some((kind, ext)), Some(owner)) = (w, self.known_owner(&id)?) {
                if blob_exists(&id, &ext) {
                    let kind = if kind == "video" { MediaKind::Video } else { MediaKind::Photo };
                    self.apply_media(&id, &owner.0, owner.1, &kind, &blob_rel(&id, &ext))?;
                }
            }
        }
        Ok(())
    }

    /// Blobs referenced by synced media ops that are not on disk yet: (id, ext).
    pub fn wanted_blobs(&self, limit: i64) -> rusqlite::Result<Vec<(String, String)>> {
        // Photos before videos: small files first make progress visible sooner. Permanently
        // deleted media are never requested; damaged local files are re-fetched from peers.
        // random order within each kind: entries that can never be served (a peer that no longer
        // has the file) cannot keep the rest waiting forever behind them
        let mut st = self.conn().prepare("SELECT media_id, ext FROM want_blob w WHERE NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=w.media_id AND x.state=2) ORDER BY kind='video', random() LIMIT ?1")?;
        let mut v: Vec<(String, String)> = st.query_map([limit], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        let mut st = self.conn().prepare("SELECT m.id, m.path FROM bad_media b JOIN media m ON m.id=b.media_id WHERE b.reason IN ('missing','hash') AND NOT EXISTS(SELECT 1 FROM trash x WHERE x.media_id=m.id AND x.state=2) LIMIT ?1")?;
        for r in st.query_map([limit], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (id, path) = r?;
            v.push((id, path.rsplit('.').next().unwrap_or("bin").to_string()));
        }
        Ok(v)
    }

    pub fn wanted_extension(&self, id: &str) -> rusqlite::Result<Option<String>> {
        use rusqlite::OptionalExtension;
        let ext = self.conn().query_row("SELECT ext FROM want_blob WHERE media_id=?1", [id], |r| r.get(0)).optional()?;
        if ext.is_some() { return Ok(ext); }
        let path: Option<String> = self.conn().query_row("SELECT m.path FROM media m JOIN bad_media b ON b.media_id=m.id WHERE m.id=?1 AND b.reason IN ('missing','hash')", [id], |r| r.get(0)).optional()?;
        Ok(path.map(|p| p.rsplit('.').next().unwrap_or("bin").to_string()))
    }

    /// Whether a media is a photo (true) or a video, from its awaited or stored record.
    pub fn wanted_is_photo(&self, id: &str) -> rusqlite::Result<Option<bool>> {
        use rusqlite::OptionalExtension;
        self.conn().query_row("SELECT kind FROM want_blob WHERE media_id=?1 UNION ALL SELECT kind FROM media WHERE id=?1 LIMIT 1", [id],
            |r| r.get::<_, String>(0)).optional().map(|k| k.map(|k| k != "video"))
    }

    /// A file a peer sent is not a picture or video: stop asking for it.
    pub fn give_up_blob(&self, id: &str) -> rusqlite::Result<()> {
        self.conn().execute("DELETE FROM want_blob WHERE media_id=?1", [id]).map(|_| ())
    }

    /// Called once a wanted blob has been stored: materializes its media row.
    pub fn blob_arrived(&self, id: &str) -> rusqlite::Result<()> {
        use rusqlite::OptionalExtension;
        if self.trash_reg(id)?.state == crate::rules::PURGED { return Ok(()); }
        let row: Option<(String, String)> = self.conn().query_row("SELECT kind, ext FROM want_blob WHERE media_id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        // shown under its owner once one of its posts is known (else it appears with the post)
        if let (Some((kind, ext)), Some((post_id, ordinal))) = (row, self.known_owner(id)?) {
            let kind = if kind == "video" { MediaKind::Video } else { MediaKind::Photo };
            self.apply_media(id, &post_id, ordinal, &kind, &blob_rel(id, &ext))?;
            // whatever apply_media found (an existing row keeps its path), nothing is awaited any more
            self.conn().execute("DELETE FROM want_blob WHERE media_id=?1", [id])?;
        }
        // A verified copy replaced a damaged local file.
        self.set_bad(id, None)?;
        Ok(())
    }
}

/// Relative path of a stored file. Callers pass ids and extensions checked by
/// `rules::valid_blob_id` / `valid_ext`; anything else maps to a name that cannot be a path
/// (and never panics on short or non-ASCII input).
pub fn blob_rel(sha: &str, ext: &str) -> String {
    if !crate::rules::valid_blob_id(sha.as_bytes()) || !crate::rules::valid_ext(ext.as_bytes()) {
        return "blobs/invalid/invalid".into();
    }
    format!("blobs/{}/{}.{}", &sha[..2], sha, ext)
}

/// Outcome of applying a batch of remote ops.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Applied {
    /// New ops stored (and applied).
    pub applied: usize,
    /// Refused: out of sequence (a gap or a forged number) or a malformed device id.
    pub refused: usize,
    /// Stored but without effect (an invalid media id or extension).
    pub invalid: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Origin;

    fn store() -> Store { Store::open(":memory:").unwrap() }

    #[test]
    fn local_writes_are_logged_and_replayed() {
        const ID: &str = "ab00000000000000000000000000000000000000000000000000000000000000";
        let a = store();
        a.upsert_post(&PostMeta { id: "p".into(), text: Some("t".into()), ..Default::default() }).unwrap();
        a.add_media(ID, "p", 0, &MediaKind::Photo, &format!("blobs/ab/{ID}.jpg"), false).unwrap();
        a.tag_media(ID, "猫", Origin::AI).unwrap();
        a.tag_media(ID, "猫", Origin::USER).unwrap();
        a.untag_media(ID, "猫").unwrap();
        a.tag_media(ID, "墙", Origin::USER).unwrap();
        let ops = a.ops_since(&VersionVector::new(), 1000).unwrap();
        assert_eq!(ops.len(), 6);

        let b = store();
        assert_eq!(b.apply_remote(&ops, |_, _| false).unwrap(), 6);
        assert_eq!(b.apply_remote(&ops, |_, _| false).unwrap(), 0, "idempotent");
        assert_eq!(b.wanted_blobs(10).unwrap(), vec![(ID.to_string(), "jpg".to_string())]);
        b.blob_arrived(ID).unwrap();
        assert!(b.wanted_blobs(10).unwrap().is_empty());
        let mut tags: Vec<(String, u8)> = b.conn().prepare("SELECT t.label, tm.origin FROM tag_media tm JOIN tag t ON t.id=tm.tag_id ORDER BY t.label").unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|r| r.unwrap()).collect();
        tags.sort();
        assert_eq!(tags, vec![("墙".into(), 1), ("猫".into(), 0)]);
        assert_eq!(b.version_vector().unwrap(), a.version_vector().unwrap());
    }

    #[test]
    fn concurrent_tag_edits_converge_in_any_order() {
        let (a, b) = (store(), store());
        for s in [&a, &b] {
            s.upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        }
        a.tag_media("m", "x", Origin::AI).unwrap();
        b.tag_media("m", "x", Origin::USER).unwrap();
        b.untag_media("m", "x").unwrap();
        let oa = a.ops_since(&VersionVector::new(), 100).unwrap();
        let ob = b.ops_since(&VersionVector::new(), 100).unwrap();
        let (c, d) = (store(), store());
        c.apply_remote(&oa, |_, _| true).unwrap(); c.apply_remote(&ob, |_, _| true).unwrap();
        d.apply_remote(&ob, |_, _| true).unwrap(); d.apply_remote(&oa, |_, _| true).unwrap();
        let q = |s: &Store| s.conn().query_row("SELECT origin, hlc FROM tag_media", [], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))).unwrap();
        assert_eq!(q(&c), q(&d));
        a.apply_remote(&ob, |_, _| true).unwrap();
        b.apply_remote(&oa, |_, _| true).unwrap();
        assert_eq!(q(&a), q(&b));
        assert_eq!(q(&a), q(&c));
    }
}

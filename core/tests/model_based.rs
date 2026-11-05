//! Model-based test of sync: real stores (files on disk) are driven by random local edits,
//! partial / reordered / repeated deliveries of each other's logs and restarts. After every
//! step each store is compared with a reference model:
//!  * every record it holds is exactly the record its author wrote (nothing altered in transit);
//!  * each device's log is contiguous, and the version vector is what an independent simulation
//!    of "only the next number is taken" predicts for the deliveries so far;
//!  * its observable state equals the specification computed *declaratively* from the records
//!    it holds: each register is the maximum of all writes to it in a fixed total order, a media's
//!    owner is the smallest claim whose post is known, analysed-by is a set. The specification
//!    never replays the implementation's incremental merges, so a merge, an SQL statement, a
//!    derived table or an ordering effect that disagrees with it shows up here.
use proptest::prelude::*;
use std::collections::{BTreeMap, BTreeSet};
use tl_core::model::{MediaKind, Origin, PostMeta};
use tl_core::oplog::{LoggedOp, Op, VersionVector};
use tl_core::rules::TrashAction;
use tl_core::store::Store;

#[derive(Debug, Clone)]
enum Step {
    Tag { r: usize, media: u8, label: u8, ai: bool },
    Untag { r: usize, media: u8, label: u8 },
    Retag { r: usize, media: u8, model: u8, labels: Vec<u8>, replace: bool },
    /// `text`: None = absent, Some(0) = empty, Some(1) = blank, Some(n) = a value.
    ImportPost { r: usize, post: u8, text: Option<u8>, author: Option<u8> },
    /// Claim a media for a post this store knows only through sync (no post record of its own).
    /// No app path does this today; it is the case where a media can arrive before its post.
    ClaimKnown { r: usize, media: u8, post: u8, ordinal: u8 },
    Claim { r: usize, media: u8, post: u8, ordinal: u8 },
    Bin { r: usize, media: u8, action: u8 },
    Rename { r: usize, from: u8, to: u8 },
    UndoRename { r: usize, label: u8 },
    Folder { r: usize, f: u8, delete: bool },
    Member { r: usize, f: u8, media: u8, add: bool },
    Recent { r: usize, post: u8, at: u8 },
    /// A shared setting (like the AI prompt): a value, or back to the default (None).
    Setting { r: usize, value: Option<u8> },
    /// Deliver up to `limit` of `from`'s records that `to` lacks, possibly in reverse order.
    Deliver { from: usize, to: usize, limit: usize, reverse: bool },
    /// Close and reopen a store from its file.
    Restart { r: usize },
    /// A record from another device stamped at the end of time (a wrong clock or a forgery).
    Future { to: usize, media: u8, label: u8 },
}

fn step() -> impl Strategy<Value = Step> {
    let r = 0..3usize;
    prop_oneof![
        3 => (r.clone(), 0..3u8, 0..3u8, any::<bool>()).prop_map(|(r, media, label, ai)| Step::Tag { r, media, label, ai }),
        1 => (r.clone(), 0..3u8, 0..3u8).prop_map(|(r, media, label)| Step::Untag { r, media, label }),
        1 => (r.clone(), 0..3u8, 0..2u8, proptest::collection::vec(0..3u8, 0..3), any::<bool>())
            .prop_map(|(r, media, model, labels, replace)| Step::Retag { r, media, model, labels, replace }),
        2 => (r.clone(), 0..3u8, proptest::option::of(0..5u8), proptest::option::of(0..3u8)).prop_map(|(r, post, text, author)| Step::ImportPost { r, post, text, author }),
        1 => (r.clone(), 0..3u8, 0..3u8, 0..2u8).prop_map(|(r, media, post, ordinal)| Step::ClaimKnown { r, media, post, ordinal }),
        2 => (r.clone(), 0..3u8, 0..3u8, 0..2u8).prop_map(|(r, media, post, ordinal)| Step::Claim { r, media, post, ordinal }),
        4 => (r.clone(), 0..3u8, 0..4u8).prop_map(|(r, media, action)| Step::Bin { r, media, action }),
        1 => (0..3usize, 0..3u8, 0..3u8).prop_map(|(to, media, label)| Step::Future { to, media, label }),
        1 => (r.clone(), 0..3u8, 0..4u8).prop_map(|(r, from, to)| Step::Rename { r, from, to }),
        1 => (r.clone(), 0..4u8).prop_map(|(r, label)| Step::UndoRename { r, label }),
        1 => (r.clone(), 0..2u8, any::<bool>()).prop_map(|(r, f, delete)| Step::Folder { r, f, delete }),
        1 => (r.clone(), 0..2u8, 0..3u8, any::<bool>()).prop_map(|(r, f, media, add)| Step::Member { r, f, media, add }),
        1 => (r.clone(), 0..3u8, 0..4u8).prop_map(|(r, post, at)| Step::Recent { r, post, at }),
        1 => (r.clone(), proptest::option::of(0..3u8)).prop_map(|(r, value)| Step::Setting { r, value }),
        6 => (0..3usize, 0..3usize, 1..40usize, any::<bool>()).prop_map(|(from, to, limit, reverse)| Step::Deliver { from, to, limit, reverse }),
        1 => r.prop_map(|r| Step::Restart { r }),
    ]
}

fn mid(m: u8) -> String { format!("{m:064}") }
fn lab(l: u8) -> String { format!("l{l}") }

fn local(s: &Store, st: &Step) {
    match st {
        Step::Tag { media, label, ai, .. } => s.tag_media(&mid(*media), &lab(*label), if *ai { Origin::AI } else { Origin::USER }).unwrap(),
        Step::Untag { media, label, .. } => s.untag_media(&mid(*media), &lab(*label)).unwrap(),
        Step::Retag { media, model, labels, replace, .. } => {
            let ls: Vec<String> = labels.iter().map(|l| lab(*l)).collect();
            s.retag(&mid(*media), &format!("m{model}"), &ls, *replace).unwrap()
        }
        Step::ImportPost { post, text, author, .. } => {
            let val = |n: u8, w: &str| match n { 0 => String::new(), 1 => "  ".into(), n => format!("{w}{n}") };
            s.upsert_post(&PostMeta { id: format!("p{post}"), text: text.map(|t| val(t, "正文")), author_name: author.map(|a| val(a, "作者")), ..Default::default() }).unwrap()
        }
        Step::ClaimKnown { media, post, ordinal, .. } => {
            let known: bool = s.conn().prepare("SELECT 1 FROM post WHERE id=?1").unwrap().exists([format!("p{post}")]).unwrap();
            if known { s.add_media(&mid(*media), &format!("p{post}"), *ordinal as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(*media)), false).unwrap(); }
        }
        Step::Claim { media, post, ordinal, .. } => {
            // a media is always stored together with its post (as an import or download does)
            s.upsert_post(&PostMeta { id: format!("p{post}"), ..Default::default() }).unwrap();
            s.add_media(&mid(*media), &format!("p{post}"), *ordinal as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(*media)), false).unwrap();
        }
        Step::Bin { media, action, .. } => {
            let a = [TrashAction::Trash, TrashAction::Restore, TrashAction::Purge, TrashAction::Reimport][*action as usize];
            s.trash_action(&mid(*media), a).unwrap();
        }
        Step::Rename { from, to, .. } => { s.rename_tag(&lab(*from), &lab(*to)).unwrap(); }
        Step::UndoRename { label, .. } => s.undo_rename(&lab(*label)).unwrap(),
        Step::Folder { f, delete, .. } => if *delete { s.delete_folder(&format!("夹{f}")).unwrap() } else { s.create_folder(&format!("夹{f}")).unwrap(); },
        Step::Member { f, media, add, .. } => if *add { s.add_to_folder(&format!("夹{f}"), &[mid(*media)]).unwrap(); } else { s.remove_from_folder(&format!("夹{f}"), &[mid(*media)]).unwrap(); },
        Step::Recent { post, at, .. } => s.mark_recent(&format!("p{post}"), 1_700_000_000_000 + *at as u64 * 3_600_000).unwrap(),
        Step::Setting { value, .. } => s.set_setting("ai.prompt", value.map(|v| format!("提示词{v}")).as_deref()).unwrap(),
        Step::Deliver { .. } | Step::Restart { .. } | Step::Future { .. } => unreachable!(),
    }
}

/// Everything a store shows, as sorted lines.
fn observe(s: &Store) -> BTreeSet<String> {
    let mut v = BTreeSet::new();
    let mut q = |sql: &str, n: usize, tag: &str| {
        let mut st = s.conn().prepare(sql).unwrap();
        let rows = st.query_map([], |r| {
            let mut parts = vec![tag.to_string()];
            for i in 0..n { parts.push(match r.get_ref(i)? { rusqlite::types::ValueRef::Null => "-".into(), rusqlite::types::ValueRef::Integer(x) => x.to_string(), rusqlite::types::ValueRef::Text(t) => String::from_utf8_lossy(t).into_owned(), _ => "?".into() }); }
            Ok(parts.join(" "))
        }).unwrap();
        for r in rows { v.insert(r.unwrap()); }
    };
    q("SELECT id, author_name, screen_name, text, created_at, url FROM post", 6, "P");
    q("SELECT id, post_id, ordinal FROM media", 3, "M");
    q("SELECT tm.media_id, t.label, tm.origin FROM tag_media tm JOIN tag t ON t.id=tm.tag_id", 3, "T");
    q("SELECT s.media_id, t.label, s.model, s.present FROM tag_src s JOIN tag t ON t.id=s.tag_id", 4, "S");
    q("SELECT media_id, model FROM ai_done", 2, "A");
    q("SELECT media_id, inc, state, hlc FROM trash", 4, "B");
    q("SELECT src, dst, hlc FROM tag_alias", 3, "AL");
    q("SELECT name, deleted, hlc FROM folder", 3, "F");
    q("SELECT folder, media_id, present, hlc FROM folder_media", 4, "FM");
    q("SELECT post_id, at FROM recent", 2, "RA");
    q("SELECT key, value, hlc FROM setting", 3, "SET");
    v
}

/// The specification: the state the records `ops` stand for, computed declaratively.
fn spec(ops: &[LoggedOp]) -> BTreeSet<String> {
    let mut v = BTreeSet::new();
    // posts: each field is the maximum (clock, value) over writes of a non-empty value
    let mut posts: BTreeMap<String, [Option<(u64, String)>; 5]> = BTreeMap::new();
    // media claims: (post, ordinal); owner = smallest claim whose post is known
    let mut claims: BTreeMap<String, BTreeSet<(String, i64)>> = BTreeMap::new();
    // tag bits: (media, label) → per bit the maximum (clock, bit)
    let mut tags: BTreeMap<(String, String), [Option<(u64, bool)>; 2]> = BTreeMap::new();
    let mut src: BTreeMap<(String, String, String), (u64, bool)> = BTreeMap::new();
    let mut ai: BTreeSet<(String, String)> = BTreeSet::new();
    let mut bin: BTreeMap<String, (u32, u8, u64)> = BTreeMap::new();
    let mut alias: BTreeMap<String, (u64, Option<String>)> = BTreeMap::new();
    let mut folder: BTreeMap<String, (u64, bool)> = BTreeMap::new();
    let mut member: BTreeMap<(String, String), (u64, bool)> = BTreeMap::new();
    let mut recent: BTreeMap<String, u64> = BTreeMap::new();
    let mut settings: BTreeMap<String, (u64, Option<String>)> = BTreeMap::new();
    fn up<T: Ord + Clone>(slot: &mut Option<T>, x: T) { if slot.as_ref().map_or(true, |c| x > *c) { *slot = Some(x); } }
    for lo in ops {
        // This generator's only abnormal clock is Future (u64::MAX). It remains
        // in the log, but must not contribute to materialized state. Deliberately
        // independent of the production admission predicate to catch wiring bugs.
        if matches!(&lo.op, Op::Tag { hlc: u64::MAX, .. }) { continue; }
        match &lo.op {
            Op::Post { meta, hlc } => {
                let e = posts.entry(meta.id.clone()).or_default();
                for (i, f) in [&meta.author_name, &meta.screen_name, &meta.text, &meta.created_at, &meta.url].into_iter().enumerate() {
                    if let Some(x) = f.as_ref().filter(|x| !x.trim().is_empty()) { up(&mut e[i], (*hlc, x.clone())); }
                }
            }
            Op::Media { id, post_id, ordinal, .. } => { claims.entry(id.clone()).or_default().insert((post_id.clone(), *ordinal)); }
            Op::Tag { media_id, label, origin, mask, hlc } => {
                let e = tags.entry((media_id.clone(), label.clone())).or_default();
                for (i, bit) in [1u8, 2].into_iter().enumerate() { if mask & bit != 0 { up(&mut e[i], (*hlc, origin & bit != 0)); } }
            }
            Op::TagSrc { media_id, label, model, present, hlc } => {
                let k = (media_id.clone(), label.clone(), model.clone());
                let mut slot = src.get(&k).cloned(); up(&mut slot, (*hlc, *present)); src.insert(k, slot.unwrap());
            }
            Op::AiDone { media_id, model } => { ai.insert((media_id.clone(), model.clone())); }
            Op::Trash { media_id, inc, state, hlc } => { let mut s = bin.get(media_id).cloned(); up(&mut s, (*inc, (*state).min(2), *hlc)); bin.insert(media_id.clone(), s.unwrap()); }
            Op::Alias { src: a, dst, hlc } => { let mut s = alias.get(a).cloned(); up(&mut s, (*hlc, dst.clone())); alias.insert(a.clone(), s.unwrap()); }
            Op::Folder { name, deleted, hlc } => { let mut s = folder.get(name).cloned(); up(&mut s, (*hlc, *deleted)); folder.insert(name.clone(), s.unwrap()); }
            Op::FolderMedia { folder: f, media_id, present, hlc } => { let k = (f.clone(), media_id.clone()); let mut s = member.get(&k).cloned(); up(&mut s, (*hlc, *present)); member.insert(k, s.unwrap()); }
            Op::Recent { post_id, at } => { let e = recent.entry(post_id.clone()).or_insert(0); *e = (*e).max(*at); }
            Op::Setting { key, value, hlc } => { let mut s = settings.get(key).cloned(); up(&mut s, (*hlc, value.clone())); settings.insert(key.clone(), s.unwrap()); }
            Op::Album { .. } => {}
            Op::Unknown(_) => {}
        }
    }
    let d = |o: &Option<(u64, String)>| o.as_ref().map_or("-".to_string(), |x| x.1.clone());
    for (id, f) in &posts { v.insert(format!("P {id} {} {} {} {} {}", d(&f[0]), d(&f[1]), d(&f[2]), d(&f[3]), d(&f[4]))); }
    for (id, cs) in &claims {
        if let Some((p, o)) = cs.iter().filter(|(p, _)| posts.contains_key(p)).min() { v.insert(format!("M {id} {p} {o}")); }
    }
    for ((m, l), b) in &tags {
        let o = b[0].map_or(0, |x| x.1 as u8) | (b[1].map_or(0, |x| x.1 as u8) << 1);
        v.insert(format!("T {m} {l} {o}"));
    }
    for ((m, l, model), (_, p)) in &src { v.insert(format!("S {m} {l} {model} {}", *p as u8)); }
    for (m, model) in &ai { v.insert(format!("A {m} {model}")); }
    for (m, (i, s, h)) in &bin { v.insert(format!("B {m} {i} {s} {h}")); }
    for (a, (h, dst)) in &alias { v.insert(format!("AL {a} {} {h}", dst.clone().unwrap_or("-".into()))); }
    for (f, (h, del)) in &folder { v.insert(format!("F {f} {} {h}", *del as u8)); }
    for ((f, m), (h, p)) in &member { v.insert(format!("FM {f} {m} {} {h}", *p as u8)); }
    for (p, at) in &recent { v.insert(format!("RA {p} {at}")); }
    for (k, (h, val)) in &settings { v.insert(format!("SET {k} {} {h}", val.clone().unwrap_or("-".into()))); }
    v
}

struct Replica { path: std::path::PathBuf, s: Option<Store> }
impl Replica {
    fn s(&self) -> &Store { self.s.as_ref().unwrap() }
    fn restart(&mut self) { self.s = None; self.s = Some(Store::open(self.path.to_str().unwrap()).unwrap()); }
}

fn whole_log(s: &Store) -> Vec<LoggedOp> { s.ops_since(&VersionVector::new(), 1_000_000).unwrap() }

fn check(r: &Replica, authored: &BTreeMap<(String, i64), serde_json::Value>, vv_model: &VersionVector, ctx: &str) -> Result<(), TestCaseError> {
    let log = whole_log(r.s());
    // records are exactly what their authors wrote
    for lo in &log {
        let a = authored.get(&(lo.device.clone(), lo.seq));
        prop_assert!(a.is_some(), "{ctx}: {}#{} was never written by its device", lo.device, lo.seq);
        prop_assert_eq!(a.unwrap(), &tl_core::oplog::op_value(&lo.op), "{}: {}#{} altered", ctx, lo.device, lo.seq);
    }
    // each log is contiguous, and the version vector is the predicted one
    let vv = r.s().version_vector().unwrap();
    for (dev, max) in &vv {
        let n = log.iter().filter(|o| &o.device == dev).count() as i64;
        prop_assert_eq!(n, *max, "{}: log of {} has gaps", ctx, dev);
    }
    prop_assert_eq!(&vv, vv_model, "{}: version vector", ctx);
    // the state is what the records stand for
    let got = observe(r.s());
    let want = spec(&log);
    if got != want {
        let missing: Vec<_> = want.difference(&got).collect();
        let extra: Vec<_> = got.difference(&want).collect();
        prop_assert!(false, "{}: state differs from the specification\n  expected but missing: {:?}\n  present but not expected: {:?}", ctx, missing, extra);
    }
    Ok(())
}

fn run(steps: &[Step], tag: &str) -> Result<(), TestCaseError> {
    let dir = std::env::temp_dir().join(format!("tl-model-{tag}-{}-{}", std::process::id(), rand_suffix()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut reps: Vec<Replica> = (0..3).map(|i| {
        let path = dir.join(format!("r{i}.sqlite"));
        Replica { s: Some(Store::open(path.to_str().unwrap()).unwrap()), path }
    }).collect();
    let mut authored: BTreeMap<(String, i64), serde_json::Value> = BTreeMap::new();
    let mut vv_model: Vec<VersionVector> = vec![VersionVector::new(); 3];
    for (i, st) in steps.iter().enumerate() {
        let ctx = format!("step {i} {st:?}");
        match st {
            Step::Deliver { from, to, limit, reverse } => {
                if from == to { continue; }
                let mut ops = reps[*from].s().ops_since(&reps[*to].s().version_vector().unwrap(), *limit).unwrap();
                if *reverse { ops.reverse(); }
                // the model of delivery: in the order given, only the next number of each log is taken
                for o in &ops {
                    let have = vv_model[*to].get(&o.device).copied().unwrap_or(0);
                    if o.seq == have + 1 { vv_model[*to].insert(o.device.clone(), o.seq); }
                }
                reps[*to].s().apply_remote_counted(&ops, |_, _| true).unwrap();
                check(&reps[*to], &authored, &vv_model[*to], &ctx)?;
            }
            Step::Restart { r } => { reps[*r].restart(); check(&reps[*r], &authored, &vv_model[*r], &ctx)?; }
            Step::Future { to, media, label } => {
                // the forging device's log continues where every store has it (so the record is taken)
                let seq = authored.keys().filter(|(d, _)| d == "forger").count() as i64 + 1;
                let op = Op::Tag { media_id: mid(*media), label: lab(*label), origin: 1, mask: 3, hlc: u64::MAX };
                authored.insert(("forger".into(), seq), tl_core::oplog::op_value(&op));
                let mut ops: Vec<LoggedOp> = (1..seq).map(|q| LoggedOp { device: "forger".into(), seq: q, op: tl_core::oplog::parse_op(authored[&("forger".to_string(), q)].clone()).unwrap() }).collect();
                ops.push(LoggedOp { device: "forger".into(), seq, op });
                for o in &ops { let have = vv_model[*to].get(&o.device).copied().unwrap_or(0); if o.seq == have + 1 { vv_model[*to].insert(o.device.clone(), o.seq); } }
                reps[*to].s().apply_remote_counted(&ops, |_, _| true).unwrap();
                check(&reps[*to], &authored, &vv_model[*to], &ctx)?;
            }
            _ => {
                let r = match st { Step::Tag { r, .. } | Step::Untag { r, .. } | Step::Retag { r, .. } | Step::ImportPost { r, .. } | Step::Claim { r, .. } | Step::ClaimKnown { r, .. } | Step::Bin { r, .. }
                    | Step::Rename { r, .. } | Step::UndoRename { r, .. } | Step::Folder { r, .. } | Step::Member { r, .. } | Step::Recent { r, .. } | Step::Setting { r, .. } => *r, _ => unreachable!() };
                local(reps[r].s(), st);
                let me = reps[r].s().device_id().unwrap();
                for lo in whole_log(reps[r].s()).into_iter().filter(|o| o.device == me) {
                    // whatever a peer sent, this device's own clock stays near wall time
                    if let Some(h) = tl_core::oplog::op_value(&lo.op).get("hlc").and_then(|h| h.as_u64()) {
                        prop_assert!(h <= tl_core::rules::hlc_ceiling(tl_core::store::now_ms()), "{ctx}: a local write carries a clock from the far future");
                    }
                    authored.entry((lo.device.clone(), lo.seq)).or_insert_with(|| tl_core::oplog::op_value(&lo.op));
                    let e = vv_model[r].entry(me.clone()).or_insert(0);
                    *e = (*e).max(lo.seq);
                }
                check(&reps[r], &authored, &vv_model[r], &ctx)?;
            }
        }
    }
    // finally everything reaches everyone: all stores equal, and equal to the specification of every record
    for _ in 0..3 { for a in 0..3 { for b in 0..3 { if a != b {
        let ops = reps[a].s().ops_since(&reps[b].s().version_vector().unwrap(), 1_000_000).unwrap();
        for o in &ops { let have = vv_model[b].get(&o.device).copied().unwrap_or(0); if o.seq == have + 1 { vv_model[b].insert(o.device.clone(), o.seq); } }
        reps[b].s().apply_remote_counted(&ops, |_, _| true).unwrap();
    } } } }
    let all: Vec<LoggedOp> = { let mut v = whole_log(reps[0].s()); v.sort_by(|a, b| (&a.device, a.seq).cmp(&(&b.device, b.seq))); v };
    prop_assert_eq!(all.len(), authored.len(), "every record reached every store");
    for (i, r) in reps.iter().enumerate() { check(r, &authored, &vv_model[i], &format!("final, store {i}"))?; }
    let first = observe(reps[0].s());
    for r in &reps[1..] { prop_assert_eq!(&observe(r.s()), &first, "stores converge"); }
    drop(reps);
    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}

fn rand_suffix() -> u64 { use std::sync::atomic::{AtomicU64, Ordering}; static N: AtomicU64 = AtomicU64::new(0); N.fetch_add(1, Ordering::Relaxed) }

proptest! {
    #![proptest_config(ProptestConfig { cases: 300, max_shrink_iters: 4000, ..ProptestConfig::default() })]

    #[test]
    fn stores_follow_the_specification(steps in proptest::collection::vec(step(), 1..60)) {
        run(&steps, "p")?;
    }
}

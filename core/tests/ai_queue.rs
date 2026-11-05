//! The AI queue on real stores (`tagmodel` is its specification): a media this device cannot
//! analyse is skipped for the run, then for good after `MAX_AI_ATTEMPTS`, a crash during an
//! attempt counts, nothing of it is synced, and another device's analysis still arrives.
use tl_core::model::{MediaKind, PostMeta};
use tl_core::oplog::VersionVector;
use tl_core::rules::MAX_AI_ATTEMPTS;
use tl_core::store::Store;

fn replica() -> Store {
    let s = Store::open(":memory:").unwrap();
    s.upsert_post(&PostMeta { id: "p0".into(), ..Default::default() }).unwrap();
    for m in 0..3 { s.add_media(&mid(m), "p0", m as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(m)), false).unwrap(); }
    s
}
fn mid(m: u8) -> String { format!("{m:064}") }
fn pending(s: &Store, since: i64) -> Vec<String> { s.media_needing_ai_for("qwen", since, 10).unwrap().into_iter().map(|m| m.media_id).collect() }

/// Bridge the finite proof state to the real SQL selector, including the last media index
/// and every reachable combination of retry budgets and current-run failure marks.
#[test]
fn finite_queue_model_matches_sql_for_all_reachable_states() {
    use tl_core::tagmodel::{head, Queue, N};
    let s = replica();
    for done in 0u8..(1 << N) {
        s.conn().execute("DELETE FROM ai_done", []).unwrap();
        for m in 0..N {
            if done & (1 << m) != 0 {
                s.conn().execute("INSERT INTO ai_done VALUES(?1,'other-model')", [mid(m as u8)]).unwrap();
            }
        }
        for f0 in 0..=MAX_AI_ATTEMPTS as u8 {
            for f1 in 0..=MAX_AI_ATTEMPTS as u8 {
                for f2 in 0..=MAX_AI_ATTEMPTS as u8 {
                    for run_failed in 0u8..(1 << N) {
                        let q = Queue { fail: [f0, f1, f2], run_failed };
                        if (0..N).any(|m| q.fail[m] == 0 && run_failed & (1 << m) != 0) { continue; }
                        s.conn().execute("DELETE FROM ai_fail", []).unwrap();
                        for m in 0..N {
                            if q.fail[m] > 0 {
                                let at = if run_failed & (1 << m) != 0 { 200 } else { 100 };
                                s.conn().execute("INSERT INTO ai_fail VALUES(?1,'qwen',?2,'error',?3)",
                                    rusqlite::params![mid(m as u8), q.fail[m], at]).unwrap();
                            }
                        }
                        assert_eq!(pending(&s, 150).first().cloned(), head(done, &q).map(|m| mid(m as u8)),
                            "done={done}, queue={q:?}");
                    }
                }
            }
        }
    }
}
/// Sends everything `from` has that `to` lacks.
fn sync(from: &Store, to: &Store) {
    let ops = from.ops_since(&to.version_vector().unwrap(), 100_000).unwrap();
    to.apply_remote(&ops, |_, _| true).unwrap();
}

#[test]
fn a_failing_media_never_blocks_the_queue_and_stays_on_this_device() {
    assert_eq!(MAX_AI_ATTEMPTS, 2);
    let (a, b) = (replica(), replica());
    sync(&a, &b); sync(&b, &a);

    // run 1 on A (started at t=100): m0 fails; the rest of the run goes on without it
    assert_eq!(pending(&a, 100)[0], mid(0));
    a.ai_attempt_begin(&mid(0), "qwen", 101).unwrap();
    a.ai_attempt_failed(&mid(0), "qwen", "Width: 22 must be larger than factor: 32").unwrap();
    assert_eq!(pending(&a, 100), vec![mid(1), mid(2)], "skipped for this run");
    // m1: the app dies during the attempt (begin, then nothing)
    a.ai_attempt_begin(&mid(1), "qwen", 102).unwrap();

    // run 2 (t=200): both are tried again once
    assert_eq!(pending(&a, 200), vec![mid(0), mid(1), mid(2)]);
    a.ai_attempt_begin(&mid(0), "qwen", 201).unwrap();
    a.ai_attempt_failed(&mid(0), "qwen", "Width: 22 must be larger than factor: 32").unwrap();
    a.ai_attempt_begin(&mid(1), "qwen", 202).unwrap();   // dies again

    // run 3: this device has given up on both; m2 is still done normally
    assert_eq!(pending(&a, 300), vec![mid(2)]);
    a.retag(&mid(2), "qwen", &["天空".into()], false).unwrap();
    assert!(pending(&a, 300).is_empty(), "the run ends: nothing left that this device can do");
    let f = a.ai_failures().unwrap();
    assert_eq!(f.len(), 2, "both are listed, not dropped silently");
    assert!(f.iter().any(|x| x.media_id == mid(0) && x.reason.contains("factor: 32")));
    assert!(f.iter().any(|x| x.media_id == mid(1) && x.reason.contains("意外退出")));

    // nothing about failures is synced: B still analyses m0 and m1, and its results reach A
    sync(&a, &b);
    assert!(b.ai_failures().unwrap().is_empty());
    assert_eq!(pending(&b, 0), vec![mid(0), mid(1)], "B still has them to do");
    b.retag(&mid(0), "qwen", &["白墙".into()], false).unwrap();
    b.retag(&mid(1), "qwen", &[], false).unwrap();
    sync(&b, &a);
    assert!(a.ai_failures().unwrap().is_empty(), "analysed elsewhere: no longer a failure here");
    assert!(pending(&a, 0).is_empty() && pending(&b, 0).is_empty());
    assert_eq!(a.media_needing_ai(10).unwrap().len(), 0);

    // both devices agree on everything synced
    sync(&a, &b);
    let all = |s: &Store| s.ops_since(&VersionVector::new(), 100_000).unwrap().len();
    assert_eq!(all(&a), all(&b));
    let tags = |s: &Store| { let mut st = s.conn().prepare("SELECT media_id, tag_id, origin FROM tag_media ORDER BY 1,2").unwrap(); st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))).unwrap().count() };
    assert_eq!(tags(&a), tags(&b));
}

#[test]
fn an_attempt_taken_back_does_not_count() {
    let a = replica();
    a.ai_attempt_begin(&mid(0), "qwen", 10).unwrap();
    a.ai_attempt_undo(&mid(0), "qwen").unwrap();
    assert_eq!(pending(&a, 10)[0], mid(0), "cancelled or the model failed to load: not the media's fault");
    let n: i64 = a.conn().query_row("SELECT count(*) FROM ai_fail", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 0);
    // a failure for another model is not this model's
    a.ai_attempt_begin(&mid(0), "other", 10).unwrap();
    a.ai_attempt_begin(&mid(0), "other", 11).unwrap();
    assert_eq!(pending(&a, 0)[0], mid(0));
    a.ai_failures_clear().unwrap();
    assert!(a.ai_failures().unwrap().is_empty());
}

#[test]
fn renaming_a_folder_moves_its_media_and_syncs_as_folder_records() {
    let (a, b) = (replica(), replica());
    a.add_to_folder("猫", &[mid(0), mid(1)]).unwrap();
    a.add_to_folder("狗", &[mid(2)]).unwrap();
    sync(&a, &b);
    assert_eq!(a.rename_folder("猫", "猫咪").unwrap(), 2);
    // into an existing name: a merge
    assert_eq!(a.rename_folder("狗", "猫咪").unwrap(), 1);
    sync(&a, &b);
    for s in [&a, &b] {
        let names: Vec<String> = s.folders().unwrap().into_iter().map(|f| f.0).collect();
        assert_eq!(names, vec!["猫咪".to_string()]);
        let n: i64 = s.conn().query_row("SELECT count(*) FROM folder_media WHERE folder='猫咪' AND present=1", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 3);
    }
}

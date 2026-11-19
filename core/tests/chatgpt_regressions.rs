use tl_core::{store::Store, library::{Library, FeedFilter, SearchFields}, model::{PostMeta, MediaKind, Origin, SearchScope}, oplog::{Op,LoggedOp}, rules::TrashAction};

const ID: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
fn base() -> Store {
 let s=Store::open(":memory:").unwrap();
 s.upsert_post(&PostMeta{id:"p".into(),..Default::default()}).unwrap();
 s.add_media(ID,"p",0,&MediaKind::Photo,&format!("blobs/aa/{ID}.jpg"),false).unwrap();s
}
#[test]
fn regression_merged_common_filter_loses_match() {
 let s=base();s.tag_media(ID,"a",Origin::USER).unwrap();s.tag_media(ID,"b",Origin::AI).unwrap();s.rename_tag("a","b").unwrap();
 assert_eq!(s.media_tags(ID).unwrap(),vec![("b".into(),3)]);
 let got=s.feed_filtered(&[vec!["b".into()]],&["b".into()],SearchScope::Common,SearchFields::default(),&FeedFilter::default()).unwrap();
 assert_eq!(got.len(),1,"regression: displayed common tag must match common search");
}
#[test]
fn regression_future_clock_prevents_local_removal() {
 let s=base();
 s.apply_remote(&[LoggedOp{device:"peer".into(),seq:1,op:Op::Tag{media_id:ID.into(),label:"locked".into(),origin:1,mask:3,hlc:u64::MAX}}],|_,_|true).unwrap();
 s.untag_media(ID,"locked").unwrap();
 assert_eq!(s.media_tags(ID).unwrap(),vec![],"regression: untag must remove tag");
}
#[test]
fn regression_wipe_failure_commits_partial_deletion() {
 let s=base();s.tag_media(ID,"keep",Origin::USER).unwrap();
 let vv=s.version_vector().unwrap();
 s.conn().execute_batch("CREATE TRIGGER stop_wipe BEFORE DELETE ON post BEGIN SELECT RAISE(ABORT,'simulated failure'); END;").unwrap();
 assert!(s.wipe().is_err());
 assert_eq!(s.stats().unwrap().photos,1);
 assert_eq!(s.version_vector().unwrap(),vv,"regression: rollback must preserve the log");
 assert!(s.post_meta("p").unwrap().is_some());
}
#[test]
fn regression_purged_inflight_blob_recreates_media_row() {
 let s=base();
 s.trash_action(ID,TrashAction::Trash).unwrap();s.trash_action(ID,TrashAction::Purge).unwrap();s.gc_done(ID).unwrap();
 assert!(s.media_row(ID).unwrap().is_none());
 s.blob_arrived(ID, &tl_core::oplog::blob_rel(ID, "jpg")).unwrap();
 assert!(s.media_row(ID).unwrap().is_none(),"late blob must not recreate purged media");
 assert!(s.gc_pending().unwrap().is_empty(),"no remaining removal scheduled");
}
#[tokio::test(flavor="multi_thread")]
async fn regression_same_hash_other_extension_cannot_relay() {
 use std::sync::Arc;
 use tl_core::sync::SyncNode;
 let root=std::env::temp_dir().join(format!("tl-audit-ext-{}",std::process::id()));
 let a=Library::open(root.join("a")).unwrap();
 let b=Arc::new(Library::open(root.join("b")).unwrap());
 let c=Arc::new(Library::open(root.join("c")).unwrap());
 let bytes=b"\xff\xd8\xff\xe0same photo";
 for (l,ext) in [(&a,"jpg"),(b.as_ref(),"png")] {
  let (id,rel)=l.put_blob(bytes,ext).unwrap();
  l.db().upsert_post(&PostMeta{id:"p".into(),..Default::default()}).unwrap();
  l.db().add_media(&id,"p",0,&MediaKind::Photo,&rel,false).unwrap();
 }
 let ops=a.db().ops_since(&Default::default(),100).unwrap();
 b.db().apply_remote(&ops,|_,_|false).unwrap();
 c.db().apply_remote(&ops,|_,_|false).unwrap();
 let bn=SyncNode::new(b);let cn=SyncNode::new(c.clone());
 let (x,y)=tokio::io::duplex(1<<20);
 let (r1,r2)=tokio::join!(bn.simulated_session(x,true),cn.simulated_session(y,false));
 r1.unwrap();r2.unwrap();
 assert_eq!(c.db().stats().unwrap().photos,1,"regression: healthy peer must relay bytes");
 assert_eq!(c.db().wanted_blobs(10).unwrap().len(),0);
}
#[test]
fn regression_export_issues_follows_rejected_symlink() {
 use std::{fs,io::Read};
 let root=std::env::temp_dir().join(format!("tl-audit-symlink-{}",std::process::id()));
 let src=root.join("source/post");fs::create_dir_all(&src).unwrap();
 let secret=root.join("outside.txt");fs::write(&secret,b"AUDIT_SYNTHETIC_PRIVATE_CONTENT").unwrap();
 std::os::unix::fs::symlink(&secret,src.join("bad.jpg")).unwrap();
 fs::write(src.join("good.jpg"),b"\xff\xd8\xff\xe0valid").unwrap();
 let l=Library::open(root.join("lib")).unwrap();
 let report=l.import_legacy_dir(&root.join("source")).unwrap();
 assert!(report.issues.iter().any(|i|i.path.ends_with("bad.jpg") && i.category=="unreadable"));
 let out=root.join("issues.zip");tl_core::import::export_issues(std::path::Path::new(report.report_file.as_ref().unwrap()),&out).unwrap();
 let mut z=zip::ZipArchive::new(fs::File::open(out).unwrap()).unwrap();
 let mut leaked=false;
 for i in 0..z.len() {let mut entry=z.by_index(i).unwrap();if entry.name().ends_with("bad.jpg"){let mut b=String::new();entry.read_to_string(&mut b).unwrap();leaked=b=="AUDIT_SYNTHETIC_PRIVATE_CONTENT";}}
 assert!(!leaked,"regression: refused symlink target must never be exported");
}

#[test]
fn old_ai_and_vectors_cannot_write_after_wipe_even_if_media_returns() {
    let dir = std::env::temp_dir().join(format!("tl-ai-{}", rand::random::<u64>()));
    let lib = Library::open(&dir).unwrap();
    let epoch = lib.epoch();
    lib.wipe(false).unwrap();
    {
        let db = lib.db();
        db.upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        db.add_media(ID, "p", 0, &MediaKind::Photo, &format!("blobs/aa/{ID}.jpg"), false).unwrap();
    }
    assert!(lib.apply_ai_tags_at(epoch, ID, "model", &["stale".into()], false).is_err());
    assert!(lib.set_vectors_at(epoch, "model", &[("stale".into(), vec![1.0])]).is_err());
    assert!(lib.db().media_tags(ID).unwrap().is_empty());
    assert_eq!(lib.load_vectors_for_test("model"), 0);
    lib.apply_ai_tags_at(lib.epoch(), ID, "model", &["fresh".into()], false).unwrap();
    assert_eq!(lib.db().media_tags(ID).unwrap(), vec![("fresh".into(), 2)]);
    drop(lib);
    std::fs::remove_dir_all(dir).unwrap();
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn future_operations_are_relayed_without_poisoning_state(offset in 86_500_000u64..1_000_000_000, duplicate in 0usize..5) {
        let a = base();
        let b = base();
        let hlc = (tl_core::store::now_ms() + offset) << 16;
        let op = LoggedOp { device: "future-peer".into(), seq: 1,
            op: Op::Setting { key: "future".into(), value: Some("value".into()), hlc } };
        a.apply_remote(&[op], |_, _| true).unwrap();
        let log = a.ops_since(&Default::default(), 100).unwrap();
        for _ in 0..=duplicate { b.apply_remote(&log, |_, _| true).unwrap(); }
        for db in [&a, &b] {
            proptest::prop_assert_eq!(db.setting("future").unwrap(), None);
            proptest::prop_assert_eq!(db.pending_op_count().unwrap(), 1);
            proptest::prop_assert_eq!(db.retry_pending_ops(|_, _| true).unwrap(), 0);
            proptest::prop_assert_eq!(db.pending_op_count().unwrap(), 1);
        }
        let relayed = b.ops_since(&Default::default(), 100).unwrap();
        proptest::prop_assert!(relayed.iter().any(|op| op.device == "future-peer" && matches!(&op.op, Op::Setting{hlc: h, ..} if *h == hlc)), "original clock must survive relaying");
    }
}

#[test]
fn failed_file_deletion_keeps_gc_job_for_retry() {
    let dir = std::env::temp_dir().join(format!("tl-gc-{}", rand::random::<u64>()));
    let lib = Library::open(&dir).unwrap();
    let (id, rel) = lib.put_blob(b"\xff\xd8\xff\xe0gc", "jpg").unwrap();
    {
        let db = lib.db();
        db.upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
        db.add_media(&id, "p", 0, &MediaKind::Photo, &rel, false).unwrap();
        db.trash_action(&id, TrashAction::Trash).unwrap();
        db.trash_action(&id, TrashAction::Purge).unwrap();
    }
    let path = dir.join(&rel);
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap(); // deterministic unlink failure, even as root
    lib.settle().unwrap();
    assert!(!lib.db().gc_pending().unwrap().is_empty());
    assert!(lib.db().media_row(&id).unwrap().is_some());
    std::fs::remove_dir(path).unwrap();
    lib.settle().unwrap();
    assert!(lib.db().gc_pending().unwrap().is_empty());
    assert!(lib.db().media_row(&id).unwrap().is_none());
    drop(lib);
    std::fs::remove_dir_all(dir).unwrap();
}

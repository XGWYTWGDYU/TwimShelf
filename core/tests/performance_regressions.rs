use tl_core::{library::{FeedFilter, SearchFields}, model::{MediaKind, Origin, PostMeta, SearchScope}, oplog::VersionVector, store::Store};

#[test]
fn feed_details_preserve_sources_and_aliases_across_query_chunks() {
    let db = Store::open(":memory:").unwrap();
    let tx = db.conn().unchecked_transaction().unwrap();
    db.upsert_post(&PostMeta { id: "p".into(), ..Default::default() }).unwrap();
    for n in 0..405 {
        let id = format!("{n:064x}");
        db.add_media(&id, "p", n, &MediaKind::Photo, &format!("blobs/00/{id}.jpg"), false).unwrap();
        db.tag_media(&id, "old", Origin::USER).unwrap();
        db.retag(&id, "model-b", &["old".into()], false).unwrap();
        db.retag(&id, "model-a", &["new".into()], false).unwrap();
    }
    db.rename_tag("old", "new").unwrap();
    let last = format!("{:064x}",404);
    db.set_bad(&last, Some("decode")).unwrap();
    tx.commit().unwrap();
    let items = db.feed_filtered(&[], &[], SearchScope::Both, SearchFields::default(), &FeedFilter::default()).unwrap();
    assert_eq!(items.len(), 405);
    for item in &items {
        assert_eq!(item.tags.len(), 1);
        assert_eq!(item.tags[0].label, "new");
        assert_eq!(item.tags[0].origin, 3);
        assert_eq!(item.tags[0].models, ["model-a", "model-b"]);
        assert_eq!(item.bad.as_deref(), if item.media_id == last { Some("decode") } else { None });
    }
    let narrow = db.feed_filtered(&[], &[], SearchScope::Both, SearchFields::default(), &FeedFilter { bad_only: true, ..Default::default() }).unwrap();
    assert_eq!(narrow.len(), 1);
    assert_eq!(serde_json::to_value(&narrow[0]).unwrap(), serde_json::to_value(items.iter().find(|i| i.media_id == last).unwrap()).unwrap());
}

#[test]
fn outgoing_log_snapshot_is_bounded_and_next_session_sends_new_writes() {
    let db = Store::open(":memory:").unwrap();
    for id in ["first", "second", "third"] { db.upsert_post(&PostMeta { id: id.into(), ..Default::default() }).unwrap(); }
    let upper = db.version_vector().unwrap();
    db.upsert_post(&PostMeta { id: "later".into(), ..Default::default() }).unwrap();
    let mut cursor = VersionVector::new();
    let mut count = 0;
    loop {
        let batch = db.ops_since_until(&cursor, &upper, 1).unwrap();
        if batch.is_empty() { break; }
        for op in batch { count += 1; cursor.insert(op.device, op.seq); }
    }
    assert_eq!(count, 3);
    assert_eq!(cursor, upper);
    assert_eq!(db.ops_since(&cursor, 10).unwrap().len(), 1);
}

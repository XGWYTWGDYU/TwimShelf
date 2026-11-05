//! What a grid of a hundred thousand media costs to list (run on demand:
//! `cargo test --release --test grid_scale -- --ignored --nocapture`). The grid draws only what
//! is on screen, but it gets the whole list of its media at once.
use tl_core::library::{FeedRequest, Library};
use tl_core::model::{MediaKind, PostMeta};

#[test]
#[ignore]
fn a_hundred_thousand_media_list_quickly() {
    let dir = std::env::temp_dir().join(format!("tl-grid-scale-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let lib = Library::open(&dir).unwrap();
    let posts = 25_000;
    let t = std::time::Instant::now();
    {
        let db = lib.db();
        db.conn().execute_batch("BEGIN").unwrap();
        for p in 0..posts {
            let id = format!("p{p}");
            db.upsert_post(&PostMeta { id: id.clone(), author_name: Some(format!("Author {}", p % 300)), screen_name: Some(format!("user{}", p % 300)),
                text: Some("A post with an ordinary amount of text, about as long as most posts are. ".repeat(2)), created_at: Some("Fri Oct 24 08:13:11 +0000 2026".into()), url: Some(format!("https://x.com/u/status/{p}")) }).unwrap();
            for k in 0..4 { db.add_media(&format!("m{p}_{k}"), &id, k, &MediaKind::Photo, &format!("blobs/m{p}_{k}.jpg"), false).unwrap(); }
        }
        db.conn().execute_batch("COMMIT").unwrap();
    }
    println!("seeded 100000 media in {:?}", t.elapsed());
    let req: FeedRequest = serde_json::from_str(r#"{"scope":"both"}"#).unwrap();
    let t = std::time::Instant::now();
    let items = lib.feed(&req).unwrap();
    let query = t.elapsed();
    let t = std::time::Instant::now();
    let json = serde_json::to_string(&items).unwrap();
    println!("listed {} media: query {:?}, JSON {:?}, {} MB", items.len(), query, t.elapsed(), json.len() / 1_000_000);
    let t = std::time::Instant::now();
    let packed = lib.feed_packed(&req).unwrap();
    let pjson = serde_json::to_string(&packed).unwrap();
    println!("packed: {:?}, {} MB ({} posts, {} tag lists)", t.elapsed(), pjson.len() / 1_000_000, packed.posts.len(), packed.tag_lists.len());
    // the packed form gives back exactly the same items
    let back = serde_json::to_string(&packed.unpack()).unwrap();
    assert_eq!(back, json);
    assert_eq!(items.len(), 100_000);
    let _ = std::fs::remove_dir_all(&dir);
}

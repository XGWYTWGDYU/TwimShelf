//! Performance checks at personal-library scale. Run: `cargo test --release --test perf -- --ignored --nocapture`
use std::time::Instant;
use tl_core::library::{FeedRequest, Library};
use tl_core::model::{MediaKind, Origin, PostMeta, SearchScope};

fn req(terms: &[&str], fuzzy: bool) -> FeedRequest {
    FeedRequest { newest_first: false, terms: terms.iter().map(|s| s.to_string()).collect(), scope: SearchScope::Both, seed: Some(7), fuzzy, term_vectors: vec![], embed_model: None, threshold: 0.72, fields: Default::default(), filter: Default::default() }
}

#[test]
#[ignore]
fn feed_and_search_at_100k_media() {
    let dir = std::env::temp_dir().join(format!("tl-perf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let lib = Library::open(&dir).unwrap();
    let words = ["墙", "白墙", "猫", "天空", "城市", "夜景", "人像", "风景", "蓝色", "红色", "插画", "照片", "室内", "海", "山", "花", "狗", "车", "食物", "截图"];
    let t = Instant::now();
    {
        let db = lib.db();
        let tx = db.conn().unchecked_transaction().unwrap();
        for p in 0..40_000u32 {
            db.upsert_post(&PostMeta { id: format!("p{p}"), text: Some(format!("帖子 {p}")), author_name: Some("作者".into()), screen_name: Some("user".into()), url: None, created_at: None }).unwrap();
            for k in 0..(1 + p % 4) {
                let id = format!("{:064x}", (p as u64) << 8 | k as u64);
                db.add_media(&id, &format!("p{p}"), k as i64, &MediaKind::Photo, &format!("blobs/00/{id}.jpg"), false).unwrap();
                for j in 0..3 { db.tag_media(&id, words[((p as usize) * 7 + k as usize * 3 + j) % words.len()], if j == 0 { Origin::USER } else { Origin::AI }).unwrap(); }
            }
        }
        tx.commit().unwrap();
    }
    let media: i64 = lib.db().conn().query_row("SELECT count(*) FROM media", [], |r| r.get(0)).unwrap();
    println!("built {media} media / {} tag rows in {:?}", lib.db().conn().query_row("SELECT count(*) FROM tag_media", [], |r| r.get::<_, i64>(0)).unwrap(), t.elapsed());

    let mut report = vec![];
    for (name, r) in [("full feed (shuffled)", req(&[], true)), ("fuzzy 墙", req(&["墙"], true)), ("exact 墙", req(&["墙"], false)), ("fuzzy 墙+猫", req(&["墙", "猫"], true))] {
        let _ = lib.feed(&r).unwrap();
        let t = Instant::now();
        let n = lib.feed(&r).unwrap().len();
        report.push(format!("{name}: {n} items in {:?}", t.elapsed()));
    }
    for l in &report { println!("{l}"); }
    let t = Instant::now();
    let n = lib.feed(&req(&[], true)).unwrap().len();
    assert!(t.elapsed().as_millis() < 2000, "full feed of {n} items took {:?}", t.elapsed());
    std::fs::remove_dir_all(&dir).unwrap();
}

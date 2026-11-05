//! Two devices of one account find each other on the real local network (mDNS) and sync by
//! themselves — no address is handed over. Uses the machine's network, so it runs on demand:
//! `cargo test --test discovery -- --ignored --nocapture`.
use std::sync::Arc;
use std::time::{Duration, Instant};
use tl_core::discovery::Discovery;
use tl_core::library::Library;
use tl_core::model::{MediaKind, PostMeta};
use tl_core::sync::{Account, SyncNode};

fn post_count(l: &Library) -> i64 {
    l.db().conn().query_row("SELECT COUNT(*) FROM post", [], |r| r.get(0)).unwrap()
}

#[test]
#[ignore]
fn two_devices_find_each_other_and_sync() {
    let base = std::env::temp_dir().join(format!("tl-discovery-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let a = Arc::new(Library::open(base.join("a")).unwrap());
    let b = Arc::new(Library::open(base.join("b")).unwrap());
    let account = Account::generate();
    let (na, nb) = (SyncNode::new(a.clone()), SyncNode::new(b.clone()));
    let rt = tl_core::download::runtime();
    rt.block_on(na.start(Some(account.clone()), "Device A".into())).unwrap();
    rt.block_on(nb.start(Some(account.clone()), "Device B".into())).unwrap();

    // a post with one photo on A only
    let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
    bytes.extend_from_slice(b"discovery test photo");
    bytes.resize(4000, 7);
    let (sha, rel) = a.put_blob(&bytes, "jpg").unwrap();
    {
        let db = a.db();
        db.upsert_post(&PostMeta { id: "p1".into(), text: Some("found by discovery".into()), ..Default::default() }).unwrap();
        db.add_media(&sha, "p1", 0, &MediaKind::Photo, &rel, false).unwrap();
    }
    assert_eq!(post_count(&b), 0);

    let ty = format!("_twlib-t{}._tcp", std::process::id() % 10000);
    let da = Discovery::start(na.clone(), &ty, "Device A").unwrap();
    let db = Discovery::start(nb.clone(), &ty, "Device B").unwrap();
    da.changed();

    let t = Instant::now();
    let mut seen = false;
    while t.elapsed() < Duration::from_secs(90) {
        std::thread::sleep(Duration::from_millis(500));
        let peers_a = da.status().peers;
        if !seen && peers_a.iter().any(|p| p.name == "Device B" && p.host.is_some()) {
            seen = true;
            println!("A found B after {:?}", t.elapsed());
        }
        if post_count(&b) == 1 && b.dir.join(&rel).exists() {
            println!("synced after {:?}; A sees {:?}", t.elapsed(), da.status().peers.iter().map(|p| (&p.name, &p.host, p.port)).collect::<Vec<_>>());
            da.stop();
            db.stop();
            let _ = std::fs::remove_dir_all(&base);
            return;
        }
    }
    panic!("no sync within 90 s; A sees {:?}, B sees {:?}, A status {:?}",
        da.status().peers, db.status().peers, na.status().failed);
}

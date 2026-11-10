//! Network tests; run with `cargo test -- --ignored`.
use std::sync::Arc;
use tl_core::download::{self, DownloadRequest, Route};
use tl_core::library::{FeedRequest, Library};
use tl_core::model::SearchScope;

#[test]
#[ignore]
fn downloads_public_post_via_fxtwitter() {
    let dir = std::env::temp_dir().join(format!("tl-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let lib = Arc::new(Library::open(&dir).unwrap());
    // any public post with a photo or a video
    let url = std::env::var("TL_TEST_PUBLIC_POST_URL").expect("TL_TEST_PUBLIC_POST_URL");
    download::start(lib.clone(), DownloadRequest { urls: vec![url.clone(), url], concurrency: 2, interval_ms: 200, route: Route::Fx, revive: false, folder: None, mark_recent: false }).unwrap();
    while download::status().running { std::thread::sleep(std::time::Duration::from_millis(100)); }
    let s = download::status();
    assert_eq!(s.failed, 0, "{:?}", s.errors);
    let items = lib.feed(&FeedRequest { whole_posts: false, newest_first: false, terms: vec![], scope: SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() }).unwrap();
    assert_eq!(items.len(), 1);
    assert!(items[0].screen_name.is_some());
    let bytes = std::fs::metadata(&items[0].path).unwrap().len();
    println!("downloaded {} bytes -> {}", bytes, items[0].path);
    assert!(bytes > 10_000);
}

/// Protected posts: secrets are never printed, and malformed links are rejected locally without
/// trying the network.
#[test]
fn protected_posts_reject_bad_links_offline() {
    let c = tl_core::protected::Credentials { auth_token: "a".into(), ct0: "b".into() };
    assert_eq!(format!("{c:?}"), "Credentials { .. }", "secrets never printed");
    let rt = tl_core::download::runtime();
    let e = rt.block_on(tl_core::protected::fetch_post("not a status link", &c)).unwrap_err();
    assert!(matches!(e, tl_core::protected::ProtectedError::Other(_)), "{e:?}");
    let p = tl_core::protected::ProtectedPost { id: "9".into(), author_name: Some("N".into()), screen_name: Some("n".into()), text: Some("t".into()),
        created_at: None, url: Some("https://x.com/n/status/9".into()),
        media: vec![tl_core::protected::ProtectedMedia { kind: tl_core::protected::MediaKind::Video, url: "https://video.twimg.com/x.mp4".into(), headers: vec![("Referer".into(), "https://x.com/".into())] }] };
    let r = tl_core::protected::to_remote(p);
    assert_eq!((r.meta.id.as_str(), r.media[0].kind.clone(), r.media[0].headers.len()), ("9", tl_core::model::MediaKind::Video, 1));
}

/// The model store against the real API: metadata only, nothing is downloaded.
/// `cargo test --test live model_store -- --ignored --nocapture`
#[test]
#[ignore]
fn model_store_reads_the_real_api() {
    use tl_core::hub;
    let dir = std::env::temp_dir();
    for (format, known, arch_out) in [("gguf", "ggml-org/Qwen2.5-VL-3B-Instruct-GGUF", "bert"), ("mlx", "EZCon/Huihui-Qwen3-VL-4B-Instruct-abliterated-4bit-mlx", "bert")] {
        let p = hub::search(&dir, format, "", false, None).unwrap();
        println!("{format}: {} offered, {} hidden", p.items.len(), p.hidden.len());
        for r in p.items.iter().take(4) { println!("  {} {:?} {:?} {}", r.repo, r.architecture, r.params, r.tier); }
        for h in p.hidden.iter().take(4) { println!("  hidden {} : {}", h.repo, h.reason); }
        assert!(!p.items.is_empty());
        assert!(p.items.iter().all(|r| r.architecture.as_deref() != Some(arch_out)));
        let searched = hub::search(&dir, format, "qwen", false, None).unwrap();
        println!("  'qwen': {} offered, {} hidden, next {}", searched.items.len(), searched.hidden.len(), searched.next.is_some());
        let next = hub::search(&dir, format, "qwen", false, searched.next.as_deref()).unwrap();
        println!("  'qwen' next: {} offered", next.items.len());
        let claimed = hub::search(&dir, format, "", true, None).unwrap();
        println!("  low restriction: {} offered, {} hidden, claimed {}", claimed.items.len(), claimed.hidden.len(), claimed.items.iter().filter(|r| r.claims_uncensored).count());
        let d = hub::detail(&dir, format, known).unwrap();
        println!("  {known}: rev {} problem {:?}", d.revision, d.problem);
        for v in &d.variants { println!("    {} {} {} suggested={} {}", v.label, v.bytes, v.tier, v.suggested, v.folder); }
        assert!(d.problem.is_none() && !d.variants.is_empty(), "{known}");
        let typed = hub::search(&dir, format, &format!("https://huggingface.co/{known}"), false, None).unwrap();
        assert_eq!(typed.items.iter().map(|r| r.repo.as_str()).collect::<Vec<_>>(), [known]);
    }
    assert!(hub::detail(&dir, "gguf", "no-such-org-tl/no-such-model").is_err());
}

/// A real install at a pinned revision, of a test repo of a few hundred KB.
/// `cargo test --test live model_store_installs -- --ignored --nocapture`
#[test]
#[ignore]
fn model_store_installs_a_pinned_revision() {
    use tl_core::{hub, models};
    let dir = std::env::temp_dir().join(format!("tl-hub-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let info: serde_json::Value = reqwest::blocking::get("https://huggingface.co/api/models/hf-internal-testing/tiny-random-bert?expand[]=sha").unwrap().json().unwrap();
    let revision = info["sha"].as_str().unwrap().to_string();
    hub::install(&dir, hub::InstallRequest { format: "mlx".into(), repo: "hf-internal-testing/tiny-random-bert".into(), revision: Some(revision), weights: None, projector: None, bytes: 1, folder: None }).unwrap();
    let status = loop {
        let s = models::status().unwrap();
        if !s.running { break s; }
        std::thread::sleep(std::time::Duration::from_millis(200));
    };
    println!("{status:?}");
    assert!(status.finished, "{:?}", status.error);
    let installed = models::installed(&dir);
    assert_eq!(installed[0].id, "hf-internal-testing--tiny-random-bert");
    std::fs::remove_dir_all(&dir).unwrap();
}

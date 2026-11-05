//! C-ABI parity/performance and the main-isolate audit, using synthetic metadata only.
use std::ffi::{CStr, CString};
use std::time::{Duration, Instant};
use tl_core::{ffi::*, library::{Library, PackedFeed}, model::{MediaKind, PostMeta}};

fn text(value: &str) -> CString { CString::new(value).unwrap() }
fn take(pointer: *mut std::ffi::c_char) -> String {
    assert!(!pointer.is_null());
    let value = unsafe { CStr::from_ptr(pointer) }.to_str().unwrap().to_owned();
    tl_string_free(pointer); value
}
fn ok(pointer: *mut std::ffi::c_char) -> serde_json::Value {
    let json: serde_json::Value = serde_json::from_str(&take(pointer)).unwrap();
    assert!(json.get("error").is_none(), "{json}"); json["ok"].clone()
}
fn seed(count: usize) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("r6-synthetic-{}-{}", std::process::id(), rand::random::<u64>()));
    let library = Library::open(&root).unwrap();
    {
        let db = library.db(); db.conn().execute_batch("BEGIN").unwrap();
        for i in 0..count / 4 {
            let id = format!("synthetic-{i:06}");
            db.upsert_post(&PostMeta { id: id.clone(), author_name: Some(format!("Author {}", i % 300)), screen_name: Some(format!("user{}", i % 300)), text: Some("Synthetic post text for packed-feed and UI blocking measurements. ".repeat(2)), url: Some(format!("https://x.com/i/status/{i}")), created_at: Some("Fri Oct 24 08:13:11 +0000 2026".into()) }).unwrap();
            for k in 0..4 {
                let kind = if k == 3 { MediaKind::Video } else { MediaKind::Photo };
                db.add_media(&format!("m{i:06}_{k}"), &id, k, &kind, &format!("blobs/m{i}_{k}.jpg"), false).unwrap();
            }
        }
        db.conn().execute_batch("COMMIT").unwrap();
    }
    drop(library);
    assert!(tl_open(text(root.to_str().unwrap()).as_ptr()));
    ok(tl_tag(text("m000000_0").as_ptr(), text("synthetic tag").as_ptr(), 1));
    ok(tl_ai_apply(text(&serde_json::json!({"media_id":"m000000_1","model":"ext:synthetic","labels":["synthetic AI tag"],"replace_old":false,"epoch":ok(tl_epoch())}).to_string()).as_ptr()));
    root
}
fn fixtures(root: &std::path::Path, packed: &str, plain: &str) {
    if let Some(output) = std::env::var_os("R6_FIXTURES") {
        let directory = std::path::PathBuf::from(output); std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("packed.json"), packed).unwrap();
        std::fs::write(directory.join("plain.json"), plain).unwrap();
        std::fs::write(directory.join("library-path.txt"), root.to_string_lossy().as_bytes()).unwrap();
    }
}
#[test]
fn packed_ffi_and_plain_ffi_match() {
    let root = seed(32);
    let req = text(r#"{"scope":"both","seed":42}"#);
    let packed = take(tl_feed_packed(req.as_ptr()));
    let plain = take(tl_feed(req.as_ptr()));
    let envelope: serde_json::Value = serde_json::from_str(&packed).unwrap();
    let data: PackedFeed = serde_json::from_value(envelope["ok"].clone()).unwrap();
    let other: serde_json::Value = serde_json::from_str(&plain).unwrap();
    assert_eq!(serde_json::to_value(data.unpack()).unwrap(), other["ok"]);
    fixtures(&root, &packed, &plain);
}

#[test]
#[ignore = "100k synthetic metadata benchmark; run in release on demand"]
fn packed_100k_round_trip_and_ui_audit() {
    let root = seed(100_000);
    let req = text(r#"{"scope":"both","seed":42}"#);
    let start = Instant::now();
    let packed = take(tl_feed_packed(req.as_ptr()));
    let abi_time = start.elapsed();
    #[derive(serde::Deserialize)] struct Envelope { ok: PackedFeed }
    let decoded: Envelope = serde_json::from_str(&packed).unwrap();
    let unpacked = decoded.ok.unpack();
    let round_trip = start.elapsed();
    assert_eq!(unpacked.len(), 100_000);
    println!("tl_feed_packed ABI={abi_time:?}; complete round_trip={round_trip:?}; bytes={}", packed.len());
    if !cfg!(debug_assertions) { assert!(round_trip < Duration::from_secs(1), "packed round trip took {round_trip:?}"); }
    let plain = take(tl_feed(req.as_ptr()));
    let other: serde_json::Value = serde_json::from_str(&plain).unwrap();
    assert_eq!(serde_json::to_value(&unpacked).unwrap(), other["ok"]);
    fixtures(&root, &packed, &plain);
    macro_rules! measure { ($name:ident $(, $argument:expr)*) => {{
        let start = Instant::now(); let result = $name($($argument),*); let elapsed = start.elapsed();
        let value = take(result); let json: serde_json::Value = serde_json::from_str(&value).unwrap();
        println!("AUDIT {} {:.3} ms {}", stringify!($name), elapsed.as_secs_f64()*1000., if json.get("error").is_some() {"error"} else {"ok"});
    }}; }
    let start = Instant::now(); tl_set_cookies(text("").as_ptr(), text("").as_ptr());
    println!("AUDIT tl_set_cookies {:.3} ms ok", start.elapsed().as_secs_f64()*1000.);
    measure!(tl_epoch); measure!(tl_stats); measure!(tl_folder_overview);
    measure!(tl_all_tags); measure!(tl_media_tags, text("m000000_0").as_ptr());
    measure!(tl_setting, text("audio.headphonesOnly").as_ptr());
    measure!(tl_post_scope, text("synthetic-000000").as_ptr());
    measure!(tl_bin_snapshot); measure!(tl_import_reports);
    measure!(tl_integrity_summary); measure!(tl_ai_counts); measure!(tl_ai_failures);
    measure!(tl_create_folder, text("Synthetic folder").as_ptr());
    measure!(tl_tag_to_folder, text(r#"{"label":"synthetic tag","folder":"Synthetic folder"}"#).as_ptr());
    measure!(tl_rename_tag, text("synthetic tag").as_ptr(), text("renamed synthetic tag").as_ptr());
    measure!(tl_delete_tag, text("synthetic tag").as_ptr());
    measure!(tl_remove_ai_tags);
    measure!(tl_action, text(r#"{"kind":"tag","media":["m000000_0"],"label":"audit"}"#).as_ptr());
    let receipt = ok(tl_action(text(r#"{"kind":"trash","media":["m000003_0"]}"#).as_ptr()));
    measure!(tl_action_undo, text(&receipt.to_string()).as_ptr());
    measure!(tl_action, text(r#"{"kind":"trash","media":["m000002_0"]}"#).as_ptr());
    measure!(tl_bin_snapshot);
    measure!(tl_action, text(r#"{"kind":"purge","media":["m000002_0"]}"#).as_ptr());
    let account = tl_core::sync::Account::generate();
    measure!(tl_sync_start, text(&hex::encode(account.key)).as_ptr(), text("Synthetic audit").as_ptr());
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = socket.local_addr().unwrap().port(); drop(socket);
    measure!(tl_sync_join, text("127.0.0.1").as_ptr(), port, text("000000").as_ptr());
    measure!(tl_sync_status); measure!(tl_sync_pair_begin);
    let begin = Instant::now(); tl_sync_pair_cancel(); println!("AUDIT tl_sync_pair_cancel {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    measure!(tl_discovery_start, text("_twlib-debug._tcp").as_ptr(), text("Synthetic audit").as_ptr(), text("mac").as_ptr());
    measure!(tl_discovery_status);
    let begin = Instant::now(); tl_discovery_changed(); println!("AUDIT tl_discovery_changed {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    let begin = Instant::now(); tl_discovery_sync_now(); println!("AUDIT tl_discovery_sync_now {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    let begin = Instant::now(); tl_discovery_stop(); println!("AUDIT tl_discovery_stop {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    let begin = Instant::now(); take(tl_sync_new_account()); println!("AUDIT tl_sync_new_account {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    let start = Instant::now();
    let grid = tl_grid_new(1280., 720., 1., 0., 0., 100_000, 0, 0, 0.);
    println!("AUDIT tl_grid_new {:.3} ms ok", start.elapsed().as_secs_f64()*1000.);
    let mut out3 = [0.; 3]; let mut out4 = [0.; 4]; let mut tiles = [0.; 9000];
    macro_rules! geometry { ($name:ident $(, $argument:expr)*) => {{
        let start = Instant::now(); let _ = $name(grid $(, $argument)*);
        println!("AUDIT {} {:.3} ms ok", stringify!($name), start.elapsed().as_secs_f64()*1000.);
    }}; }
    geometry!(tl_grid_configure, 1280., 720., 1., 0., 0., 100_000);
    geometry!(tl_grid_rest, out3.as_mut_ptr()); geometry!(tl_grid_set_offset, 1.);
    geometry!(tl_grid_max_offset); geometry!(tl_grid_begin_pinch, 100., 100., 0.);
    geometry!(tl_grid_pinch_changed, 1.1, 100., 100.); geometry!(tl_grid_release, 0., 1.1);
    geometry!(tl_grid_tick, 0.1); geometry!(tl_grid_finish_now); geometry!(tl_grid_info, out4.as_mut_ptr());
    geometry!(tl_grid_tiles, tiles.as_mut_ptr(), 1000); geometry!(tl_grid_index_at, 100., 100.);
    geometry!(tl_grid_frame, 0, out3.as_mut_ptr()); geometry!(tl_grid_set_hidden, -1); geometry!(tl_grid_free);
    measure!(tl_verify_start);
    let begin = Instant::now(); tl_verify_cancel(); println!("AUDIT tl_verify_cancel {:.3} ms ok", begin.elapsed().as_secs_f64()*1000.);
    println!("SYNTHETIC_LIBRARY {}", root.display());
}

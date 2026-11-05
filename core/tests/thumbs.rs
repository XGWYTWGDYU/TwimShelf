use image::{ImageEncoder, Rgb, RgbImage, Rgba, RgbaImage};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tl_core::library::Library;
use tl_core::thumbs::{thumbnail, warm, ThumbError, ThumbResult};

struct TestDir(PathBuf);
impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct Fixture {
    lib: Library,
    temp: TestDir,
}
impl Fixture {
    fn new() -> Self {
        let temp = TestDir(std::env::temp_dir().join(format!(
            "tl-thumbs-{}-{:x}",
            std::process::id(),
            rand::random::<u64>()
        )));
        std::fs::create_dir_all(&temp.0).unwrap();
        let lib = Library::open(temp.0.join("library")).unwrap();
        Self { lib, temp }
    }
    fn cache(&self) -> PathBuf {
        self.temp.0.join("cache")
    }
    fn register(&self, id: &str, extension: &str, kind: &str, bytes: &[u8]) -> PathBuf {
        let relative = format!("synthetic-{id}.{extension}");
        let path = self.lib.dir.join(&relative);
        std::fs::write(&path, bytes).unwrap();
        let db = self.lib.db();
        let post = format!("post-{id}");
        db.conn()
            .execute("INSERT INTO post(id) VALUES(?1)", [&post])
            .unwrap();
        db.conn()
            .execute(
                "INSERT INTO media(id,post_id,ordinal,kind,path) VALUES(?1,?2,0,?3,?4)",
                rusqlite::params![id, post, kind, relative],
            )
            .unwrap();
        path
    }
    fn photo(&self, id: &str, image: &RgbImage) -> PathBuf {
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 95)
            .encode_image(image)
            .unwrap();
        self.register(id, "jpg", "photo", &bytes)
    }
}
fn cached(lib: &Library, id: &str, side: u32, cache: &Path) -> PathBuf {
    match thumbnail(lib, id, side, cache).unwrap() {
        ThumbResult::Image { path } => path.into(),
        _ => panic!("photo returned video result"),
    }
}
fn red(pixel: &Rgb<u8>) {
    assert!(
        pixel[0] > 210 && pixel[1] < 45 && pixel[2] < 45,
        "{pixel:?}"
    );
}
fn blue(pixel: &Rgb<u8>) {
    assert!(
        pixel[2] > 210 && pixel[0] < 45 && pixel[1] < 45,
        "{pixel:?}"
    );
}
fn green(pixel: &Rgb<u8>) {
    assert!(
        pixel[1] > 210 && pixel[0] < 45 && pixel[2] < 45,
        "{pixel:?}"
    );
}

fn exif_jpeg(image: &RgbImage, orientation: u16) -> Vec<u8> {
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 95)
        .encode_image(image)
        .unwrap();
    // Little-endian TIFF with one SHORT Orientation entry, wrapped in APP1.
    let mut exif =
        b"Exif\0\0II\x2a\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00".to_vec();
    exif.extend_from_slice(&orientation.to_le_bytes());
    exif.extend_from_slice(&[0; 6]);
    let mut result = jpeg[..2].to_vec();
    result.extend_from_slice(&[0xff, 0xe1]);
    result.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
    result.extend_from_slice(&exif);
    result.extend_from_slice(&jpeg[2..]);
    result
}

#[test]
fn orientation_6_and_8_are_applied() {
    let f = Fixture::new();
    let image = RgbImage::from_fn(120, 80, |x, _| {
        if x < 60 {
            Rgb([255, 0, 0])
        } else {
            Rgb([0, 0, 255])
        }
    });
    for orientation in [6, 8] {
        let id = format!("rotate{orientation}");
        f.register(&id, "jpg", "photo", &exif_jpeg(&image, orientation));
        let result = image::open(cached(&f.lib, &id, 64, &f.cache()))
            .unwrap()
            .to_rgb8();
        assert_eq!(result.dimensions(), (64, 64));
        if orientation == 6 {
            red(result.get_pixel(32, 8));
            blue(result.get_pixel(32, 56));
        } else {
            blue(result.get_pixel(32, 8));
            red(result.get_pixel(32, 56));
        }
    }
}

#[test]
fn wide_and_tall_images_are_centre_cropped() {
    let f = Fixture::new();
    for (id, w, h) in [("wide", 240, 80), ("tall", 80, 240)] {
        let image = RgbImage::from_fn(w, h, |x, y| {
            let coordinate = if w > h { x } else { y };
            if (80..160).contains(&coordinate) {
                Rgb([0, 255, 0])
            } else {
                Rgb([255, 0, 0])
            }
        });
        f.photo(id, &image);
        let result = image::open(cached(&f.lib, id, 64, &f.cache()))
            .unwrap()
            .to_rgb8();
        for (x, y) in [(4, 4), (60, 4), (32, 32), (4, 60), (60, 60)] {
            green(result.get_pixel(x, y));
        }
    }
}

#[test]
fn alpha_is_composited_on_white_before_filtering() {
    let f = Fixture::new();
    let image = RgbaImage::from_fn(80, 80, |x, _| {
        if x < 40 {
            Rgba([0, 0, 0, 0])
        } else {
            Rgba([255, 0, 0, 128])
        }
    });
    let mut bytes = Vec::new();
    image::codecs::png::PngEncoder::new(&mut bytes)
        .write_image(image.as_raw(), 80, 80, image::ExtendedColorType::Rgba8)
        .unwrap();
    f.register("alpha", "png", "photo", &bytes);
    let result = image::open(cached(&f.lib, "alpha", 64, &f.cache()))
        .unwrap()
        .to_rgb8();
    assert!(result.get_pixel(8, 32).0.iter().all(|v| *v > 245));
    let p = result.get_pixel(56, 32);
    assert!(
        p[0] > 245 && (115..140).contains(&p[1]) && (115..140).contains(&p[2]),
        "{p:?}"
    );
}

#[test]
fn rgb_icc_profile_is_converted_to_srgb_and_tagged() {
    use image::ImageDecoder;
    let f = Fixture::new();
    let source = RgbImage::from_pixel(80, 80, Rgb([230, 100, 20]));
    let mut bytes = Vec::new();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 100);
    encoder
        .set_icc_profile(moxcms::ColorProfile::new_display_p3().encode().unwrap())
        .unwrap();
    encoder.encode_image(&source).unwrap();
    f.register("profile", "jpg", "photo", &bytes);
    let path = cached(&f.lib, "profile", 64, &f.cache());
    let output = image::open(&path).unwrap().to_rgb8();
    let p = output.get_pixel(32, 32);
    assert!(p[0] > 235 && p[1] < 97 && p[2] < 12, "{p:?}");
    let mut decoder = image::codecs::jpeg::JpegDecoder::new(std::io::BufReader::new(
        std::fs::File::open(path).unwrap(),
    ))
    .unwrap();
    let mut profile = decoder.icc_profile().unwrap().unwrap();
    let mut expected = moxcms::ColorProfile::new_srgb().encode().unwrap();
    // ICC headers include the encoding time, which is not a color property.
    profile[24..36].fill(0);
    expected[24..36].fill(0);
    assert_eq!(profile, expected);
}

#[test]
fn corrupt_media_has_a_typed_not_decodable_error_and_no_cache_file() {
    let f = Fixture::new();
    f.register("corrupt", "jpg", "photo", b"not a picture");
    let error = thumbnail(&f.lib, "corrupt", 64, &f.cache()).unwrap_err();
    assert_eq!(
        error.downcast_ref::<ThumbError>(),
        Some(&ThumbError::NotDecodable)
    );
    assert_eq!(error.to_string(), "not_decodable");
    assert!(!f.cache().join("64/corrupt.jpg").exists());
}

#[test]
fn video_is_a_distinct_result_without_reading_the_original() {
    let f = Fixture::new();
    let original = f.register("video", "mp4", "video", b"synthetic video");
    std::fs::remove_file(original).unwrap();
    let result = thumbnail(&f.lib, "video", 384, &f.cache()).unwrap();
    assert_eq!(
        serde_json::to_value(result).unwrap(),
        serde_json::json!({"video": true})
    );
    assert!(!f.cache().exists());
}

#[test]
fn cache_hit_reuses_bytes_and_mtime_and_sizes_are_separate() {
    let f = Fixture::new();
    f.photo("cached", &RgbImage::from_pixel(100, 100, Rgb([255, 0, 0])));
    let path = cached(&f.lib, "cached", 64, &f.cache());
    let before = (
        std::fs::read(&path).unwrap(),
        std::fs::metadata(&path).unwrap().modified().unwrap(),
    );
    assert_eq!(cached(&f.lib, "cached", 64, &f.cache()), path);
    assert_eq!(std::fs::read(&path).unwrap(), before.0);
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        before.1
    );
    let large = cached(&f.lib, "cached", 128, &f.cache());
    assert_ne!(path, large);
    assert_eq!(image::image_dimensions(large).unwrap(), (128, 128));
}

#[test]
fn stale_or_invalid_cache_is_rebuilt() {
    let f = Fixture::new();
    let original = f.photo("stale", &RgbImage::from_pixel(80, 80, Rgb([255, 0, 0])));
    let path = cached(&f.lib, "stale", 64, &f.cache());
    let blue_image = RgbImage::from_pixel(80, 80, Rgb([0, 0, 255]));
    blue_image.save(&original).unwrap();
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH)
        .unwrap();
    cached(&f.lib, "stale", 64, &f.cache());
    blue(image::open(&path).unwrap().to_rgb8().get_pixel(32, 32));
    std::fs::write(&path, b"interrupted external cache write").unwrap();
    cached(&f.lib, "stale", 64, &f.cache());
    assert_eq!(image::image_dimensions(path).unwrap(), (64, 64));
}

#[test]
fn concurrent_requests_publish_only_complete_jpegs_and_leave_no_temp_files() {
    let f = Fixture::new();
    f.photo(
        "concurrent",
        &RgbImage::from_pixel(1200, 800, Rgb([0, 255, 0])),
    );
    let cache = f.cache();
    let start = std::sync::Barrier::new(8);
    std::thread::scope(|scope| {
        let handles: Vec<_> = (0..8)
            .map(|_| {
                scope.spawn(|| {
                    start.wait();
                    let path = cached(&f.lib, "concurrent", 128, &cache);
                    let result = image::open(path).unwrap().to_rgb8();
                    assert_eq!(result.dimensions(), (128, 128));
                    green(result.get_pixel(64, 64));
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
    });
    let files: Vec<_> = std::fs::read_dir(cache.join("128"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(files, [std::ffi::OsString::from("concurrent.jpg")]);
}

#[test]
fn warm_skips_cache_hits_errors_and_videos_and_obeys_cancellation() {
    let f = Fixture::new();
    f.photo("one", &RgbImage::from_pixel(80, 80, Rgb([255, 0, 0])));
    f.photo("two", &RgbImage::from_pixel(80, 80, Rgb([0, 0, 255])));
    f.register("video", "mp4", "video", b"video");
    f.register("bad", "png", "photo", b"bad");
    let ids = vec!["one".into(), "two".into(), "bad".into(), "video".into()];
    let cancel = AtomicBool::new(true);
    assert_eq!(warm(&f.lib, &ids, 64, &f.cache(), &cancel), 0);
    assert!(!f.cache().exists());
    cancel.store(false, Ordering::Release);
    let expected = if std::thread::available_parallelism().map_or(1, usize::from) > 2 {
        2
    } else {
        0
    };
    assert_eq!(warm(&f.lib, &ids, 64, &f.cache(), &cancel), expected);
    assert_eq!(warm(&f.lib, &ids, 64, &f.cache(), &cancel), 0);
}

#[test]
fn animated_gif_uses_the_first_frame() {
    let f = Fixture::new();
    let mut bytes = Vec::new();
    {
        let mut encoder = image::codecs::gif::GifEncoder::new(&mut bytes);
        encoder
            .encode_frame(image::Frame::new(RgbaImage::from_pixel(
                80,
                80,
                Rgba([255, 0, 0, 255]),
            )))
            .unwrap();
        encoder
            .encode_frame(image::Frame::new(RgbaImage::from_pixel(
                80,
                80,
                Rgba([0, 0, 255, 255]),
            )))
            .unwrap();
    }
    f.register("animated", "gif", "photo", &bytes);
    let result = image::open(cached(&f.lib, "animated", 64, &f.cache()))
        .unwrap()
        .to_rgb8();
    red(result.get_pixel(32, 32));
}

#[test]
fn animated_webp_uses_the_first_frame() {
    fn chunk(tag: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut bytes = tag.to_vec();
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(data);
        if data.len() % 2 != 0 {
            bytes.push(0);
        }
        bytes
    }
    let f = Fixture::new();
    // Build a two-frame WebP container around synthetic lossless frame chunks.
    let mut payload = b"WEBP".to_vec();
    payload.extend(chunk(b"VP8X", &[2, 0, 0, 0, 79, 0, 0, 79, 0, 0]));
    payload.extend(chunk(b"ANIM", &[0; 6]));
    for color in [[255, 0, 0], [0, 0, 255]] {
        let image = RgbImage::from_pixel(80, 80, Rgb(color));
        let mut still = Vec::new();
        image::codecs::webp::WebPEncoder::new_lossless(&mut still)
            .write_image(image.as_raw(), 80, 80, image::ExtendedColorType::Rgb8)
            .unwrap();
        let mut frame = vec![0, 0, 0, 0, 0, 0, 79, 0, 0, 79, 0, 0, 100, 0, 0, 2];
        frame.extend_from_slice(&still[12..]);
        payload.extend(chunk(b"ANMF", &frame));
    }
    let mut bytes = b"RIFF".to_vec();
    bytes.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    bytes.extend(payload);
    f.register("animatedWebp", "webp", "photo", &bytes);
    let output = image::open(cached(&f.lib, "animatedWebp", 64, &f.cache()))
        .unwrap()
        .to_rgb8();
    red(output.get_pixel(32, 32));
}

#[test]
fn invalid_sizes_ids_and_missing_media_do_not_create_files() {
    let f = Fixture::new();
    for side in [0, 8193, u32::MAX] {
        assert_eq!(
            thumbnail(&f.lib, "missing", side, &f.cache())
                .unwrap_err()
                .downcast_ref::<ThumbError>(),
            Some(&ThumbError::InvalidSize)
        );
    }
    assert_eq!(
        thumbnail(&f.lib, "../escape", 64, &f.cache())
            .unwrap_err()
            .downcast_ref::<ThumbError>(),
        Some(&ThumbError::InvalidId)
    );
    assert_eq!(
        thumbnail(&f.lib, "missing", 64, &f.cache())
            .unwrap_err()
            .downcast_ref::<ThumbError>(),
        Some(&ThumbError::NotFound)
    );
    assert!(!f.cache().exists());
}

#[test]
fn ffi_preserves_envelopes_typed_error_and_background_warm_api() {
    use std::ffi::{CStr, CString};
    use tl_core::ffi::*;
    fn read(p: *mut std::ffi::c_char) -> serde_json::Value {
        assert!(!p.is_null());
        let bytes = unsafe { CStr::from_ptr(p) }.to_bytes().to_vec();
        tl_string_free(p);
        serde_json::from_slice(&bytes).unwrap()
    }
    let f = Fixture::new();
    f.register("bad", "jpg", "photo", b"invalid");
    f.photo("ffiPhoto", &RgbImage::from_pixel(80, 80, Rgb([0, 255, 0])));
    let directory = CString::new(f.lib.dir.to_str().unwrap()).unwrap();
    assert!(tl_open(directory.as_ptr()));
    let cache = CString::new(f.cache().to_str().unwrap()).unwrap();
    let id = CString::new("bad").unwrap();
    assert_eq!(
        read(tl_thumbnail(id.as_ptr(), 64, cache.as_ptr())),
        serde_json::json!({"error": "not_decodable"})
    );
    let ids = CString::new(r#"["ffiPhoto"]"#).unwrap();
    assert_eq!(
        read(tl_thumbnails_warm(ids.as_ptr(), 64, cache.as_ptr())),
        serde_json::json!({"ok": null})
    );
    if std::thread::available_parallelism().map_or(1, usize::from) > 2 {
        let output = f.cache().join("64/ffiPhoto.jpg");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while !output.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        green(image::open(output).unwrap().to_rgb8().get_pixel(32, 32));
    }
    // Reuse the same coordinator for subsequent requests and cancel queued work.
    let empty = CString::new("[]").unwrap();
    assert_eq!(
        read(tl_thumbnails_warm(empty.as_ptr(), 64, cache.as_ptr())),
        serde_json::json!({"ok": null})
    );
    tl_thumbnails_warm_cancel();
}

#[test]
#[ignore = "run explicitly with cargo test --release --test thumbs thumbnail_benchmark -- --ignored --nocapture"]
fn thumbnail_benchmark() {
    let f = Fixture::new();
    let image = RgbImage::from_fn(4000, 3000, |x, y| {
        Rgb([
            ((x * 3 + y) % 256) as u8,
            ((x + y * 2) % 256) as u8,
            ((x / 4 + y / 3) % 256) as u8,
        ])
    });
    f.photo("benchmark", &image);
    let mut timings = Vec::new();
    for iteration in 0..6 {
        let cache = f.cache().join(iteration.to_string());
        let start = std::time::Instant::now();
        let path = cached(&f.lib, "benchmark", 384, &cache);
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        assert_eq!(image::image_dimensions(path).unwrap(), (384, 384));
        if iteration != 0 {
            timings.push(elapsed);
        }
    }
    let mean = timings.iter().sum::<f64>() / timings.len() as f64;
    eprintln!("4000x3000 JPEG -> 384 JPEG (cold thumbnail cache; mean of 5 after one warmup): {mean:.2} ms; samples {timings:?}");
    assert!(
        mean < 100.0,
        "thumbnail generation exceeded 100 ms: {mean:.2} ms"
    );
}

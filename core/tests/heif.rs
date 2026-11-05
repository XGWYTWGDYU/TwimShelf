#![cfg(feature = "heif")]
//! Synthetic 64x48 red pictures, made with sips (HEIC) and ffmpeg (AVIF).
use std::path::{Path, PathBuf};
use tl_core::{heif, thumbs};

fn sample(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data").join(name)
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("tl-heif-{name}-{:x}", rand::random::<u64>()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn reddish(p: [u8; 3]) {
    assert!(p[0] > 200 && p[1] < 90 && p[2] < 90, "{p:?}");
}

#[test]
fn decodes_heic_and_avif() {
    for name in ["sample.heic", "sample.avif"] {
        assert!(heif::is_heif(&sample(name)), "{name}");
        let d = heif::decode(&sample(name)).unwrap();
        assert_eq!(d.image.dimensions(), (64, 48), "{name}");
        let p = d.image.get_pixel(32, 24).0;
        reddish([p[0], p[1], p[2]]);
        assert_eq!(p[3], 255);
    }
}

#[test]
fn display_image_is_a_cached_jpeg_within_the_size() {
    let cache = temp("display");
    for name in ["sample.heic", "sample.avif"] {
        let path = thumbs::display_image(&sample(name), 32, &cache).unwrap();
        let shown = image::open(&path).unwrap().into_rgb8();
        assert_eq!(shown.dimensions(), (32, 24), "{name}");
        reddish(shown.get_pixel(16, 12).0);
        let made = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(thumbs::display_image(&sample(name), 32, &cache).unwrap(), path);
        assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), made, "served from the cache");
        // no larger than the original
        assert_eq!(image::image_dimensions(thumbs::display_image(&sample(name), 4096, &cache).unwrap()).unwrap(), (64, 48));
    }
    std::fs::remove_dir_all(cache).unwrap();
}

#[test]
fn damaged_files_are_refused_without_a_crash() {
    let dir = temp("damaged");
    let whole = std::fs::read(sample("sample.heic")).unwrap();
    for (name, bytes) in [("cut.heic", &whole[..whole.len() / 2]), ("head.heic", &whole[..24]), ("empty.heic", &[][..]), ("text.heic", &b"not a picture"[..])] {
        let file = dir.join(name);
        std::fs::write(&file, bytes).unwrap();
        assert!(heif::decode(&file).is_err(), "{name}");
        assert!(thumbs::display_image(&file, 64, &dir.join("cache")).is_err(), "{name}");
    }
    std::fs::remove_dir_all(dir).unwrap();
}

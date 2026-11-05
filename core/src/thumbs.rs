//! Portable, on-disk square JPEG thumbnails. Original media are never modified.
use crate::library::Library;
use image::{imageops, DynamicImage, ImageDecoder, ImageEncoder, ImageReader, RgbImage};
use moxcms::{ColorProfile, DataColorSpace, Layout, TransformOptions};
use rusqlite::OptionalExtension;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum ThumbResult {
    Image { path: String },
    Video { video: bool },
}

/// Machine-readable errors; front ends choose their own localized presentation.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ThumbError {
    #[error("not_decodable")]
    NotDecodable,
    #[error("invalid_thumbnail_size")]
    InvalidSize,
    #[error("invalid_media_id")]
    InvalidId,
    #[error("media_not_found")]
    NotFound,
}

pub(crate) fn check_side(side: u32) -> Result<(), ThumbError> {
    if side == 0 || side > 8192 {
        Err(ThumbError::InvalidSize)
    } else {
        Ok(())
    }
}

fn cache_path(media_id: &str, side: u32, cache_dir: &Path) -> anyhow::Result<PathBuf> {
    check_side(side)?;
    if media_id.is_empty()
        || !media_id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(ThumbError::InvalidId.into());
    }
    Ok(cache_dir
        .join(side.to_string())
        .join(format!("{media_id}.jpg")))
}

// Weak entries avoid retaining a mutex for every media ever displayed. The lock
// covers decoding as well as publication, so duplicate requests share that work.
type ImageLocks = Mutex<HashMap<PathBuf, Weak<Mutex<()>>>>;
static IMAGE_LOCKS: OnceLock<ImageLocks> = OnceLock::new();
fn image_lock(path: &Path) -> Arc<Mutex<()>> {
    let mut locks = IMAGE_LOCKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(lock) = locks.get(path).and_then(Weak::upgrade) {
        return lock;
    }
    if locks.len() >= 512 {
        locks.retain(|_, lock| lock.strong_count() != 0);
    }
    let lock = Arc::new(Mutex::new(()));
    locks.insert(path.to_owned(), Arc::downgrade(&lock));
    lock
}

fn fresh(cache: &Path, original: &Path, side: u32) -> bool {
    let Ok(meta) = fs::metadata(cache) else {
        return false;
    };
    if !meta.is_file() || meta.len() == 0 {
        return false;
    }
    let cached = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
    let source = fs::metadata(original)
        .and_then(|m| m.modified())
        .unwrap_or(std::time::UNIX_EPOCH);
    cached >= source && image::image_dimensions(cache).ok() == Some((side, side))
}

/// Returns a cached path, or the distinct video result for a front-end poster.
pub fn thumbnail(
    lib: &Library,
    media_id: &str,
    side: u32,
    cache_dir: &Path,
) -> anyhow::Result<ThumbResult> {
    thumbnail_inner(lib, media_id, side, cache_dir).map(|(result, _)| result)
}

fn thumbnail_inner(
    lib: &Library,
    media_id: &str,
    side: u32,
    cache_dir: &Path,
) -> anyhow::Result<(ThumbResult, bool)> {
    let cache = cache_path(media_id, side, cache_dir)?;
    // Release SQLite before any image IO or processing.
    let (relative, kind) = {
        let db = lib.db();
        db.conn()
            .query_row(
                "SELECT path,kind FROM media WHERE id=?1",
                [media_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
            .ok_or(ThumbError::NotFound)?
    };
    if kind == "video" {
        return Ok((ThumbResult::Video { video: true }, false));
    }
    let original = lib.dir.join(relative);
    let result = || ThumbResult::Image {
        path: cache.to_string_lossy().into_owned(),
    };
    if fresh(&cache, &original, side) {
        return Ok((result(), false));
    }
    let lock = image_lock(&cache);
    let _guard = lock.lock().unwrap_or_else(|e| e.into_inner());
    if fresh(&cache, &original, side) {
        return Ok((result(), false));
    }
    let image = square(&original, side)?;
    publish(&image, &cache)?;
    Ok((result(), true))
}

fn square(path: &Path, side: u32) -> anyhow::Result<RgbImage> {
    fn not_decodable<E>(_: E) -> ThumbError {
        ThumbError::NotDecodable
    }
    if crate::heif::is_heif(path) {
        let decoded = crate::heif::decode(path).map_err(not_decodable)?;
        return square_of(DynamicImage::ImageRgba8(decoded.image), decoded.icc, image::metadata::Orientation::NoTransforms, side);
    }
    let reader = ImageReader::open(path)
        .map_err(not_decodable)?
        .with_guessed_format()
        .map_err(not_decodable)?;
    let mut decoder = reader.into_decoder().map_err(not_decodable)?;
    let icc = decoder.icc_profile().ok().flatten();
    let exif = decoder.exif_metadata().ok().flatten();
    let orientation = exif
        .and_then(|bytes| {
            let bytes = bytes.strip_prefix(b"Exif\0\0").unwrap_or(&bytes).to_vec();
            exif::Reader::new().read_raw(bytes).ok()
        })
        .and_then(|exif| {
            exif.get_field(exif::Tag::Orientation, exif::In::PRIMARY)
                .and_then(|field| field.value.get_uint(0))
        })
        .and_then(|value| u8::try_from(value).ok())
        .and_then(image::metadata::Orientation::from_exif)
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    // ImageDecoder::read_image reads the first frame for GIF and animated WebP.
    let decoded = DynamicImage::from_decoder(decoder).map_err(not_decodable)?;
    square_of(decoded, icc, orientation, side)
}

/// Transparent parts on white.
fn flatten(decoded: DynamicImage) -> RgbImage {
    if decoded.color().has_alpha() {
        let rgba = decoded.into_rgba8();
        RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
            let p = rgba.get_pixel(x, y).0;
            let alpha = u32::from(p[3]);
            image::Rgb(std::array::from_fn(|c| {
                ((u32::from(p[c]) * alpha + 255 * (255 - alpha) + 127) / 255) as u8
            }))
        })
    } else {
        decoded.into_rgb8()
    }
}

fn square_of(
    decoded: DynamicImage,
    icc: Option<Vec<u8>>,
    orientation: image::metadata::Orientation,
    side: u32,
) -> anyhow::Result<RgbImage> {
    let rgb = flatten(decoded);
    let edge = rgb.width().min(rgb.height());
    if edge == 0 {
        return Err(ThumbError::NotDecodable.into());
    }
    let crop = imageops::crop_imm(
        &rgb,
        (rgb.width() - edge) / 2,
        (rgb.height() - edge) / 2,
        edge,
        edge,
    );
    // An area prefilter reduces large originals cheaply; CatmullRom provides the
    // final high-quality reconstruction without a huge full-resolution filter.
    let mut output = if edge > side * 2 {
        let reduced = imageops::thumbnail(&*crop, side * 2, side * 2);
        imageops::resize(&reduced, side, side, imageops::FilterType::CatmullRom)
    } else {
        imageops::resize(&*crop, side, side, imageops::FilterType::CatmullRom)
    };
    if let Some(icc) = icc {
        to_srgb(&mut output, &icc);
    }
    // Centre square cropping and isotropic resampling commute with EXIF's
    // quarter turns/reflections. Transform the small result, not 12M pixels.
    let mut output = DynamicImage::ImageRgb8(output);
    output.apply_orientation(orientation);
    Ok(output.into_rgb8())
}

fn to_srgb(image: &mut RgbImage, icc: &[u8]) {
    let Ok(profile) = ColorProfile::new_from_slice(icc) else {
        return;
    };
    // The decoder already expands grayscale and CMYK to RGB. Their source ICC
    // layouts cannot be applied to those expanded samples a second time.
    if profile.color_space != DataColorSpace::Rgb {
        return;
    }
    let Ok(transform) = profile.create_transform_8bit(
        Layout::Rgb,
        &ColorProfile::new_srgb(),
        Layout::Rgb,
        TransformOptions::default(),
    ) else {
        return;
    };
    let mut output = vec![0; image.as_raw().len()];
    if transform.transform(image.as_raw(), &mut output).is_ok() {
        image.as_mut().copy_from_slice(&output);
    }
}

struct Temp(PathBuf);
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn publish(image: &RgbImage, path: &Path) -> anyhow::Result<()> {
    let directory = path.parent().ok_or(ThumbError::InvalidId)?;
    fs::create_dir_all(directory)?;
    let temporary = directory.join(format!(
        ".thumb-{}-{:032x}.tmp",
        std::process::id(),
        rand::random::<u128>()
    ));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let temporary = Temp(temporary);
    let mut writer = BufWriter::new(file);
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut writer, 85);
    encoder.set_icc_profile(ColorProfile::new_srgb().encode()?)?;
    encoder.encode_image(image)?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    drop(writer);
    fs::rename(&temporary.0, path)?;
    // Best effort durability of the rename; opening directories is not portable.
    if let Ok(directory) = File::open(directory) {
        let _ = directory.sync_all();
    }
    Ok(())
}

/// A HEIC or AVIF file as a JPEG the front end's image decoder can read, at most `max_side` on its
/// long edge. Cached beside the thumbnails, and cleared with them.
pub fn display_image(original: &Path, max_side: u32, cache_dir: &Path) -> anyhow::Result<String> {
    check_side(max_side)?;
    let name = hex::encode(Sha256::digest(original.to_string_lossy().as_bytes()));
    let cache = cache_dir.join("display").join(max_side.to_string()).join(format!("{name}.jpg"));
    let current = || {
        let (Ok(cached), Ok(source)) = (fs::metadata(&cache), fs::metadata(original)) else {
            return false;
        };
        cached.len() > 0 && matches!((cached.modified(), source.modified()), (Ok(c), Ok(s)) if c >= s)
    };
    let done = || cache.to_string_lossy().into_owned();
    if current() {
        return Ok(done());
    }
    let lock = image_lock(&cache);
    let _guard = lock.lock().unwrap_or_else(|e| e.into_inner());
    if current() {
        return Ok(done());
    }
    let decoded = crate::heif::decode(original).map_err(|_| ThumbError::NotDecodable)?;
    let mut picture = decoded.image;
    if picture.width().max(picture.height()) > max_side {
        let long = u64::from(picture.width().max(picture.height()));
        let scaled = |edge: u32| ((u64::from(edge) * u64::from(max_side) + long / 2) / long).max(1) as u32;
        picture = imageops::thumbnail(&picture, scaled(picture.width()), scaled(picture.height()));
    }
    let mut rgb = flatten(DynamicImage::ImageRgba8(picture));
    if let Some(icc) = decoded.icc {
        to_srgb(&mut rgb, &icc);
    }
    publish(&rgb, &cache)?;
    Ok(done())
}

/// Two cores stay free for the app, but a machine with fewer still gets one worker.
fn warm_workers(cores: usize, ids: usize) -> usize { cores.saturating_sub(2).clamp(1, 4).min(ids) }

static WARM_SERIAL: Mutex<()> = Mutex::new(());
/// Makes missing thumbnails; returns the number newly generated (not cache hits
/// or videos). In-flight decodes finish on cancellation; no new ones are taken.
pub fn warm(
    lib: &Library,
    ids: &[String],
    side: u32,
    cache_dir: &Path,
    cancel: &AtomicBool,
) -> usize {
    let workers = warm_workers(std::thread::available_parallelism().map_or(1, usize::from), ids.len());
    if workers == 0 || check_side(side).is_err() || cancel.load(Ordering::Acquire) {
        return 0;
    }
    // Serialise warm generations across callers, keeping the global decode
    // worker budget even when a new FFI request cancels an older generation.
    let _guard = WARM_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let next = AtomicUsize::new(0);
    let made = AtomicUsize::new(0);
    let worker = || {
        while !cancel.load(Ordering::Acquire) {
            let index = next.fetch_add(1, Ordering::Relaxed);
            let Some(id) = ids.get(index) else {
                break;
            };
            if matches!(thumbnail_inner(lib, id, side, cache_dir), Ok((_, true))) {
                made.fetch_add(1, Ordering::Relaxed);
            }
        }
    };
    std::thread::scope(|scope| {
        for _ in 1..workers {
            scope.spawn(&worker);
        }
        // The background caller participates: total decode threads <= workers.
        worker();
    });
    made.load(Ordering::Relaxed)
}

#[cfg(all(test, feature = "heif"))]
mod heif_tests {
    use super::square;
    use std::path::Path;

    #[test]
    fn heic_and_avif_make_square_thumbnails() {
        for name in ["sample.heic", "sample.avif"] {
            let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data").join(name);
            let thumb = square(&file, 32).unwrap();
            assert_eq!(thumb.dimensions(), (32, 32), "{name}");
            let [r, g, b] = thumb.get_pixel(16, 16).0;
            assert!(r > 200 && g < 90 && b < 90, "{name}: {r} {g} {b}");
        }
    }
}

#[cfg(test)]
mod worker_tests {
    use super::*;

    #[test]
    fn a_machine_with_few_cores_still_warms() {
        assert_eq!(warm_workers(1, 10), 1);
        assert_eq!(warm_workers(2, 10), 1);
        assert_eq!(warm_workers(4, 10), 2);
        assert_eq!(warm_workers(32, 10), 4);
        assert_eq!(warm_workers(8, 0), 0, "nothing to do");
    }

    /// The grid marks a media damaged only for `NotDecodable`: a cache that cannot be written is
    /// another error, whatever the picture.
    #[test]
    fn a_cache_that_cannot_be_written_is_not_a_damaged_picture() {
        let d = std::env::temp_dir().join(format!("tl-thumb-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let lib = Library::open(d.join("lib")).unwrap();
        let source = d.join("x.png");
        DynamicImage::new_rgb8(8, 8).save(&source).unwrap();
        let kind = crate::model::MediaKind::Photo;
        let (sha, rel) = lib.put_file(&source, &kind, "png").unwrap();
        {
            let db = lib.db();
            db.upsert_post_checked(&crate::model::PostMeta { id: "1".into(), ..Default::default() }, |_, _| true).unwrap();
            db.add_media(&sha, "1", 0, &kind, &rel, false).unwrap();
        }
        let blocked = d.join("a-file");
        fs::write(&blocked, b"").unwrap();
        let error = thumbnail(&lib, &sha, 64, &blocked).unwrap_err();
        assert_ne!(error.downcast_ref::<ThumbError>(), Some(&ThumbError::NotDecodable), "{error:#}");
        assert!(thumbnail(&lib, &sha, 64, &d.join("cache")).is_ok());
        let _ = fs::remove_dir_all(&d);
    }
}

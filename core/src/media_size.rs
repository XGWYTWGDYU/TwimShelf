//! The width and height a media is shown at, read from the file's header: the cards in 浏览 are
//! as tall as their media, so the grid must know the shape before it loads anything. Kept per
//! media (the id is the content's hash, so a size never changes) in `media_size`, local like the
//! verification records: every device reads its own copies. A file that says nothing is stored
//! as 0×0, not asked again, and shown in the default shape.
use crate::library::Library;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Up to this many new media are read while a feed is being answered: what was just imported has
/// its shape at once. A library that has never been read goes through `fill_in_background`.
const READ_IN_FEED: usize = 64;
const BATCH: usize = 200;

static FILLING: AtomicBool = AtomicBool::new(false);

/// Whether the background pass is still reading: the apps show its sizes when it has finished.
pub fn filling() -> bool { FILLING.load(Ordering::SeqCst) }

/// (width, height) as displayed, rotation applied.
pub fn read(path: &Path, video: bool) -> Option<(u32, u32)> {
    let size = if video { movie_size(path) } else { image_size(path).or_else(|| heif_size(path)) };
    size.filter(|&(w, h)| w > 0 && h > 0)
}

/// Stores the sizes of those media (read outside of the database's lock).
fn store(lib: &Library, list: &[(String, String, String)]) -> anyhow::Result<()> {
    let sizes: Vec<(&str, u32, u32)> = list.iter().map(|(id, rel, kind)| {
        let (w, h) = read(&lib.dir.join(rel), kind == "video").unwrap_or((0, 0));
        (id.as_str(), w, h)
    }).collect();
    lib.db().set_media_sizes(&sizes)?;
    Ok(())
}

/// The media still without a size, when they are few enough to read right now.
pub fn read_few(lib: &Library) -> anyhow::Result<()> {
    let list = lib.db().media_without_size(READ_IN_FEED + 1)?;
    if !list.is_empty() && list.len() <= READ_IN_FEED { store(lib, &list)?; }
    Ok(())
}

/// Reads the sizes of all the media that have none, in the background.
pub fn fill_in_background(lib: Arc<Library>) {
    if lib.db().media_without_size(1).map_or(true, |l| l.is_empty()) { return; }
    if FILLING.swap(true, Ordering::SeqCst) { return; }
    let epoch = lib.epoch();
    let spawned = std::thread::Builder::new().name("tl-media-sizes".into()).spawn(move || {
        loop {
            // the library was replaced or wiped: this pass is over
            if lib.db_at(epoch).is_err() { break; }
            let Ok(list) = lib.db().media_without_size(BATCH) else { break };
            if list.is_empty() || store(&lib, &list).is_err() { break; }
        }
        FILLING.store(false, Ordering::SeqCst);
    });
    if spawned.is_err() { FILLING.store(false, Ordering::SeqCst); }
}

fn image_size(path: &Path) -> Option<(u32, u32)> {
    let (w, h) = image::ImageReader::open(path).ok()?.with_guessed_format().ok()?.into_dimensions().ok()?;
    // EXIF orientations 5 to 8 turn the picture on its side
    let turned = exif::Reader::new().read_from_container(&mut BufReader::new(File::open(path).ok()?)).ok()
        .and_then(|e| e.get_field(exif::Tag::Orientation, exif::In::PRIMARY).and_then(|f| f.value.get_uint(0)))
        .is_some_and(|o| (5..=8).contains(&o));
    Some(if turned { (h, w) } else { (w, h) })
}

/// The boxes of an ISO media file (MP4, MOV, HEIC, AVIF) between two offsets: (type, content
/// start, content end).
fn boxes(f: &mut BufReader<File>, mut at: u64, end: u64) -> Vec<([u8; 4], u64, u64)> {
    let mut found = Vec::new();
    while at + 8 <= end && found.len() < 4096 {
        let mut head = [0u8; 8];
        if f.seek(SeekFrom::Start(at)).is_err() || f.read_exact(&mut head).is_err() { break; }
        let mut size = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as u64;
        let mut start = at + 8;
        if size == 1 {
            let mut long = [0u8; 8];
            if f.read_exact(&mut long).is_err() { break; }
            size = u64::from_be_bytes(long);
            start += 8;
        } else if size == 0 {
            size = end - at;
        }
        let stop = at.saturating_add(size);
        if size < start - at || stop > end { break; }
        found.push(([head[4], head[5], head[6], head[7]], start, stop));
        at = stop;
    }
    found
}

fn open_iso(path: &Path) -> Option<(BufReader<File>, u64)> {
    let f = File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    Some((BufReader::new(f), len))
}

fn read_at<const N: usize>(f: &mut BufReader<File>, at: u64) -> Option<[u8; N]> {
    let mut b = [0u8; N];
    f.seek(SeekFrom::Start(at)).ok()?;
    f.read_exact(&mut b).ok()?;
    Some(b)
}

/// The first track with a picture: moov/trak/tkhd holds its size and its rotation.
fn movie_size(path: &Path) -> Option<(u32, u32)> {
    let (mut f, len) = open_iso(path)?;
    let (_, moov_start, moov_end) = boxes(&mut f, 0, len).into_iter().find(|b| &b.0 == b"moov")?;
    for (name, start, end) in boxes(&mut f, moov_start, moov_end) {
        if &name != b"trak" { continue; }
        let Some((_, tkhd, _)) = boxes(&mut f, start, end).into_iter().find(|b| &b.0 == b"tkhd") else { continue };
        let version = read_at::<1>(&mut f, tkhd)?[0];
        let matrix = tkhd + if version == 1 { 52 } else { 40 };
        let m = read_at::<44>(&mut f, matrix)?;
        let word = |i: usize| u32::from_be_bytes([m[i], m[i + 1], m[i + 2], m[i + 3]]);
        let (w, h) = (word(36) >> 16, word(40) >> 16);
        if w == 0 || h == 0 { continue; }
        // a matrix with nothing on its first diagonal: a quarter turn
        return Some(if word(0) == 0 && word(4) != 0 { (h, w) } else { (w, h) });
    }
    None
}

/// HEIC and AVIF: meta/iprp/ipco holds the pictures' sizes (the largest is the picture itself,
/// the others its thumbnails) and the rotation.
fn heif_size(path: &Path) -> Option<(u32, u32)> {
    let (mut f, len) = open_iso(path)?;
    let top = boxes(&mut f, 0, len);
    if &top.first()?.0 != b"ftyp" { return None; }
    let meta = top.iter().find(|b| &b.0 == b"meta")?;
    let iprp = boxes(&mut f, meta.1 + 4, meta.2).into_iter().find(|b| &b.0 == b"iprp")?;
    let ipco = boxes(&mut f, iprp.1, iprp.2).into_iter().find(|b| &b.0 == b"ipco")?;
    let mut best: Option<(u32, u32)> = None;
    let mut turned = false;
    for (name, start, _) in boxes(&mut f, ipco.1, ipco.2) {
        if &name == b"ispe" {
            let b = read_at::<12>(&mut f, start)?;
            let w = u32::from_be_bytes([b[4], b[5], b[6], b[7]]);
            let h = u32::from_be_bytes([b[8], b[9], b[10], b[11]]);
            if best.map_or(true, |(bw, bh)| w as u64 * h as u64 > bw as u64 * bh as u64) { best = Some((w, h)); }
        } else if &name == b"irot" {
            turned |= read_at::<1>(&mut f, start)?[0] & 1 == 1;
        }
    }
    best.map(|(w, h)| if turned { (h, w) } else { (w, h) })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("tl-size-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d.join(name)
    }
    fn iso(name: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(name);
        v.extend_from_slice(body);
        v
    }
    fn tkhd(version: u8, a: u32, b: u32, w: u32, h: u32) -> Vec<u8> {
        let mut body = vec![version, 0, 0, 0];
        body.extend(vec![0u8; if version == 1 { 48 } else { 36 }]);
        body.extend_from_slice(&a.to_be_bytes());
        body.extend_from_slice(&b.to_be_bytes());
        body.extend(vec![0u8; 28]);
        body.extend_from_slice(&(w << 16).to_be_bytes());
        body.extend_from_slice(&(h << 16).to_be_bytes());
        iso(b"tkhd", &body)
    }

    #[test]
    fn pictures_and_rotation() {
        let p = tmp("a.png");
        image::RgbImage::new(30, 20).save(&p).unwrap();
        assert_eq!(read(&p, false), Some((30, 20)));
        let junk = tmp("junk.jpg");
        std::fs::write(&junk, b"<html>not a picture</html>").unwrap();
        assert_eq!(read(&junk, false), None);
    }

    #[test]
    fn exif_orientation_turns_the_size() {
        // SOI, APP1 with Orientation = 6, then a real JPEG's remainder
        let mut enc = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut enc).encode(&vec![0u8; 3 * 40 * 10], 40, 10, image::ExtendedColorType::Rgb8).unwrap();
        let tiff: &[u8] = &[b'M', b'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0];
        let mut app1 = b"Exif\0\0".to_vec();
        app1.extend_from_slice(tiff);
        let mut out = vec![0xFF, 0xD8, 0xFF, 0xE1];
        out.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&app1);
        out.extend_from_slice(&enc[2..]);
        let p = tmp("turned.jpg");
        std::fs::write(&p, out).unwrap();
        assert_eq!(read(&p, false), Some((10, 40)));
    }

    #[test]
    fn movies_with_and_without_rotation() {
        let audio = iso(b"trak", &tkhd(0, 0x10000, 0, 0, 0));
        for (version, a, b, want) in [(0u8, 0x10000u32, 0u32, (1920, 1080)), (1, 0x10000, 0, (1920, 1080)), (0, 0, 0x10000, (1080, 1920))] {
            let video = iso(b"trak", &tkhd(version, a, b, 1920, 1080));
            let mut file = iso(b"ftyp", b"isom");
            file.extend(iso(b"mdat", &[0u8; 64]));
            file.extend(iso(b"moov", &[audio.clone(), video].concat()));
            let p = tmp("m.mp4");
            std::fs::write(&p, file).unwrap();
            assert_eq!(read(&p, true), Some(want));
        }
        let p = tmp("n.mp4");
        std::fs::write(&p, b"not a movie at all").unwrap();
        assert_eq!(read(&p, true), None);
    }

    #[test]
    fn heif_takes_the_largest_picture_and_its_rotation() {
        let ispe = |w: u32, h: u32| iso(b"ispe", &[&[0u8; 4][..], &w.to_be_bytes(), &h.to_be_bytes()].concat());
        for (rotation, want) in [(None, (4032, 3024)), (Some(1u8), (3024, 4032)), (Some(2u8), (4032, 3024))] {
            let mut props = [ispe(320, 240), ispe(4032, 3024)].concat();
            if let Some(r) = rotation { props.extend(iso(b"irot", &[r])); }
            let iprp = iso(b"iprp", &iso(b"ipco", &props));
            let meta = iso(b"meta", &[&[0u8; 4][..], &iprp].concat());
            let file = [iso(b"ftyp", b"heic"), meta].concat();
            let p = tmp("p.heic");
            std::fs::write(&p, file).unwrap();
            assert_eq!(read(&p, false), Some(want));
        }
    }

    /// A box that says it is larger than the file, or too small: nothing is read past it.
    #[test]
    fn broken_boxes_end_the_walk() {
        let mut file = iso(b"ftyp", b"isom");
        file.extend_from_slice(&u32::MAX.to_be_bytes());
        file.extend_from_slice(b"moov");
        let p = tmp("broken.mp4");
        std::fs::write(&p, &file).unwrap();
        assert_eq!(read(&p, true), None);
        let mut small = 4u32.to_be_bytes().to_vec();
        small.extend_from_slice(b"moov");
        std::fs::write(&p, small).unwrap();
        assert_eq!(read(&p, true), None);
    }

    #[test]
    fn the_feed_carries_the_size_and_asks_a_file_once() {
        let d = std::env::temp_dir().join(format!("tl-size-lib-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let src = d.join("src/帖子");
        std::fs::create_dir_all(&src).unwrap();
        let mut png = Vec::new();
        image::RgbImage::new(30, 20).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        std::fs::write(src.join("1.png"), &png).unwrap();
        let lib = Arc::new(Library::open(d.join("lib")).unwrap());
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let req = crate::library::FeedRequest { newest_first: false, terms: vec![], scope: crate::model::SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() };
        let items = lib.feed(&req).unwrap();
        assert_eq!(items[0].size, Some((30, 20)));
        let packed = lib.feed_packed(&req).unwrap();
        assert_eq!(packed.unpack()[0].size, Some((30, 20)));
        assert!(lib.db().media_without_size(10).unwrap().is_empty());
        // the file goes bad later: the size stands, and nothing rereads it
        std::fs::write(&items[0].path, b"x").unwrap();
        assert_eq!(lib.feed(&req).unwrap()[0].size, Some((30, 20)));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_file_without_a_size_is_read_once_and_a_large_library_fills_in_the_background() {
        let d = std::env::temp_dir().join(format!("tl-size-bg-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let src = d.join("src/帖子");
        std::fs::create_dir_all(&src).unwrap();
        for i in 0..(READ_IN_FEED + 5) {
            std::fs::write(src.join(format!("{i}.jpg")), crate::testutil::jpg(format!("{i}").as_bytes())).unwrap();
        }
        let lib = Arc::new(Library::open(d.join("lib")).unwrap());
        lib.import_legacy_dir(&d.join("src")).unwrap();
        let req = crate::library::FeedRequest { newest_first: false, terms: vec![], scope: crate::model::SearchScope::Both, seed: Some(0), fuzzy: true, term_vectors: vec![], embed_model: None, threshold: 0.7, fields: Default::default(), filter: Default::default() };
        // too many to read while answering
        assert_eq!(lib.db().media_without_size(1000).unwrap().len(), READ_IN_FEED + 5);
        lib.feed(&req).unwrap();
        assert_eq!(lib.db().media_without_size(1000).unwrap().len(), READ_IN_FEED + 5);
        fill_in_background(lib.clone());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while filling() && std::time::Instant::now() < deadline { std::thread::sleep(std::time::Duration::from_millis(20)); }
        assert!(lib.db().media_without_size(10).unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }
}

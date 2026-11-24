//! The picture a model is shown: the right way up, at most 896 on its long side, at least 112 on its
//! short one, no longer than 4 to 1 (padded with black), as a JPEG at quality 80. The same for every
//! model, on the device or a service.
use image::{imageops, ImageEncoder, RgbImage};
use std::path::Path;

pub const LONG_SIDE: u32 = 896;
const SHORT_SIDE: u32 = 112;

/// The picture at `path` (a photo, or a frame the app took from a video) as a model is shown it.
pub fn tagging_jpeg(path: &Path) -> anyhow::Result<Vec<u8>> {
    prepare(crate::thumbs::upright(path)?)
}

/// `picture` as a model is shown it.
pub fn prepare(mut picture: RgbImage) -> anyhow::Result<Vec<u8>> {
    anyhow::ensure!(picture.width() > 0 && picture.height() > 0, "empty picture");
    let (w, h) = (picture.width(), picture.height());
    if w.max(h) > LONG_SIDE {
        let long = u64::from(w.max(h));
        let scaled = |edge: u32| ((u64::from(edge) * u64::from(LONG_SIDE) + long / 2) / long).max(1) as u32;
        picture = imageops::thumbnail(&picture, scaled(w), scaled(h));
    }
    let (w, h) = (picture.width(), picture.height());
    let (short, long) = (w.min(h) as f64, w.max(h) as f64);
    let ceiling = if (LONG_SIDE as f64) / long < 1.0 { 1.0 } else { LONG_SIDE as f64 / long };
    let scale = (SHORT_SIDE as f64 / short).clamp(1.0, ceiling.max(1.0));
    if scale > 1.0 {
        picture = imageops::resize(&picture, (w as f64 * scale).round() as u32, (h as f64 * scale).round() as u32, imageops::FilterType::Triangle);
    }
    let (w, h) = (picture.width(), picture.height());
    let (pw, ph) = (w.max(h.div_ceil(4)), h.max(w.div_ceil(4)));
    if (pw, ph) != (w, h) {
        let mut canvas = RgbImage::new(pw, ph);
        imageops::overlay(&mut canvas, &picture, i64::from((pw - w) / 2), i64::from((ph - h) / 2));
        picture = canvas;
    }
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 80).write_image(picture.as_raw(), picture.width(), picture.height(), image::ExtendedColorType::Rgb8)?;
    Ok(out)
}

/// A plain grey picture, to try a model with.
pub fn grey() -> Vec<u8> {
    prepare(RgbImage::from_pixel(SHORT_SIDE, SHORT_SIDE, image::Rgb([128, 128, 128]))).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size(jpeg: &[u8]) -> (u32, u32) {
        let i = image::load_from_memory(jpeg).unwrap();
        (i.width(), i.height())
    }

    #[test]
    fn sizes() {
        assert_eq!(size(&prepare(RgbImage::new(4000, 3000)).unwrap()), (896, 672));
        assert_eq!(size(&prepare(RgbImage::new(50, 100)).unwrap()), (112, 224));
        // too long: padded to 4 to 1
        assert_eq!(size(&prepare(RgbImage::new(896, 100)).unwrap()), (896, 224));
        assert_eq!(size(&grey()), (112, 112));
    }
}

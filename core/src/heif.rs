//! HEIC and AVIF stills: libheif, in the Flutter app's builds of the core (the `heif` feature).
//! The native Apple apps have ImageIO and do not carry it.
use crate::rules::{sniff, Sniff};
use std::io::Read;
use std::path::Path;

pub struct Decoded {
    pub image: image::RgbaImage,
    pub icc: Option<Vec<u8>>,
}

/// Judged by the file's own first bytes: an extension can be wrong.
pub fn is_heif(path: &Path) -> bool {
    let mut head = [0u8; 32];
    let Ok(mut file) = std::fs::File::open(path) else { return false };
    let n = file.read(&mut head).unwrap_or(0);
    sniff(&head[..n]) == Sniff::Heif
}

#[cfg(not(feature = "heif"))]
pub fn decode(_path: &Path) -> anyhow::Result<Decoded> {
    anyhow::bail!("not_decodable")
}

#[cfg(feature = "heif")]
pub fn decode(path: &Path) -> anyhow::Result<Decoded> {
    // read here, not by libheif: its file paths do not take every name on Windows
    let bytes = std::fs::read(path)?;
    unsafe { ffi::decode(&bytes) }
}

#[cfg(feature = "heif")]
mod ffi {
    use super::Decoded;
    use std::ffi::{c_char, c_int, c_void, CStr};
    use std::ptr::{null, null_mut};

    /// A larger picture is refused rather than decoded: 4 bytes a pixel, all of it in memory.
    const MAX_PIXELS: u64 = 200_000_000;

    #[repr(C)]
    struct Error {
        code: c_int,
        subcode: c_int,
        message: *const c_char,
    }
    enum Context {}
    enum Handle {}
    enum Image {}
    const COLORSPACE_RGB: c_int = 1;
    const CHROMA_INTERLEAVED_RGBA: c_int = 11;
    const CHANNEL_INTERLEAVED: c_int = 10;

    extern "C" {
        fn heif_init(params: *mut c_void) -> Error;
        fn heif_context_alloc() -> *mut Context;
        fn heif_context_free(context: *mut Context);
        fn heif_context_read_from_memory_without_copy(context: *mut Context, memory: *const c_void, size: usize, options: *const c_void) -> Error;
        fn heif_context_get_primary_image_handle(context: *mut Context, handle: *mut *mut Handle) -> Error;
        fn heif_image_handle_release(handle: *const Handle);
        fn heif_image_handle_get_width(handle: *const Handle) -> c_int;
        fn heif_image_handle_get_height(handle: *const Handle) -> c_int;
        fn heif_image_handle_get_raw_color_profile_size(handle: *const Handle) -> usize;
        fn heif_image_handle_get_raw_color_profile(handle: *const Handle, data: *mut c_void) -> Error;
        fn heif_decode_image(handle: *const Handle, image: *mut *mut Image, colorspace: c_int, chroma: c_int, options: *const c_void) -> Error;
        fn heif_image_release(image: *const Image);
        fn heif_image_get_width(image: *const Image, channel: c_int) -> c_int;
        fn heif_image_get_height(image: *const Image, channel: c_int) -> c_int;
        fn heif_image_get_plane_readonly2(image: *const Image, channel: c_int, stride: *mut usize) -> *const u8;
    }

    fn check(error: Error) -> anyhow::Result<()> {
        if error.code == 0 {
            return Ok(());
        }
        let message = if error.message.is_null() { String::new() } else { unsafe { CStr::from_ptr(error.message) }.to_string_lossy().into_owned() };
        anyhow::bail!("heif: {message}")
    }

    struct Owned<T>(*mut T, unsafe extern "C" fn(*mut T));
    impl<T> Drop for Owned<T> {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { (self.1)(self.0) }
            }
        }
    }
    unsafe extern "C" fn free_handle(p: *mut Handle) { heif_image_handle_release(p) }
    unsafe extern "C" fn free_image(p: *mut Image) { heif_image_release(p) }

    /// The primary picture, turned the way its file says (libheif applies that itself).
    pub(super) unsafe fn decode(bytes: &[u8]) -> anyhow::Result<Decoded> {
        static INIT: std::sync::Once = std::sync::Once::new();
        INIT.call_once(|| {
            let _ = heif_init(null_mut());
        });
        let context = Owned(heif_context_alloc(), heif_context_free);
        anyhow::ensure!(!context.0.is_null(), "heif: no context");
        check(heif_context_read_from_memory_without_copy(context.0, bytes.as_ptr().cast(), bytes.len(), null()))?;
        let mut handle = null_mut();
        check(heif_context_get_primary_image_handle(context.0, &mut handle))?;
        let handle = Owned(handle, free_handle);
        let pixels = u64::try_from(heif_image_handle_get_width(handle.0)).unwrap_or(0) * u64::try_from(heif_image_handle_get_height(handle.0)).unwrap_or(0);
        anyhow::ensure!(pixels > 0 && pixels <= MAX_PIXELS, "heif: {pixels} pixels");
        let icc = match heif_image_handle_get_raw_color_profile_size(handle.0) {
            0 => None,
            size => {
                let mut data = vec![0u8; size];
                check(heif_image_handle_get_raw_color_profile(handle.0, data.as_mut_ptr().cast())).ok().map(|_| data)
            }
        };
        let mut image = null_mut();
        check(heif_decode_image(handle.0, &mut image, COLORSPACE_RGB, CHROMA_INTERLEAVED_RGBA, null()))?;
        let image = Owned(image, free_image);
        let width = usize::try_from(heif_image_get_width(image.0, CHANNEL_INTERLEAVED))?;
        let height = usize::try_from(heif_image_get_height(image.0, CHANNEL_INTERLEAVED))?;
        let mut stride = 0usize;
        let plane = heif_image_get_plane_readonly2(image.0, CHANNEL_INTERLEAVED, &mut stride);
        anyhow::ensure!(!plane.is_null() && stride >= width * 4, "heif: no pixels");
        let mut rgba = Vec::with_capacity(width * height * 4);
        for y in 0..height {
            rgba.extend_from_slice(std::slice::from_raw_parts(plane.add(y * stride), width * 4));
        }
        let image = image::RgbaImage::from_raw(width as u32, height as u32, rgba).ok_or_else(|| anyhow::anyhow!("heif: size"))?;
        Ok(Decoded { image, icc })
    }
}

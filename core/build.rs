fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    #[cfg(feature = "heif")]
    heif::build();
}

/// HEIC and AVIF for the Flutter app: libheif with libde265 and dav1d, from pinned sources, built
/// the same way on every target and linked in statically, so no system library is needed.
#[cfg(feature = "heif")]
mod heif {
    use std::path::{Path, PathBuf};
    use std::process::Command;

    fn config(source: &Path, out: &Path, name: &str) -> cmake::Config {
        let mut c = cmake::Config::new(source);
        // always Release: on Windows the runtime has to match what Rust links
        c.profile("Release").out_dir(out.join(name)).define("BUILD_SHARED_LIBS", "OFF").define("CMAKE_INSTALL_LIBDIR", "lib").define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");
        let target = std::env::var("TARGET").unwrap();
        if target.contains("android") {
            let ndk = PathBuf::from(std::env::var_os("ANDROID_NDK_HOME").expect("ANDROID_NDK_HOME"));
            let abi = match target.split('-').next().unwrap() {
                "aarch64" => "arm64-v8a",
                "armv7" => "armeabi-v7a",
                "x86_64" => "x86_64",
                other => panic!("no Android ABI for {other}"),
            };
            c.define("CMAKE_TOOLCHAIN_FILE", forward(&ndk.join("build/cmake/android.toolchain.cmake"))).define("ANDROID_ABI", abi).define("ANDROID_PLATFORM", "android-31");
            // that toolchain looks for make only inside the NDK: the SDK's own Ninja, on every host
            c.generator("Ninja").define("CMAKE_MAKE_PROGRAM", forward(&sdk_ninja()));
        }
        c
    }

    /// CMake reads a backslash as an escape.
    fn forward(path: &Path) -> String {
        path.to_string_lossy().replace('\\', "/")
    }

    fn sdk_ninja() -> PathBuf {
        let sdk = PathBuf::from(std::env::var_os("ANDROID_HOME").expect("ANDROID_HOME")).join("cmake");
        let mut versions: Vec<_> = std::fs::read_dir(&sdk).unwrap_or_else(|e| panic!("{}: {e}", sdk.display())).flatten().map(|e| e.path()).collect();
        versions.sort();
        let exe = if cfg!(windows) { "ninja.exe" } else { "ninja" };
        versions.iter().rev().map(|v| v.join("bin").join(exe)).find(|n| n.exists()).unwrap_or_else(|| panic!("no Ninja under {}", sdk.display()))
    }

    /// `libde265.a` or `libde265.lib` or `de265.lib`: the file decides the name to link.
    fn library(root: &Path, stem: &str) -> (PathBuf, String) {
        let dir = root.join("lib");
        for entry in std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display())).flatten() {
            let file = entry.file_name().to_string_lossy().into_owned();
            let Some((base, ext)) = file.rsplit_once('.') else { continue };
            if (ext == "a" || ext == "lib") && base.trim_start_matches("lib") == stem {
                return (entry.path(), if ext == "a" { base.trim_start_matches("lib").to_string() } else { base.to_string() });
            }
        }
        panic!("{stem} not built in {}", dir.display());
    }

    pub fn build() {
        for f in ["heif/fetch.cmake", "heif/dav1d/CMakeLists.txt"] {
            println!("cargo:rerun-if-changed={f}");
        }
        let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
        // one copy of the sources for all targets, with the build's caches
        let sources = std::env::var_os("CARGO_TARGET_DIR").map_or_else(|| out.join("heif-src"), |d| PathBuf::from(d).join("heif-src"));
        std::fs::create_dir_all(&sources).unwrap();
        let cmake_tool = std::env::var_os("CMAKE").unwrap_or_else(|| "cmake".into());
        let status = Command::new(&cmake_tool).arg(format!("-DDEST={}", sources.display())).arg("-P").arg("heif/fetch.cmake").status().expect("cmake is needed to build HEIC and AVIF support");
        assert!(status.success(), "fetching the HEIC and AVIF decoders failed");

        let target = std::env::var("TARGET").unwrap();
        let de265 = config(&sources.join("libde265-1.1.3"), &out, "de265")
            .define("ENABLE_SDL", "OFF")
            .define("ENABLE_ENCODER", "OFF")
            .define("ENABLE_DECODER", "OFF")
            .define("ENABLE_AVX512", "OFF")
            // 32-bit ARM's kernels are assembly files: left out, as for dav1d. On x86-64 Android
            // its CPU check does not link into a shared library (only emulators run that target).
            .define("ENABLE_SIMD", if target.starts_with("armv7") || target == "x86_64-linux-android" { "OFF" } else { "ON" })
            .build();
        let dav1d = config(Path::new("heif/dav1d"), &out, "dav1d").define("DAV1D_SOURCE", forward(&sources.join("dav1d-1.5.3"))).build();
        let (de265_lib, de265_name) = library(&de265, "de265");
        let (dav1d_lib, dav1d_name) = library(&dav1d, "dav1d");

        let mut heif = config(&sources.join("libheif-1.23.7"), &out, "heif");
        heif.cflag("-DLIBDE265_STATIC_BUILD=1 -DLIBHEIF_STATIC_BUILD=1").cxxflag("-DLIBDE265_STATIC_BUILD=1 -DLIBHEIF_STATIC_BUILD=1");
        heif.define("LIBDE265_INCLUDE_DIR", forward(&de265.join("include"))).define("LIBDE265_LIBRARY", forward(&de265_lib));
        heif.define("DAV1D_INCLUDE_DIR", forward(&dav1d.join("include"))).define("DAV1D_LIBRARY", forward(&dav1d_lib));
        heif.define("WITH_LIBDE265", "ON").define("WITH_LIBDE265_PLUGIN", "OFF").define("WITH_DAV1D", "ON").define("WITH_DAV1D_PLUGIN", "OFF");
        for off in ["ENABLE_PLUGIN_LOADING", "WITH_X265", "WITH_X264", "WITH_OpenH264_DECODER", "WITH_KVAZAAR", "WITH_UVG266", "WITH_VVDEC", "WITH_VVENC", "WITH_AOM_DECODER", "WITH_AOM_ENCODER", "WITH_SvtEnc", "WITH_RAV1E", "WITH_JPEG_DECODER", "WITH_JPEG_ENCODER", "WITH_OpenJPEG_DECODER", "WITH_OpenJPEG_ENCODER", "WITH_FFMPEG_DECODER", "WITH_OPENJPH_ENCODER", "WITH_LIBSHARPYUV", "WITH_EXAMPLES", "WITH_EXAMPLE_HEIF_THUMB", "WITH_GDK_PIXBUF", "WITH_UNCOMPRESSED_CODEC", "WITH_HEADER_COMPRESSION", "BUILD_TESTING", "CMAKE_DISABLE_FIND_PACKAGE_Doxygen"] {
            heif.define(off, if off.starts_with("CMAKE_DISABLE") { "ON" } else { "OFF" });
        }
        let heif = heif.build();
        let (_, heif_name) = library(&heif, "heif");

        for root in [&heif, &de265, &dav1d] {
            println!("cargo:rustc-link-search=native={}", root.join("lib").display());
        }
        println!("cargo:rustc-link-lib=static={heif_name}");
        println!("cargo:rustc-link-lib=static={de265_name}");
        println!("cargo:rustc-link-lib=static={dav1d_name}");
        if target.contains("apple") {
            println!("cargo:rustc-link-lib=c++");
        } else if target.contains("android") {
            println!("cargo:rustc-link-lib=c++_static");
            println!("cargo:rustc-link-lib=c++abi");
        } else if target.contains("linux") {
            println!("cargo:rustc-link-lib=stdc++");
        }
    }
}

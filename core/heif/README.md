# HEIC and AVIF

The `heif` feature of the core, on in the Flutter app's builds. `fetch.cmake` fetches these, each
checked against its hash, into `<cargo target>/heif-src`; `../build.rs` builds them with CMake and
links them in statically, so no target needs a system library.

| Part | Version | Licence | For |
|---|---|---|---|
| libheif | 1.23.7 | LGPL-3.0-or-later | reads the files |
| libde265 | 1.1.3 | LGPL-3.0-or-later | HEVC (HEIC) |
| dav1d | 1.5.3 | BSD-2-Clause | AV1 (AVIF); C only, see `dav1d/CMakeLists.txt` |

The native Apple apps do not use it: they have ImageIO.

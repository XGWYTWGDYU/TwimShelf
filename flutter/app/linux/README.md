# Linux desktop bundle

On the oldest supported Linux distribution, install the Flutter Linux toolchain,
GTK3 development files, Python3, Rust and libmpv development/runtime dependencies.
SDKs, Cargo/Pub caches, build output and packaging scratch all go to `build.dir` of `config.yaml`.

Build Core with `scripts/flutter/build_core.sh linux`, then from flutter/app run
`flutter pub get` and `flutter build linux --release`. The tl_core plugin's CMake
bundles the prepared libtl_core.so. The root CMake retains F7a's libmpv/codec dependency
collection and video-native-size.json. Driver libraries and glibc remain host-provided.
CMake generates localized desktop/AppStream metadata and hicolor icons from the native
PNG resources via scripts/flutter/desktop_assets.py, without changing native resources
or requiring Pillow. Generated files live in the build tree, then the bundle's share/.

From the repository, package the installed Release bundle:

```sh
scripts/flutter/package_linux.sh flutter/app/build/linux/x64/release/bundle build/apps
```

The archive includes the full relocatable bundle and F7a video libraries. The packager
checks required components, executable ELF architecture, nonzero video size metadata,
and internal relative symlinks. It refuses external/dangling links or an existing
archive. SOURCE_DATE_EPOCH controls archive timestamps (default zero); x64 and arm64
names come from the executable's ELF header. Synthetic packaging tests run with
`python3 scripts/flutter/test_desktop_packaging.py build/cache/packaging-test`.

Extract and run `./twimshelf` from its bundle; keep lib/, data/ and share/ next
to it. The existing first-run desktop integration writes a per-user desktop entry
with the absolute executable and icon paths; rerun the app if the bundle is moved.
System installers can instead deploy share/applications, share/icons and share/metainfo
to the corresponding prefix directories with the executable on PATH, then refresh
desktop/icon caches. Desktop Name/summary reuse existing catalog import labels; no
new catalog text or translations were invented. AppStream metadata describes this
import entry; it does not assign a license to the application itself.

Normal size and maximized state persist in
`$XDG_CONFIG_HOME/<flutter.desktop_id of config.yaml>/window.ini` (or ~/.config, with .debug for a
debug build). X11 positions are restored/clamped to a current monitor; Wayland's
compositor controls placement. The minimum client size is 360×480. F5b's GApplication
single-instance/command-line forwarding remains intact. Older development builds may
have left org.twimshelf.app.desktop in the user's applications
folder; that obsolete developer entry can be removed manually after upgrading.

Final Linux-machine checks: build/link and appstreamcli validate plus
desktop-file-validate, launch via desktop entry, second file launch/forwarding,
close/reopen normal/maximized windows, monitor removal and X11/Wayland, synthetic
video playback with the bundled mpv codecs, and synthetic LAN discovery/sync. These
runtime checks require a Linux desktop; the available UTM inventory on this Mac
contains only a stopped Windows VM.

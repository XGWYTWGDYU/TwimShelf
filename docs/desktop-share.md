# Desktop incoming shares

No new main.dart hook is required. Keep the existing application-lifetime ShareInbox subscription; start it after Core.open and L10n.load. ShareFilesImported, ShareLinksReady and ShareInboxFailure are unchanged. Durably enqueue links before acknowledging them. Do not also forward main's arguments: the standard runners already queued them. importArguments is for alternate embedders.

## Linux packaging and manual acceptance

Build on the oldest supported Linux distribution, with GTK3 and libmpv development/runtime packages. F7a's installer bundles codecs. Normal CMake installation includes a generated catalog-derived `.desktop` in bundle/share/applications. The checked-in linux/org.twimshelf.app.desktop is a generated reference using a PATH executable. System packages must install the executable in PATH or regenerate Exec with its absolute path. First ShareInbox.start also writes an absolute-path entry under `${XDG_DATA_HOME:-$HOME/.local/share}/applications`, refreshing MIME caches when update-desktop-database is available. No URL protocol is registered and no default handler is replaced.

1. In a graphical user D-Bus session, launch once and open a library. Run desktop-file-validate on the user entry. Verify localized Names, quoted `Exec=… --import %F`, image/video MIME types and no x-scheme-handler. Confirm Open With offers the app for JPEG/MP4.
2. From another directory run `/absolute/bundle/twimshelf --import './a photo.jpg' './b video.mp4'`. Repeat with file URI/post URL and with the app open/busy/closed. GApplication must forward argv and sender cwd to one primary window. Events/acknowledgement match Android.
4. Move the bundle and relaunch; verify the user entry updates Exec. Test spaces, quotes, dollar signs, percent signs and backticks in its path. The supported desktop integration requires a working graphical user session bus; GApplication uniqueness is not guaranteed in headless/no-bus environments. Do not run multiple primaries against one inbox there.


# TwimShelf React front end (`web/`)

The web UI the Linux server (Docker) serves, and the UI of the Electron app (Linux; a macOS build
exists for testing only). The two are the same code and must look and work the same. Layouts and
behaviour follow the native apps (Apple/macOS first, windows/ second), from their sources; the
look is the Antigravity concept's (`app/src/theme.css`). It must never feel like a web page.

## Layout

| Folder | What | Rules |
|---|---|---|
| `packages/core` | The core over HTTP: generated bindings and types, result envelope, feed unpacking, i18n, a tiny store | **No DOM, no React.** Kept portable so a React Native app could reuse it. |
| `app` | The React DOM UI (Vite) | Builds only on `packages/core` and `app/src/components`. |
| `electron` | The Electron shell: starts the bundled `twimshelf-server` on localhost and shows `app` | Later step. |

Generated, never edit by hand:
- `packages/core/src/generated/bindings.ts` ← `python3 scripts/gen_web_bindings.py` (from `flutter/tl_core/lib/src/bindings.dart`)
- `packages/core/src/generated/models.ts` ← `python3 scripts/gen_web_models.py` (from `flutter/tl_core/lib/src/models.dart`)
- `packages/core/src/generated/strings/*.json` ← `python3 scripts/to_flutter.py` (from `Apple/Resources/Localizable.xcstrings`)

## Talking to the core

```ts
import { core } from '../lib/core';            // the app's one Core
const stats = await core.read<LibraryStats>(core.b.tl_stats());
const items = await core.feed({ filter: { folder: 'Trips' } });
await core.readJson<number>('tl_trash', { media: ids, post: null });
```

`core.b.tl_*` are the C functions one to one (`POST /api/call/<name>`). Most return the envelope
`{"ok": …}` / `{"error": …}` that `core.read` unwraps (it throws `CoreError`; its message is
usually a string key, show it with `L(message)`). **Which arguments a function takes, and what it
returns, is in the Dart wrapper `flutter/tl_core/lib/tl_core.dart`**; the native apps
(`Apple/macOS`, `Apple/Shared`) are the reference for layout and behaviour. Files:
`core.fileUrl(item.path)`.

After a change to the library call `libraryChanged()` (`app/src/lib/library.ts`): counts, folders
and open lists reload.

## UI conventions

- Strings: `L('key', ...args)` from `@twimshelf/core`. Never hard-code UI text; a missing string is
  added to `Apple/Resources/Localizable.xcstrings` (all four languages) and exported with
  `python3 scripts/to_flutter.py`.
- Look: the native app's layouts with the theme's tokens (`app/src/theme.css`); building blocks in
  `app/src/components` (`Toolbar`, `ui.tsx`, `Menu.tsx`, `pickers.tsx` for alerts); icons from
  `lucide-react`. Light and dark both work.
- Not a web page: the arrow cursor everywhere, no text selection outside text meant to be copied,
  no hover lifts, no browser controls (menus go through `openMenu`, which is the system's own in
  Electron; videos use `viewer/Player.tsx`, never `<video controls>`).
- Navigation: `app/src/lib/router.ts` (`go`, `href`, `useRoute`). Settings sub-pages are
  `#/settings/<name>`.
- State outside React: `store()` from core + `useStore`; loading: `useAsync`; polling: `useInterval`.
- Messages: `toast(text, {label, run})` from `app/src/components/toast.tsx`.

## Running it

```bash
cd web && npm install
npm run dev            # Vite on :5173, API proxied to TL_SERVER (default http://localhost:8080)
npm run check          # type check
npm run build          # app/dist, what the server serves (TL_WEB)
```

A server for development, on a test library (never your real one):

```bash
CARGO_TARGET_DIR=/tmp/tl-target cargo build -p tl-server
TL_DATA=/path/to/test-data TL_WEB=web/app/dist TL_PASSWORD=dev TL_PORT=8080 /tmp/tl-target/debug/twimshelf-server
```

## Where things are, and their native reference

| Part | Files | Native reference |
|---|---|---|
| Window: sidebar, toolbar, menu bar, alerts | `app/src/components/*`, `app/src/lib/commands.ts` | `Apple/macOS/MacMainWindow.swift`, `AppDelegate.swift` |
| 浏览: masonry, search capsule, cards | `app/src/pages/browse/*` | `Apple/macOS/MacFeed.swift`, `MacSearch.swift` |
| Zoomable grid (folders, media kinds, collections, bin) | `app/src/pages/grid/*` (`zoom.ts`, `scene.ts` are ports) | `Apple/Shared/Grid/*`, `Apple/macOS/MacMediaGrid*.swift` |
| Viewer and player | `app/src/viewer/*` | `Apple/macOS/MacPlayer.swift`, `Apple/Shared/PostCaptionView.swift` |
| Folders overview | `app/src/pages/FoldersPage.tsx` | `MacFoldersOverview` in `MacMainWindow.swift` |
| Settings | `app/src/pages/settings/*` | `Apple/macOS/MacSettings*.swift` |
| Electron | `web/electron` (name, id, version and icon from `config.yaml` via `scripts/apply.py desktop`) | — |

# TwimShelf React front end (`web/`)

The web UI the Linux server (Docker) serves, and the UI of the Electron app (Linux; a macOS build
exists for testing only). It replaces Flutter on the web and on Linux. Flutter stays for Android
and for testing on iOS.

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
returns, is in the Dart wrapper `flutter/tl_core/lib/tl_core.dart`**; the Flutter screens in
`flutter/app/lib` are the reference for behaviour. Files: `core.fileUrl(item.path)`.

After a change to the library call `libraryChanged()` (`app/src/lib/library.ts`): counts, folders
and open lists reload.

## UI conventions

- Strings: `L('key', ...args)` from `@twimshelf/core`. Never hard-code UI text; a missing string is
  added to `Apple/Resources/Localizable.xcstrings` (all four languages) and exported with
  `python3 scripts/to_flutter.py`.
- Look: like the native Apple app, not Material. Use `app/src/components/ui.tsx` (`Page`,
  `Section`, `Row`, `Button`, `Toggle`, `TextField`, `Dialog`, `Progress`, `Empty`) and the CSS
  tokens in `app/src/theme.css`; icons from `lucide-react`. Light and dark both work.
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

## Who does what (the migration)

| Part | Files | Reference in Flutter |
|---|---|---|
| Browse: masonry grid, search capsule, cards, selection, card actions, viewer, video | `app/src/pages/browse/*`, `app/src/viewer/*` | `screens/browse_page.dart`, `grid/`, `search/`, `screens/viewer_page.dart`, `screens/video_page.dart`, `actions/` |
| Settings: main page and all sub-pages | `app/src/pages/settings/*` | `screens/settings_page.dart`, `screens/settings/*` |
| Folders, Tags, Bin pages | `app/src/pages/FoldersPage.tsx`, `TagsPage.tsx`, `BinPage.tsx` | `screens/folders_page.dart`, `screens/settings/tags_page.dart`, the bin in `browse_page.dart` |
| Electron, server/Docker/CI/build.sh | `web/electron`, `server`, `.github`, `build.sh` | — |

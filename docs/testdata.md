# Synthetic libraries

Generate without downloads (Python standard library; optional local ffmpeg adds JPEG/MP4):

```
python3 scripts/make_seed.py /tmp/tl-seed --seed 2026
# ~2,000 photos, plus loose/damaged/video fixtures:
python3 scripts/make_seed.py /tmp/tl-big --big
```

Outputs are deterministic for the same arguments and ffmpeg version/presence. The generator refuses nonempty destinations. seed.json records all fixture hashes. Text/tag/folder names are synthetic test content, not application UI. No fixture is bundled in release assets. Without ffmpeg, PNGs are generated and video is explicitly skipped.

The UI owner must call `await seedIfRequested()` from `lib/dev/seed.dart` **after Core.open succeeds and before loading feed/stats**. The helper returns immediately outside debug builds. For validation without touching the UI, use `--target lib/dev/seed_smoke.dart`. Its only screen is the catalog-formatted stats line. The helper imports posts and loose files, adds mine/AI/both tags and a collection, and places one item in the bin. The damaged fixture is explicitly flagged through Core.reportBad. The existing core marks recent only during downloads; legacy/loose imports do not create recent entries, so this seed deliberately leaves recent empty (no network downloads or new core API). A marker in the selected library makes subsequent launches skip seeding. Always use a fresh test library, never your personal library. Before importing, the helper refuses a nonempty library (including bin items), so an omitted test-directory override cannot seed an existing personal collection. If initialization was interrupted before its completion marker, start again with a fresh test library.

## macOS

```
cd flutter/app
TL_LIBRARY_DIR=/tmp/tl-test-library TL_IMPORT_DIR=/tmp/tl-seed \
  flutter run -d macos --target lib/dev/seed_smoke.dart
```

A direct launch of the built executable inherits these same environment variables. Build output goes to build.dir of config.yaml (scripts/apply.py links the Flutter build folders there).

## iOS simulator / native iPad test build

Create a seed on the host, then launch the installed simulator app with:

```
SIMCTL_CHILD_TL_LIBRARY_DIR=/tmp/tl-ios-test-library \
SIMCTL_CHILD_TL_IMPORT_DIR=/tmp/tl-seed \
  xcrun simctl launch booted <bundle-id>
```

Simulator paths are on the host. Use an accessible container directory if sandboxing is enabled. Flutter mobile builds also accept `--dart-define=TL_SEED=1 --dart-define=TL_IMPORT_DIR=<container-path>`. For physical iPad, copy the seed into the debug app's Documents/seed through Xcode Devices, and enable TL_SEED for Flutter. For existing native UI tests, point TEST_RUNNER_TL_IMPORT_DIR at the generated **posts** subdirectory and TEST_RUNNER_TL_LIBRARY_DIR at an empty directory; native TL_DEMO_TAGS supplies its own tags. No native app source is changed here.

## Android emulator

Build/install the debug APK with `--dart-define=TL_SEED=1`. The default location is Documents/seed as returned by path_provider (Android: app_flutter/seed). Copy generated fixtures using adb to shared temporary storage, then into the private debug sandbox:

```
adb push /tmp/tl-seed /data/local/tmp/tl-seed
adb shell run-as <applicationId> mkdir -p app_flutter/seed
adb shell 'tar -C /data/local/tmp/tl-seed -cf - .' | \
  adb shell run-as <applicationId> tar -C app_flutter/seed -xf -
```

Alternatively supply `--dart-define=TL_IMPORT_DIR=/data/user/0/<applicationId>/files/seed` and copy there with run-as. Relaunch the app after copying. `adb logcat` includes the isolated host's `seed-smoke` counts. Use an emulator/test app data only; reset its data to repeat the first-launch scenario.

## Release exclusion

Build the isolated host with `flutter build macos --release --target lib/dev/seed_smoke.dart` and inspect App.framework/App for `dev.seed.missingManifest`, `.synthetic-seed-v1` and `synthetic-seed`. The debug-only helper's body and fixture strings must be absent. Do not use --no-tree-shake-icons as evidence about Dart tree shaking: the relevant guard is kDebugMode. No debug seed assets are declared in pubspec.yaml.

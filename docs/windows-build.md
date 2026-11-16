# Windows build

The Windows app is native: `windows/TwimShelf`, WinUI 3 (Windows App SDK) on .NET with native
AOT, not packaged (no MSIX, no app container). One command on Windows 11:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 windows
```

It checks the tools (Visual Studio Build Tools with C++, Rust, the .NET SDK of `global.json`, the
Vulkan SDK for GPU AI), offers to install what is missing with winget, builds the Rust core,
llama.cpp, the app and the setup (named and with the icon from `config.yaml`), and writes
`TwimShelf-<version>-windows-x64-setup.exe` to `build\apps` (`build.dir` in `config.yaml` moves
everything elsewhere). `-Check` only checks.

To work on it in Visual Studio, run `build.ps1 windows` (or `python scripts/apply.py`) once:
it writes the generated files (`product.json`, the icon) and puts the Rust core into
`windows\TwimShelf\lib`. Then open `windows\TwimShelf\TwimShelf.csproj`.

- The core's functions are bound from `Apple/Shared/tl_core.h` by `scripts/windows_bindings.py`
  (`Core/Native.g.cs`; `--check` says whether it is current).
- Interface texts come from `flutter/app/assets/l10n/*.json` (made from
  `Apple/Resources/Localizable.xcstrings` by `scripts/to_flutter.py`), embedded at build time.
- The lowest Windows is 11 (10.0.22000): the Community Toolkit's settings controls need it.

## The setup

`setup.exe` is a small Win32 program (`windows/Setup/stub`) with a tar archive of the program
appended. It unpacks it into a temporary folder with Windows' own `tar.exe`, runs
`TwimShelf.exe --setup` from there (the program is its own setup, drawn with Fluent controls) and
removes the folder.

- Installs for the current user only (`%LOCALAPPDATA%\Programs\TwimShelf` by default, the person
  can choose another folder): no administrator rights, no UAC prompt. The folder must be new, empty
  or an earlier install, and must not hold the data folder.
- Everything the program needs is in its folder (the Windows App SDK and .NET included).
  `install-manifest.json` lists the program's files, so an update removes the ones it no longer has.
  An update moves the files it replaces aside first and puts them back if it fails part way.
- Apps & Features runs `TwimShelf.exe --uninstall` to remove the program. It removes only the files
  in the manifest (and the folder once empty); the Apps & Features entry goes after they are gone,
  and stays, with a message, when some could not be removed. Removing the data folder too is a
  choice in the uninstaller, unticked by default.
- The data folder may not be inside the program's folder. An older version allowed it: the app then
  asks to move it before anything else (or quits).
- `setup.exe --quiet` installs without a window and `TwimShelf.exe --uninstall --quiet` uninstalls
  (keeping the data); the exit code says how it went. CI uses them for a smoke test: install, first
  start on a throwaway library, install again, uninstall.
- It installs over the Flutter version's setup (the same folder and Apps & Features entry), and
  the app reads the Flutter version's data folder as it is: nothing to convert.
- Firewall: a per-user setup cannot add firewall rules. The first time the app listens (LAN sync,
  the browser extension's port 27800), Windows asks whether to allow it; allow it on private networks.
- `setup.exe` is not signed (SmartScreen shows an unknown publisher). Don't sign it as it is: the
  stub reads its archive's `TLSETUP1` trailer at the very end of the file, and an embedded
  Authenticode signature is appended after it, so the setup would report itself damaged. Signing
  needs the stub to find the trailer before the certificate table first.

## Data

On first start the app asks for its data folder (library, models, settings, sync keys, logs,
caches) and keeps only a pointer to it in `%APPDATA%\TwimShelf\location.json`. Settings ›
Data Folder moves it. Secrets are kept in that folder, sealed with a key beside them: they are not
plain text, but any program that can read the folder can open them.

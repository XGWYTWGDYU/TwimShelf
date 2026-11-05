# Windows build

One command on Windows 10 1803 or later:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 flutter-windows
```

It checks the tools (Visual Studio Build Tools with C++, Rust, Flutter, the Vulkan SDK for
GPU AI), offers to install what is missing with winget, builds the Rust core, the app and the
setup (named and with the icon from `config.yaml`), and writes `TwimShelf-Flutter-<version>-windows-x64-setup.exe` to `build\apps`
(`build.dir` in `config.yaml` moves everything elsewhere). `-Check` only checks.

## The setup

`setup.exe` is a small Win32 program (`flutter/installer/stub`) with a tar archive appended:
the setup app (`flutter/installer`, Material 3, Flutter) and the program. It unpacks them into
a temporary folder with the `tar.exe` that Windows has had since 10 1803, runs the setup and
removes the folder.

- Installs for the current user only (`%LOCALAPPDATA%\Programs\<name>` by default, the person
  can choose another folder): no administrator rights, no UAC prompt.
- Everything the program needs is in its folder, the Visual C++ runtime included.
  `install-manifest.json` lists the program's files, so an update removes the ones it no longer has.
- A copy of the setup stays in `<install folder>\uninstall`; Apps & Features runs it to remove the
  program. Removing the data folder too is a choice in the uninstaller, unticked by default.
- Firewall: a per-user setup cannot add firewall rules. The first time LAN sync listens,
  Windows asks whether to allow it on private networks; allow it there.
- Sign `setup.exe` with a code-signing certificate before distributing it, or SmartScreen warns
  about an unknown publisher.

## Data

On first start the app asks for its data folder (library, models, settings, sync keys, logs,
caches) and keeps only a pointer to it in `%APPDATA%\TwimShelf\location.json`. Settings ›
Data Folder moves it. Secrets are kept in that folder, sealed with a key beside them: they are not
plain text, but any program that can read the folder can open them.

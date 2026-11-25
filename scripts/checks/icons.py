#!/usr/bin/env python3
"""Each platform carries its own committed icons directly in git (no centralized config.yaml icon
pipeline or local override sets)."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
problems = []

REQUIRED = [
    # Native Apple (iOS / iPadOS / macOS Icon Composer bundle)
    "Apple/Resources/AppIcon.icon/icon.json",
    # Native Windows (app + setup stub)
    "windows/TwimShelf/Assets/AppIcon.ico",
    "windows/TwimShelf/Assets/AppIcon.png",
    # Android (adaptive Light / Dark / Monochrome + legacy mipmaps)
    "flutter/app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml",
    "flutter/app/android/app/src/main/res/values/colors.xml",
    "flutter/app/android/app/src/main/res/values-night/colors.xml",
    "flutter/app/android/app/src/main/res/drawable/ic_launcher_foreground.xml",
    "flutter/app/android/app/src/main/res/drawable-night/ic_launcher_foreground.xml",
    "flutter/app/android/app/src/main/res/drawable/ic_launcher_monochrome.xml",
    "flutter/app/android/app/src/main/res/mipmap-mdpi/ic_launcher.png",
    "flutter/app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png",
    "flutter/app/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png",
    "flutter/app/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png",
    "flutter/app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
    # Flutter iOS + in-app About icons
    "flutter/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "flutter/app/assets/app_icon.png",
    "flutter/app/assets/app_icon_dark.png",
    # Browser extension
    "extension/icons/icon16.png",
    "extension/icons/icon32.png",
    "extension/icons/icon48.png",
    "extension/icons/icon128.png",
    # Web + Linux Electron
    "web/app/public/favicon.png",
    "web/app/public/icons/Icon-192.png",
    "web/app/public/icons/Icon-512.png",
    "web/electron/icon.png",
]

tracked = set(subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, text=True).splitlines())

for path in REQUIRED:
    if not (ROOT / path).is_file():
        problems.append(f"{path}: missing")
    elif path not in tracked:
        problems.append(f"{path}: ignored by git (must be committed)")

# Verify every Flutter iOS AppIcon entry in Contents.json exists and is not gitignored
ios_set = ROOT / "flutter/app/ios/Runner/Assets.xcassets/AppIcon.appiconset"
if (ios_set / "Contents.json").is_file():
    contents = json.loads((ios_set / "Contents.json").read_text(encoding="utf-8"))
    for entry in contents.get("images", []):
        fname = entry.get("filename")
        if not fname:
            continue
        rel = f"flutter/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/{fname}"
        if not (ROOT / rel).is_file():
            problems.append(f"{rel}: missing")
        elif rel not in tracked:
            problems.append(f"{rel}: ignored by git")

# Ensure legacy centralized icon artifacts never creep back in
for forbidden in ("icon.png", "Apple/Resources/Assets.xcassets/AppIconLocal.appiconset", "scripts/flutter/make_icons.py"):
    if (ROOT / forbidden).exists():
        problems.append(f"{forbidden}: legacy centralized icon file should not exist")

if "TL_APP_ICON" in (ROOT / "project.yml").read_text(encoding="utf-8"):
    problems.append("project.yml: still references TL_APP_ICON")
if "Assets\\AppIcon.ico" not in (ROOT / "windows/TwimShelf/TwimShelf.csproj").read_text(encoding="utf-8"):
    problems.append("windows/TwimShelf/TwimShelf.csproj: does not reference Assets\\AppIcon.ico")
if "AppIcon.ico" not in (ROOT / "build.ps1").read_text(encoding="utf-8"):
    problems.append("build.ps1: setup stub does not reference AppIcon.ico")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("icons: self-contained per platform")

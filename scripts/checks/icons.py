#!/usr/bin/env python3
"""No program of any platform carries an icon of its own: the AppIcon set is the only one in git,
and every place that shows an icon refers to it or to what scripts make from it."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "Apple/Resources/Assets.xcassets/AppIcon.appiconset/"
problems = []

tracked = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
for f in tracked:
    name = f.rsplit("/", 1)[-1].lower()
    binary = name.endswith((".png", ".ico", ".icns", ".jpg", ".webp"))
    icon = "appicon" in f.lower() or "app_icon" in name or "ic_launcher" in name or "hicolor" in f or name.endswith((".ico", ".icns"))
    if binary and icon and not f.startswith(SOURCE) and f != "icon.png":
        problems.append(f"{f}: an icon in git outside the AppIcon set")

# the native Windows app: its icon (the program's and the setup's) is made by apply.py from the set
if "AppIcon.ico" not in (ROOT / "scripts/apply.py").read_text(encoding="utf-8"):
    problems.append("scripts/apply.py: does not make the Windows icon from the AppIcon set")
if "Assets\\AppIcon.ico" not in (ROOT / "windows/TwimShelf/TwimShelf.csproj").read_text(encoding="utf-8"):
    problems.append("windows/TwimShelf/TwimShelf.csproj: its icon is not the generated one")
if "AppIcon.ico" not in (ROOT / "build.ps1").read_text(encoding="utf-8"):
    problems.append("build.ps1: the setup's icon is not the generated one")
if "icon_set" not in (ROOT / "scripts/flutter/desktop_assets.py").read_text(encoding="utf-8"):
    problems.append("desktop_assets.py: reads something else than the AppIcon set the apps use")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("icons: one source")

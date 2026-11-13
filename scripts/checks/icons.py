#!/usr/bin/env python3
"""No program of any platform carries an icon of its own: the AppIcon set is the only one in git,
and every place that shows an icon refers to it or to what scripts make from it."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "native/Resources/Assets.xcassets/AppIcon.appiconset/"
problems = []

tracked = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
for f in tracked:
    name = f.rsplit("/", 1)[-1].lower()
    binary = name.endswith((".png", ".ico", ".icns", ".jpg", ".webp"))
    icon = "appicon" in f.lower() or "app_icon" in name or "ic_launcher" in name or "hicolor" in f or name.endswith((".ico", ".icns"))
    if binary and icon and not f.startswith(SOURCE) and f != "icon.png":
        problems.append(f"{f}: an icon in git outside the AppIcon set")

for rc in ("flutter/app/windows/runner/Runner.rc", "flutter/installer/windows/runner/Runner.rc"):
    if "TL_APP_ICON" not in (ROOT / rc).read_text(encoding="utf-16" if (ROOT / rc).read_bytes()[:2] == b"\xff\xfe" else "utf-8", errors="replace"):
        problems.append(f"{rc}: its icon is not the generated one")
for cm in ("flutter/app/windows/runner/CMakeLists.txt", "flutter/installer/windows/runner/CMakeLists.txt"):
    if "desktop_assets.py" not in (ROOT / cm).read_text(encoding="utf-8"):
        problems.append(f"{cm}: does not make the icon from the AppIcon set")
if "desktop_assets.py" not in (ROOT / "build.ps1").read_text(encoding="utf-8"):
    problems.append("build.ps1: the setup's icon is not made from the AppIcon set")
if "icon_set" not in (ROOT / "scripts/flutter/desktop_assets.py").read_text(encoding="utf-8"):
    problems.append("desktop_assets.py: reads something else than the AppIcon set the apps use")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("icons: one source")

#!/usr/bin/env python3
"""Generate every icon the Flutter apps carry, from the one source: the app's AppIcon set
(native/Resources/Assets.xcassets/AppIcon.appiconset, named in config.yaml).

None of what this writes is in git (scripts/checks/icons.py keeps it that way); scripts/apply.py
runs this whenever a build applies config.yaml and something is missing or the source changed.

  Android   legacy mipmaps, and the adaptive icon's foreground over a white background
  iOS       the AppIcon set of Runner, opaque
  macOS     the AppIcon set of Runner, with the Mac icon's own corners
  in-app    assets/app_icon.png of the app and of the Windows setup

Windows and Linux make theirs at build time from the same set (desktop_assets.py).

  python3 scripts/flutter/make_icons.py                       the icons above
  python3 scripts/flutter/make_icons.py --app-icon icon.png   the AppIcon set itself, from the
      one source file: square, with its own corners and transparent margin. The Mac icons are that
      file scaled; the iOS icon is its artwork alone, cut to the edges and opaque (iOS masks it).
  python3 scripts/flutter/make_icons.py --check    names what is missing; exit 1 if anything is
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = ROOT / "native/Resources/Assets.xcassets/AppIcon.appiconset"
APP_DIR = ROOT / "flutter/app"
ANDROID_RES = APP_DIR / "android/app/src/main/res"
IOS_SET = APP_DIR / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
MAC_SET = APP_DIR / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
IN_APP = (APP_DIR / "assets/app_icon.png", ROOT / "flutter/installer/assets/app_icon.png")

ANDROID_LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ANDROID_ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
WHITE = (255, 255, 255, 255)


def catalog(folder):
    """(file, pixels) of an AppIcon set, from its Contents.json."""
    out = {}
    for image in json.loads((folder / "Contents.json").read_text(encoding="utf-8"))["images"]:
        name = image.get("filename")
        if name:
            out[folder / name] = round(float(image["size"].split("x")[0]) * float(image["scale"].rstrip("x")))
    return out


def outputs():
    files = list(IN_APP) + list(catalog(IOS_SET)) + list(catalog(MAC_SET))
    for density in ANDROID_LEGACY:
        files += [ANDROID_RES / f"mipmap-{density}/ic_launcher.png", ANDROID_RES / f"mipmap-{density}/ic_launcher_foreground.png"]
    return files


def pillow():
    """Pillow, fetched into the build cache when this Python has none."""
    try:
        from PIL import Image
    except ImportError:
        cache = subprocess.check_output([sys.executable, str(ROOT / "scripts/apply.py"), "where", "cache"], text=True).strip()
        target = Path(cache) / "python-pillow"
        sys.path.insert(0, str(target))
        try:
            from PIL import Image
        except ImportError:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check", "--target", str(target), "pillow"])
            import importlib
            importlib.invalidate_caches()
            from PIL import Image
    return Image


def app_icon_set(path):
    Image = pillow()
    with Image.open(path) as f:
        source = f.convert("RGBA")
    if source.width != source.height:
        sys.exit(f"{path}: an icon must be square")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        source.resize((size, size), Image.Resampling.LANCZOS).save(SOURCE_DIR / f"mac-{size}.png", optimize=True)
    left, top, right, bottom = source.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    art = source.crop((left, top, right, bottom))
    # the corners iOS masks away: the colour of the artwork's edge, not white
    middle = art.height // 2
    canvas = Image.new("RGBA", art.size, art.getpixel((4, middle))[:3] + (255,))
    canvas.alpha_composite(art)
    canvas.resize((1024, 1024), Image.Resampling.LANCZOS).convert("RGB").save(SOURCE_DIR / "icon-1024.png", optimize=True)
    print(f"config: the AppIcon set made from {Path(path).name}")


def main():
    if "--app-icon" in sys.argv:
        app_icon_set(sys.argv[sys.argv.index("--app-icon") + 1])
        return
    if "--check" in sys.argv:
        missing = [str(f.relative_to(ROOT)) for f in outputs() if not f.exists()]
        print("\n".join(missing))
        sys.exit(1 if missing else 0)

    Image = pillow()
    with Image.open(SOURCE_DIR / "icon-1024.png") as f:
        image = f.convert("RGBA")
    with Image.open(SOURCE_DIR / "mac-1024.png") as f:
        mac = f.convert("RGBA")

    def resized(source, size):
        return source.resize((size, size), Image.Resampling.LANCZOS)

    def on_white(size):
        canvas = Image.new("RGBA", (size, size), WHITE)
        canvas.alpha_composite(resized(image, size))
        return canvas.convert("RGB")

    for density, size in ANDROID_LEGACY.items():
        folder = ANDROID_RES / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        on_white(size).save(folder / "ic_launcher.png")
        resized(image, ANDROID_ADAPTIVE[density]).save(folder / "ic_launcher_foreground.png")
    for path, size in catalog(IOS_SET).items():
        on_white(size).save(path)  # the App Store refuses transparency
    for path, size in catalog(MAC_SET).items():
        resized(mac, size).save(path)
    for path in IN_APP:
        path.parent.mkdir(parents=True, exist_ok=True)
        resized(image, 512).save(path)
    print(f"config: {len(outputs())} icons made from the AppIcon set")


if __name__ == "__main__":
    main()

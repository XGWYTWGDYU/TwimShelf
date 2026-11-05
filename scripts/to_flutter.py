#!/usr/bin/env python3
"""Export the Apple string catalog to deterministic Flutter language assets.

  python3 scripts/to_flutter.py
  python3 scripts/to_flutter.py CATALOG --out OUTPUT_DIRECTORY
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGS = ["en", "zh-Hans", "zh-Hant", "ja"]


def value_of(loc):
    if "stringUnit" in loc:
        return loc["stringUnit"]["value"]
    plural = loc.get("variations", {}).get("plural")
    if plural is not None:
        return {key: value_of(value) for key, value in sorted(plural.items())}
    raise ValueError("Unsupported localization shape: " + repr(loc))


def export(catalog, out):
    result = {lang: {} for lang in LANGS}
    for key, entry in sorted(catalog["strings"].items()):
        locs = entry.get("localizations", {})
        # Source-language keys are the default for untranslated source strings.
        english = value_of(locs["en"]) if "en" in locs else key
        for lang in LANGS:
            value = value_of(locs[lang]) if lang in locs else english
            # A partially translated plural also falls back form by form.
            if isinstance(value, dict) and isinstance(english, dict):
                value = {**english, **value}
            result[lang][key] = value
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for lang, entries in result.items():
        (out / (lang + ".json")).write_text(
            json.dumps(entries, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", nargs="?", type=Path,
                        default=ROOT / "native/Resources/Localizable.xcstrings")
    parser.add_argument("--out", type=Path, default=ROOT / "flutter/app/assets/l10n")
    args = parser.parse_args()
    with args.catalog.open(encoding="utf-8") as source:
        result = export(json.load(source), args.out)
    print(f"Exported {len(result['en'])} keys in {len(LANGS)} languages")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""THIRD-PARTY-NOTICES.txt for a release: the license text of every dependency that was fetched for
the build. Run after a build, so that everything is on disk:

  python3 scripts/third_party_notices.py <out.txt>

Rust crates (cargo metadata), Dart packages (the app's package_config.json), Swift packages (their
checkouts in the build cache), and the C/C++ sources the build fetched (libheif, dav1d, llama.cpp…).
What has no license file is named at the end, so nothing goes missing silently.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
LICENSE = re.compile(r'^(licen[cs]e|copying|notice|copyright)([._-].*)?$', re.I)


def apply(*args):
    return subprocess.check_output([sys.executable, str(ROOT / 'scripts/apply.py'), *args], text=True).strip()


def rust():
    meta = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1', '--features', 'heif'], cwd=ROOT / 'core', text=True))
    ours = set(meta['workspace_members'])
    for p in meta['packages']:
        if p['id'] not in ours:
            yield f"Rust: {p['name']} {p['version']} ({p.get('license') or 'see text'})", Path(p['manifest_path']).parent


def dart():
    config = ROOT / 'flutter/app/.dart_tool/package_config.json'
    if not config.exists():
        print('note: no Dart packages (flutter pub get has not run)', file=sys.stderr)
        return
    for p in json.loads(config.read_text(encoding='utf-8'))['packages']:
        uri = p['rootUri']
        if not uri.startswith('file:'):
            continue  # the app's own packages
        path = Path(unquote(urlparse(uri).path))
        if ROOT in path.parents:
            continue
        yield f"Dart: {p['name']}", path


def fetched():
    cache = Path(apply('where', 'cache'))
    seen = set()
    for pattern in ('xcode/**/SourcePackages/checkouts/*', 'cargo/heif-src/*', 'flutter/**/_deps/*-src'):
        for path in cache.glob(pattern):
            if path.is_dir() and path.name not in seen:
                seen.add(path.name)
                yield f'Source: {path.name}', path


def main():
    out = Path(sys.argv[1])
    texts, missing = {}, []
    for name, path in [*rust(), *dart(), *fetched()]:
        files = sorted(f for f in path.iterdir() if f.is_file() and LICENSE.match(f.name)) if path.is_dir() else []
        if not files:
            missing.append(name)
            continue
        body = '\n\n'.join(f.read_text(encoding='utf-8', errors='replace').strip() for f in files)
        texts[name] = body
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open('w', encoding='utf-8') as f:
        f.write('Third-party software in the TwimShelf packages, and its licenses.\n\n')
        f.write('Models downloaded inside the app are not part of the packages; each has its own license.\n')
        f.write('The Android, Windows and Linux packages also contain llama.cpp (MIT, github.com/ggml-org/llama.cpp)\n')
        f.write('and libmpv with its codec libraries (media-kit, github.com/media-kit/media-kit; LGPL and others).\n\n')
        for name in sorted(texts):
            f.write(f"{'=' * 78}\n{name}\n{'=' * 78}\n\n{texts[name]}\n\n")
        if missing:
            f.write(f"{'=' * 78}\nNo license file found in the fetched copy; see the project itself\n{'=' * 78}\n\n")
            f.write('\n'.join(sorted(missing)) + '\n')
    print(f'{out}: {len(texts)} with a license text, {len(missing)} without')


if __name__ == '__main__':
    main()

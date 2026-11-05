#!/usr/bin/env python3
"""Generate desktop assets in a build directory; only reads native app resources.
Uses existing native PNG sizes, so no image library or network is required.
"""
import argparse
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SIZES = (16, 32, 64, 128, 256, 512)


def config(key):
    return subprocess.check_output([sys.executable, str(ROOT / 'scripts/apply.py'), 'get', key], text=True).strip()


def generate(output, app_id=None, app_name=None, icon_name=None):
    """app_id (a debug build's has its suffix), app_name, icon_name: from config.yaml unless given."""
    app_id = app_id or config('flutter.desktop_id')
    app_name = app_name or config('flutter.name')
    icon_name = icon_name or app_id
    output = Path(output).resolve()
    build = Path(subprocess.check_output([sys.executable, str(ROOT / 'scripts/apply.py'), 'where', 'build'], text=True).strip()).resolve()
    if (output == ROOT or ROOT in output.parents) and build not in output.parents:
        raise ValueError('Generated assets belong in build.dir of config.yaml, not in the sources')
    # what an earlier id left here would go into the bundle with the rest
    shutil.rmtree(output / 'icons', ignore_errors=True)
    for old in output.glob('*.metainfo.xml'):
        old.unlink()
    source = ROOT / 'native/Resources/Assets.xcassets/AppIcon.appiconset'
    images = []
    for size in SIZES:
        data = (source / f'mac-{size}.png').read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != (size, size):
            raise ValueError(f'Invalid native icon: {size}')
        dest = output / f'icons/hicolor/{size}x{size}/apps/{icon_name}.png'
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        if size <= 256:
            images.append((size, data))
    offset = 6 + 16 * len(images)
    entries, blobs = [], []
    for size, data in images:
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        blobs.append(data)
        offset += len(data)
    (output / 'app_icon.ico').write_bytes(struct.pack('<HHH', 0, 1, len(images)) + b''.join(entries + blobs))
    # Branding and descriptions reuse existing localized catalog strings.
    component = ET.Element('component', type='desktop-application')
    ET.SubElement(component, 'id').text = app_id
    ET.SubElement(component, 'metadata_license').text = 'CC0-1.0'
    for language in ('en', 'ja', 'zh-Hans', 'zh-Hant'):
        catalog = json.loads((ROOT / f'flutter/app/assets/l10n/{language}.json').read_text())
        attrs = {} if language == 'en' else {'{http://www.w3.org/XML/1998/namespace}lang': language}
        ET.SubElement(component, 'name', attrs).text = catalog['share.title'].replace('{app}', app_name)
        ET.SubElement(component, 'summary', attrs).text = catalog['share.subtitle']
    ET.SubElement(component, 'launchable', type='desktop-id').text = f'{app_id}.desktop'
    ET.SubElement(component, 'icon', type='stock').text = icon_name
    categories = ET.SubElement(component, 'categories')
    ET.SubElement(categories, 'category').text = 'Graphics'
    ET.SubElement(categories, 'category').text = 'AudioVideo'
    ET.ElementTree(component).write(output / f'{app_id}.metainfo.xml', encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--app-id')
    parser.add_argument('--app-name')
    parser.add_argument('--icon-name')
    args = parser.parse_args()
    generate(args.output, args.app_id, args.app_name, args.icon_name)

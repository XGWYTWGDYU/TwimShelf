#!/usr/bin/env python3
"""BUILD-INFO.json of a release: what the packages are, from config.yaml.

  python3 scripts/build_info.py <commit> > BUILD-INFO.json
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def get(key):
    return subprocess.check_output([sys.executable, str(ROOT / 'scripts/apply.py'), 'get', key], text=True).strip()


bundle = get('native.bundle_id')
print(json.dumps({
    'version': get('version'),
    'build_number': get('build_number'),
    'source_commit': sys.argv[1] if len(sys.argv) > 1 else '',
    'app_name': 'TwimShelf',
    'native': {
        'macOS': {'minimum_version': '15.0', 'architecture': 'arm64', 'bundle_id': f'{bundle}.mac',
                  'signing': 'ad-hoc', 'notarized': False, 'share_extension': get('native.share_extension_mac') == 'true'},
        'iOS': {'minimum_version': '18.0', 'architecture': 'arm64', 'bundle_id': f'{bundle}.ios',
                'signing': 'unsigned; re-sign to install', 'share_extension': get('native.share_extension_ios') == 'true'},
    },
    'flutter': {
        'macOS': {'bundle_id': get('flutter.apple_bundle_id'), 'signing': 'ad-hoc', 'notarized': False, 'share_extension': get('flutter.share_extension_mac') == 'true'},
        'iOS': {'bundle_id': get('flutter.apple_bundle_id'), 'signing': 'unsigned; re-sign to install', 'share_extension': get('flutter.share_extension_ios') == 'true'},
        'android': {'package': get('flutter.android_package')},
        'linux': {'application_id': get('flutter.desktop_id')},
        'windows': {'signing': 'unsigned'},
    },
    'bundled_AI_models': False,
}, indent=2))

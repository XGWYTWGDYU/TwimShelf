#!/usr/bin/env bash
# Run after flutter build linux --release on the oldest supported Linux host.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 BUNDLE_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" "$1" "$2" <<'PY'
import gzip
import json
from pathlib import Path
import re
import tarfile
import subprocess
import tempfile
import os
import sys

root, bundle, output = (Path(x).resolve() for x in sys.argv[1:])
build = Path(subprocess.check_output([sys.executable, str(root / 'scripts/apply.py'), 'where', 'build'], text=True).strip()).resolve()
if (output == root or root in output.parents) and build not in output.parents:
    raise SystemExit('Output belongs in build.dir of config.yaml, not in the sources')
if bundle == output or bundle in output.parents:
    raise SystemExit('Output must not be inside the bundle')
app_id = subprocess.check_output([sys.executable, str(root / 'scripts/apply.py'), 'get', 'flutter.desktop_id'], text=True).strip()
required = ['twimshelf', 'lib/libflutter_linux_gtk.so', 'data/flutter_assets',
            'data/video-native-size.json', f'share/applications/{app_id}.desktop',
            f'share/metainfo/{app_id}.metainfo.xml',
            f'share/icons/hicolor/256x256/apps/{app_id}.png']
for relative in required:
    if not (bundle / relative).exists():
        raise SystemExit(f'Missing bundle component: {relative}')
with (bundle/'twimshelf').open('rb') as stream:
    header = stream.read(20)
if header[:4] != b'\x7fELF':
    raise SystemExit('Expected a Linux ELF executable')
if not os.access(bundle/'twimshelf', os.X_OK):
    raise SystemExit('Application is not executable')
if not list((bundle/'lib').glob('libmpv.so*')):
    raise SystemExit('Missing F7a bundled libmpv runtime')
video = json.loads((bundle/'data/video-native-size.json').read_text())
if not isinstance(video.get('native_video_bytes'), int) or video['native_video_bytes'] <= 0:
    raise SystemExit('Invalid F7a runtime size record')
for path in bundle.rglob('*'):
    if path.is_symlink():
        target = path.resolve()
        if Path(os.readlink(path)).is_absolute() or (target != bundle and bundle not in target.parents) or not target.exists():
            raise SystemExit(f'Non-relocatable or dangling symlink: {path.relative_to(bundle)}')
    elif not (path.is_dir() or path.is_file()):
        raise SystemExit(f'Unsupported special file: {path}')
version = re.search(r'^version:\s*(\S+)', (root/'flutter/app/pubspec.yaml').read_text(), re.M).group(1)
if not re.fullmatch(r'[0-9A-Za-z.+_-]+', version):
    raise SystemExit('Invalid package version')
# ELF e_machine determines architecture, including cross-packaged bundles.
if len(header)<20 or header[5] not in (1,2):
    raise SystemExit('Invalid ELF header')
machine=int.from_bytes(header[18:20], 'little' if header[5]==1 else 'big')
architecture={62:'x64',183:'arm64'}.get(machine)
if architecture is None:
    raise SystemExit(f'Unsupported ELF machine: {machine}')
name=f'twimshelf-{version}-linux-{architecture}'
output.mkdir(parents=True, exist_ok=True)
archive=output/f'{name}.tar.gz'
if archive.exists():
    raise SystemExit(f'Output already exists: {archive}')
epoch=int(os.environ.get('SOURCE_DATE_EPOCH','0'))
def normalize(info):
    info.uid=info.gid=0; info.uname=info.gname=''; info.mtime=epoch
    return info
fd, temporary=tempfile.mkstemp(prefix='.twimshelf-', suffix='.partial', dir=output)
try:
    with os.fdopen(fd,'wb') as raw, gzip.GzipFile(fileobj=raw,filename='',mode='wb',mtime=epoch) as zipped:
        with tarfile.open(fileobj=zipped,mode='w',format=tarfile.PAX_FORMAT) as tar:
            tar.add(bundle, arcname=name, filter=normalize)
    os.replace(temporary,archive)
finally:
    if os.path.exists(temporary): os.unlink(temporary)
print(archive)
PY

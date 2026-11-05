#!/usr/bin/env python3
"""Synthetic packaging acceptance; pass a scratch directory (in build.dir or outside the checkout)."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/f'scripts/flutter/{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def check(scratch):
    scratch = Path(scratch).resolve()
    build = Path(subprocess.check_output([sys.executable, str(ROOT / 'scripts/apply.py'), 'where', 'build'], text=True).strip()).resolve()
    if (scratch == ROOT or ROOT in scratch.parents) and build not in scratch.parents:
        raise ValueError('Scratch belongs in build.dir of config.yaml, not in the sources')
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='w1-', dir=scratch) as temporary:
        base = Path(temporary)
        assets = base/'assets'
        desktop_assets = module('desktop_assets')
        app_id = desktop_assets.config('flutter.desktop_id')
        desktop_assets.generate(assets)
        icon = (assets/'app_icon.ico').read_bytes()
        _, kind, count = struct.unpack('<HHH', icon[:6])
        assert kind == 1 and count == 5
        for i in range(count):
            w,h,_,_,_,_,length,offset = struct.unpack('<BBBBHHII', icon[6+i*16:22+i*16])
            data=icon[offset:offset+length]
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            assert struct.unpack('>II',data[16:24]) == (w or 256,h or 256)
        metadata=ET.parse(assets/f'{app_id}.metainfo.xml').getroot()
        assert metadata.find('launchable').text == f'{app_id}.desktop'
        assert len(metadata.findall('name'))==4 and len(metadata.findall('summary'))==4
        for node in metadata.findall('summary'):
            lang=node.attrib.get('{http://www.w3.org/XML/1998/namespace}lang','en')
            assert node.text == json.loads((ROOT/f'flutter/app/assets/l10n/{lang}.json').read_text())['share.subtitle']
        bundle=base/'bundle'
        (bundle/'lib').mkdir(parents=True)
        (bundle/'data/flutter_assets').mkdir(parents=True)
        (bundle/'share/applications').mkdir(parents=True)
        (bundle/'share/metainfo').mkdir(parents=True)
        import shutil
        shutil.copytree(assets/'icons',bundle/'share/icons')
        shutil.copy(assets/f'{app_id}.metainfo.xml',bundle/'share/metainfo')
        (bundle/f'share/applications/{app_id}.desktop').write_text(f'[Desktop Entry]\nType=Application\nName=Test\nExec=twimshelf\nIcon={app_id}\n')
        header=bytearray(64);header[:6]=b'\x7fELF\x02\x01';header[18:20]=(62).to_bytes(2,'little')
        (bundle/'twimshelf').write_bytes(header);(bundle/'twimshelf').chmod(0o755)
        (bundle/'lib/libflutter_linux_gtk.so').write_bytes(b'synthetic')
        (bundle/'lib/libmpv.so.2.0').write_bytes(b'synthetic')
        (bundle/'lib/libmpv.so.2').symlink_to('libmpv.so.2.0')
        (bundle/'data/video-native-size.json').write_text('{"native_video_bytes":9}')
        def package(output, ok):
            result=subprocess.run(['bash',str(ROOT/'scripts/flutter/package_linux.sh'),str(bundle),str(output)],capture_output=True,text=True)
            assert (result.returncode==0)==ok, result.stdout+result.stderr
            return result
        package(base/'packages',True)
        archive=next((base/'packages').glob('*.tar.gz'))
        with tarfile.open(archive) as tar:
            names=tar.getnames()
            assert any(n.endswith('/lib/libmpv.so.2') for n in names)
            assert any(n.endswith('.metainfo.xml') for n in names)
            assert all(m.uid==0 and m.gid==0 and m.mtime==0 for m in tar.getmembers())
            assert next(m for m in tar.getmembers() if m.name.endswith('/lib/libmpv.so.2')).issym()
        package(base/'packages',False)  # Never overwrite a release artifact.
        package(base/'reproducible',True)
        assert archive.read_bytes()==next((base/'reproducible').glob('*.tar.gz')).read_bytes()
        (bundle/'lib/escape').symlink_to('/etc/hosts');package(base/'bad',False);(bundle/'lib/escape').unlink()
        (bundle/'lib/escape').symlink_to('../../../outside');package(base/'bad',False);(bundle/'lib/escape').unlink()
        (bundle/'lib/libmpv.so.2').unlink();(bundle/'lib/libmpv.so.2.0').unlink();package(base/'bad',False)
    print('PASS icons, catalog metadata/messages, reproducible archive, internal links, overwrite/escape/missing-mpv rejection')


if __name__ == '__main__':
    check(sys.argv[1])

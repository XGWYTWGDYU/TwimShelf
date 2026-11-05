#!/usr/bin/env python3
"""Generate synthetic legacy posts. No real photos, downloads or user libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess
import zlib


def png(width, height, index, seed):
    rng = random.Random((seed << 32) + index)
    colour = bytes(rng.randrange(32, 224) for _ in range(3))
    rows = []
    for y in range(height):
        row = bytearray(colour * width)
        if height // 4 <= y < height * 3 // 4:
            row[width // 4 * 3:width * 3 // 4 * 3] = bytes((255, index % 256, 128)) * (width * 3 // 4 - width // 4)
        rows.append(b'\0' + row)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out_dir', type=Path)
    parser.add_argument('--posts', type=int, default=12)
    parser.add_argument('--seed', type=int, default=2026)
    parser.add_argument('--big', action='store_true')
    args = parser.parse_args()
    if args.posts < 3:
        parser.error('--posts must be at least 3')
    root = args.out_dir
    if root.exists() and any(root.iterdir()):
        parser.error('output must be empty (refusing to overwrite data)')
    root.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which('ffmpeg')
    bodies = ['Synthetic seaside, blue sky.', '合成测试：海边与蓝天。', '合成測試：海邊與藍天。', '合成テスト：海と青空。', 'اختبار اصطناعي 🌈', 'Test synthétique — café 🌻']
    sizes = [(384, 384), (640, 360), (360, 640), (64, 2048), (2048, 64), (256, 192)]
    count = max(2000, args.posts) if args.big else args.posts
    for i in range(count):
        folder = root / 'posts' / f'post-{i:04d}'
        folder.mkdir(parents=True)
        post_id = str(1900000000000000000 + i)
        text = f'作者: Seed {i % 6} (@seed{i % 6})\n推文 ID: {post_id}\n发布时间: Mon Jan 01 00:00:00 +0000 2024\n原帖链接: https://x.com/seed{i % 6}/status/{post_id}\n【推文完整正文】\n{bodies[i % len(bodies)]} #{i}\n'
        (folder / '推文内容.txt').write_text(text, encoding='utf-8')
        width, height = sizes[i % len(sizes)]
        data = png(width, height, i, args.seed)
        target = folder / 'photo.png'
        target.write_bytes(data)
        if ffmpeg and i % 3 == 1:
            subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', str(target), '-map_metadata', '-1', '-threads', '1', '-flags', '+bitexact', '-fflags', '+bitexact', str(folder / 'photo.jpg')], check=True)
            target.unlink()
    loose = root / 'loose'
    loose.mkdir()
    (loose / 'loose.png').write_bytes(png(320, 240, count, args.seed))
    (root / 'posts' / 'post-0002' / 'damaged.jpg').write_bytes(b'TL_SYNTHETIC_DAMAGED_IMAGE\n')
    (root / 'posts' / 'post-0002' / 'damaged.png').write_bytes(png(96, 96, count + 1, args.seed))
    if ffmpeg:
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=blue:s=64x64:r=5:d=1', '-an', '-c:v', 'mpeg4', '-threads', '1', '-flags', '+bitexact', '-fflags', '+bitexact', '-map_metadata', '-1', str(root / 'posts' / 'post-0000' / 'video.mp4')], check=True)
    files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()}
    (root / 'seed.json').write_text(json.dumps({'version': 1, 'seed': args.seed, 'posts': count, 'video': bool(ffmpeg), 'sha256': files}, ensure_ascii=False, sort_keys=True, indent=2) + '\n', encoding='utf-8')
    print(f'{count} posts; video={bool(ffmpeg)}; {root}')


if __name__ == '__main__':
    main()

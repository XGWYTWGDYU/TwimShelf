#!/usr/bin/env python3
"""The square artwork a render made (out/<name>-art.png) in the format of the repository's icon.png:
1024 px, the artwork in the Mac squircle (824 px, continuous corners) with a transparent margin.

  python3 icon-design/frame.py c3d-light c3d-dark
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Pillow as the icon scripts get it (from the build cache when this Python has none)
sys.path.insert(0, str(HERE.parent / 'scripts/flutter'))
from make_icons import pillow  # noqa: E402
Image = pillow()
from PIL import ImageDraw  # noqa: E402

S, SIDE, R = 1024, 824, 186
for name in sys.argv[1:]:
    art = Image.open(HERE / 'out' / f'{name}-art.png').convert('RGBA').resize((SIDE, SIDE), Image.Resampling.LANCZOS)
    big = 4   # the corners drawn large and scaled down: smooth edges
    mask = Image.new('L', (SIDE * big, SIDE * big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIDE * big - 1, SIDE * big - 1), radius=R * big, fill=255)
    mask = mask.resize((SIDE, SIDE), Image.Resampling.LANCZOS)
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(art, ((S - SIDE) // 2, (S - SIDE) // 2), mask)
    out.save(HERE / 'out' / f'{name}.png')
    print(f'out/{name}.png')

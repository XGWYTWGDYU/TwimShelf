#!/usr/bin/env python3
"""The mascot's icons (native/Resources/Clawd/*.svg, from TangfanOVO/clawd-icons) as plain vector data
for the Flutter and the native apps: no SVG library, no rendered pictures.

  python3 scripts/gen_icons.py
"""
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'native/Resources/Clawd'
NS = '{http://www.w3.org/2000/svg}'


def num(v):
    s = f'{v:.3f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def arc(x0, y0, rx, ry, rot, large, sweep, x, y):
    """An SVG arc as cubic curves."""
    if rx == 0 or ry == 0 or (x0 == x and y0 == y):
        return [('L', x, y)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(rot)
    c, s = math.cos(phi), math.sin(phi)
    dx, dy = (x0 - x) / 2, (y0 - y) / 2
    x1, y1 = c * dx + s * dy, -s * dx + c * dy
    k = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if k > 1:
        rx, ry = rx * math.sqrt(k), ry * math.sqrt(k)
    a = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    b = rx * rx * y1 * y1 + ry * ry * x1 * x1
    f = math.sqrt(max(0, a / b)) * (-1 if large == sweep else 1)
    cx1, cy1 = f * rx * y1 / ry, -f * ry * x1 / rx
    cx, cy = c * cx1 - s * cy1 + (x0 + x) / 2, s * cx1 + c * cy1 + (y0 + y) / 2
    t1 = math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
    t2 = math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
    d = t2 - t1
    if sweep and d < 0:
        d += math.tau
    if not sweep and d > 0:
        d -= math.tau
    parts = max(1, math.ceil(abs(d) / (math.pi / 2) - 1e-9))
    out = []
    h = 4 / 3 * math.tan(d / parts / 4)
    def point(px, py):
        return c * rx * px - s * ry * py + cx, s * rx * px + c * ry * py + cy
    for i in range(parts):
        a1, a2 = t1 + d * i / parts, t1 + d * (i + 1) / parts
        p1 = point(math.cos(a1) - h * math.sin(a1), math.sin(a1) + h * math.cos(a1))
        p2 = point(math.cos(a2) + h * math.sin(a2), math.sin(a2) - h * math.cos(a2))
        p3 = point(math.cos(a2), math.sin(a2))
        out.append(('C', *p1, *p2, *p3))
    return out


def tokens(d):
    i = 0
    pattern = re.compile(r'\s*,?\s*([a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)')
    while i < len(d):
        m = pattern.match(d, i)
        if not m:
            if d[i:].strip():
                raise ValueError(d[i:])
            return
        yield m.group(1)
        i = m.end()


def arc_flags(d):
    """Arc flags may be written without separators ("a1 1 0 011 1"): separate them first."""
    return re.sub(r'([aA])([^a-zA-Z]*)', lambda m: m.group(1) + _split_flags(m.group(2)), d)


def _split_flags(args):
    out, i, n = [], 0, 0
    pattern = re.compile(r'\s*,?\s*([-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)')
    while i < len(args):
        if n % 7 in (3, 4):
            m = re.compile(r'\s*,?\s*([01])').match(args, i)
        else:
            m = pattern.match(args, i)
        if not m:
            break
        out.append(m.group(1))
        i, n = m.end(), n + 1
    return ' '.join(out)


COUNT = dict(M=2, L=2, H=1, V=1, C=6, S=4, Q=4, T=2, A=7, Z=0)


def path(d, ox, oy):
    """Absolute M, L, C and Z only, moved by the groups' translations."""
    t = list(tokens(arc_flags(d)))
    i, out = 0, []
    x = y = sx = sy = 0.0
    last_c = last_q = None
    cmd = None
    while i < len(t):
        if re.fullmatch('[a-zA-Z]', t[i]):
            cmd = t[i]
            i += 1
        up = cmd.upper()
        rel = cmd != up
        n = COUNT[up]
        a = [float(v) for v in t[i:i + n]]
        i += n
        bx, by = (x, y) if rel else (0.0, 0.0)
        ctrl_c, ctrl_q = None, None
        if up == 'M':
            x, y = a[0] + bx, a[1] + by
            sx, sy = x, y
            out.append(('M', x, y))
            cmd = 'l' if rel else 'L'
        elif up == 'L':
            x, y = a[0] + bx, a[1] + by
            out.append(('L', x, y))
        elif up == 'H':
            x = a[0] + bx
            out.append(('L', x, y))
        elif up == 'V':
            y = a[0] + by
            out.append(('L', x, y))
        elif up == 'C':
            p = [a[0] + bx, a[1] + by, a[2] + bx, a[3] + by, a[4] + bx, a[5] + by]
            out.append(('C', *p))
            ctrl_c = (p[2], p[3])
            x, y = p[4], p[5]
        elif up == 'S':
            c1 = (2 * x - last_c[0], 2 * y - last_c[1]) if last_c else (x, y)
            p = [a[0] + bx, a[1] + by, a[2] + bx, a[3] + by]
            out.append(('C', *c1, *p))
            ctrl_c = (p[0], p[1])
            x, y = p[2], p[3]
        elif up in ('Q', 'T'):
            if up == 'Q':
                q = (a[0] + bx, a[1] + by)
                ex, ey = a[2] + bx, a[3] + by
            else:
                q = (2 * x - last_q[0], 2 * y - last_q[1]) if last_q else (x, y)
                ex, ey = a[0] + bx, a[1] + by
            out.append(('C', x + 2 / 3 * (q[0] - x), y + 2 / 3 * (q[1] - y), ex + 2 / 3 * (q[0] - ex), ey + 2 / 3 * (q[1] - ey), ex, ey))
            ctrl_q = q
            x, y = ex, ey
        elif up == 'A':
            ex, ey = a[5] + bx, a[6] + by
            out.extend(arc(x, y, a[0], a[1], a[2], bool(a[3]), bool(a[4]), ex, ey))
            x, y = ex, ey
        elif up == 'Z':
            x, y = sx, sy
            out.append(('Z',))
        last_c, last_q = ctrl_c, ctrl_q
    words = []
    for c in out:
        words.append(c[0])
        for j in range(1, len(c), 2):
            words += [num(c[j] + ox), num(c[j + 1] + oy)]
    return ' '.join(words)


def circle(cx, cy, r):
    k = 0.5522847498 * r
    return (f'M {cx + r} {cy} C {cx + r} {cy + k} {cx + k} {cy + r} {cx} {cy + r} C {cx - k} {cy + r} {cx - r} {cy + k} {cx - r} {cy} '
            f'C {cx - r} {cy - k} {cx - k} {cy - r} {cx} {cy - r} C {cx + k} {cy - r} {cx + r} {cy - k} {cx + r} {cy} Z')


def walk(e, fill, stroke, ox, oy, out):
    if e.get('opacity') == '0':
        return
    fill, stroke = e.get('fill', fill), e.get('stroke', stroke)
    t = e.get('transform')
    if t:
        m = re.fullmatch(r'translate\(([-\d.]+)[ ,]+([-\d.]+)\)', t)
        if not m:
            raise ValueError(t)
        ox, oy = ox + float(m[1]), oy + float(m[2])
    tag = e.tag.replace(NS, '')
    d = None
    if tag == 'path':
        d = path(e.get('d'), ox, oy)
    elif tag == 'circle':
        d = path(circle(float(e.get('cx')), float(e.get('cy')), float(e.get('r'))), ox, oy)
    elif tag == 'rect':
        x, y, w, h = (float(e.get(k)) for k in ('x', 'y', 'width', 'height'))
        r = float(e.get('rx', 0))
        if r:
            k = 0.5522847498 * r
            d = path(f'M {x + r} {y} L {x + w - r} {y} C {x + w - r + k} {y} {x + w} {y + r - k} {x + w} {y + r} L {x + w} {y + h - r} '
                     f'C {x + w} {y + h - r + k} {x + w - r + k} {y + h} {x + w - r} {y + h} L {x + r} {y + h} '
                     f'C {x + r - k} {y + h} {x} {y + h - r + k} {x} {y + h - r} L {x} {y + r} C {x} {y + r - k} {x + r - k} {y} {x + r} {y} Z', ox, oy)
        else:
            d = path(f'M {x} {y} L {x + w} {y} L {x + w} {y + h} L {x} {y + h} Z', ox, oy)
    elif tag not in ('svg', 'g'):
        raise ValueError(tag)
    if d:
        if fill != 'none':
            out.append((int(fill[1:], 16) if fill.startswith('#') else None, False, d))
        if stroke != 'none':
            out.append((None, True, d))
    for child in e:
        walk(child, fill, stroke, ox, oy, out)


def main():
    icons = {}
    for f in sorted(SOURCE.glob('*.svg')):
        root = ET.parse(f).getroot()
        ops = []
        walk(root, 'none', 'none', 0, 0, ops)
        icons[f.stem] = ops
    head = 'Generated by scripts/gen_icons.py from native/Resources/Clawd (TangfanOVO/clawd-icons, MIT). Do not edit.'
    dart = [f'// {head}', '// ignore_for_file: constant_identifier_names', '',
            '/// One drawing step: a fill colour (0xRRGGBB; null with [stroke] false is the foreground colour),',
            '/// or a stroke in the foreground colour; [d] uses only M, L, C and Z in a 24×24 box.',
            'class ClawdOp {', '  const ClawdOp(this.fill, this.stroke, this.d);', '  final int? fill;', '  final bool stroke;', '  final String d;', '}', '',
            'const clawdIcons = <String, List<ClawdOp>>{']
    swift = [f'// {head}', '', '/// Drawing steps in a 24×24 box: a fill colour (0xRRGGBB, or nil and stroke false for the', '/// foreground colour) or a stroke in the foreground colour; only M, L, C and Z.',
             'enum ClawdIconData {', '    static let icons: [String: [(fill: UInt32?, stroke: Bool, d: String)]] = [']
    for name, ops in icons.items():
        dart.append(f"  '{name}': [")
        swift.append(f'        "{name}": [')
        for fill, stroke, d in ops:
            fd = 'null' if fill is None else f'0x{fill:06X}'
            sd = 'nil' if fill is None else f'0x{fill:06X}'
            dart.append(f"    ClawdOp({fd}, {str(stroke).lower()}, '{d}'),")
            swift.append(f'            (fill: {sd}, stroke: {str(stroke).lower()}, d: "{d}"),')
        dart.append('  ],')
        swift.append('        ],')
    dart.append('};')
    swift += ['    ]', '}']
    target = ROOT / 'flutter/app/lib/mascot/clawd_icons.g.dart'
    target.parent.mkdir(exist_ok=True)
    target.write_text('\n'.join(dart) + '\n', encoding='utf-8')
    (ROOT / 'native/Shared/ClawdIconData.swift').write_text('\n'.join(swift) + '\n', encoding='utf-8')
    print(f'{len(icons)} icons')


main()

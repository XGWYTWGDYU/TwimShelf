"""C in 3D: a pegboard on a white wall in a soft warm light from the top left, sheets pinned on it (black on the white board, white on the black one).

  /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P icon-design/pegboard_blender.py -- light
  (or dark: the black board)

Writes icon-design/out/c3d-<mode>-art.png, the square artwork (what iOS shows, cut to its edges),
and c3d-<mode>.png in the format of icon.png (the Mac squircle with its transparent margin) is made
from it by icon-design/frame.py. The pictures are the test photos of the MTK build (public domain /
CC0) were dropped: plain sheets of paper read better.
"""
import math
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

HERE = Path(__file__).resolve().parent
MODE = (sys.argv[sys.argv.index('--') + 1] if '--' in sys.argv else 'light')
OUT = HERE / 'out'
OUT.mkdir(exist_ok=True)

# ---- the scene: metres, the wall is the plane y = 0 facing -y, the camera looks along +y
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def material(name, color, rough=0.5, metal=0.0, image=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Roughness'].default_value = rough
    bsdf.inputs['Metallic'].default_value = metal
    if image:
        tex = m.node_tree.nodes.new('ShaderNodeTexImage')
        tex.image = bpy.data.images.load(str(image))
        m.node_tree.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    return m


def box(name, size, location, mat, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location, rotation=rotation)
    o = bpy.context.object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(mat)
    return o


def bevel(o, width, segments=3):
    m = o.modifiers.new('bevel', 'BEVEL')
    m.width = width
    m.segments = segments
    m.limit_method = 'ANGLE'


white_wall = material('wall', (0.92, 0.9, 0.86), rough=0.85)
board_mat = material('board', (0.86, 0.85, 0.83) if MODE == 'light' else (0.025, 0.025, 0.026), rough=0.42)
paper = material('paper', (0.93, 0.93, 0.92), rough=0.55)

# the wall, far larger than the view
box('wall', (8, 0.1, 8), (0, 0.05, 0), white_wall)

# the pegboard: 1.25 x 1 m, 12 mm thick, 30 mm off the wall, a grid of real holes
BW, BH, T, GAP = 1.25, 1.0, 0.012, 0.03
board = box('board', (BW, T, BH), (0, -(GAP + T / 2), 0), board_mat)
bevel(board, 0.006)
holes = bpy.data.meshes.new('holes')
bm = bmesh.new()
step = 0.075
nx, nz = int(BW / step) - 1, int(BH / step) - 1
sx, sz = -(nx - 1) * step / 2, -(nz - 1) * step / 2
for i in range(nx):
    for j in range(nz):
        m = bmesh.ops.create_cone(bm, cap_ends=True, segments=20, radius1=0.0105, radius2=0.0105, depth=0.1)
        for v in m['verts']:
            v.co = Vector((v.co.x, -v.co.z, v.co.y)) + Vector((sx + i * step, -(GAP + T / 2), sz + j * step))
bm.to_mesh(holes)
bm.free()
cutter = bpy.data.objects.new('holes', holes)
scene.collection.objects.link(cutter)
cut = board.modifiers.new('holes', 'BOOLEAN')
cut.operation = 'DIFFERENCE'
cut.object = cutter
cut.solver = 'EXACT'
cutter.hide_render = True
cutter.hide_viewport = True

# ---- pictures pinned on the board: a white print, the photo on it, a round pin at the top
FRONT = -(GAP + T)
PINS = [(0.82, 0.08, 0.05), (0.95, 0.48, 0.02), (0.08, 0.5, 0.22)]


def pin_print(name, shade, w, h, x, z, angle, pin_color):
    tilt = math.radians(angle)
    pivot = Vector((x, FRONT, z + h / 2 - 0.03))   # the pin, near the top
    parts = []
    sheet = material(f'{name}-paper', shade, rough=0.6)
    card = box(f'{name}-card', (w, 0.0016, h), (x, FRONT - 0.008, z), sheet)  # off the board: its shadow shows
    parts.append(card)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.019, location=(pivot.x, FRONT - 0.02, pivot.z), segments=32, ring_count=16)
    head = bpy.context.object
    head.scale = (1, 0.7, 1)
    head.data.materials.append(material(f'{name}-pin', pin_color, rough=0.22))
    bpy.ops.object.shade_smooth()
    parts.append(head)
    for p in parts:
        p.rotation_euler.rotate_axis('Y', -tilt)
        p.location = pivot + (p.location - pivot).copy()
        # rotate the position about the pin
        off = p.location - pivot
        p.location = pivot + Vector((off.x * math.cos(tilt) - off.z * math.sin(tilt), off.y, off.x * math.sin(tilt) + off.z * math.cos(tilt)))


# sheets of paper, no pictures: a little different in size and white, the colour is the pins'
# light mode: black cards on the white board; dark mode: white cards on the black board
CARDS = [(0.035, 0.035, 0.04), (0.05, 0.05, 0.055), (0.028, 0.028, 0.032)] if MODE == 'light' else \
    [(0.97, 0.965, 0.955), (0.95, 0.94, 0.92), (0.98, 0.975, 0.97)]
# one group in the middle of the board: a tall card on the left, a wide one at the top right, a
# squarer one below it; small tilts, and each pin in a hole of the grid (holes every 75 mm:
# x = 0, ±0.075, ±0.15 …, z = ±0.0375, ±0.1125, ±0.1875 …). pin_print takes the card's middle, the
# pin sits 30 mm below its top edge.
def card(name, shade, w, h, pin_x, pin_z, angle, pin):
    pin_print(name, shade, w, h, pin_x, pin_z - h / 2 + 0.03, angle, pin)


card('a', CARDS[0], 0.34, 0.42, -0.15, 0.1875, -2.5, PINS[0])
card('b', CARDS[1], 0.30, 0.24, 0.225, 0.2625, 3.0, PINS[1])
card('c', CARDS[2], 0.26, 0.30, 0.225, -0.0375, -2.0, PINS[2])

# ---- light: a soft warm beam from the top left (a large spot, its edge fading out), no window:
# the wall is brightest at the top left and falls off to the bottom right; the shadows are soft
target = Vector((-0.32, 0, 0.26))
src = Vector((-1.9, -2.3, 2.4))
bpy.ops.object.light_add(type='SPOT', location=src)
beam = bpy.context.object
beam.data.energy = 1700
beam.data.color = (1.0, 0.9, 0.76)
beam.data.spot_size = math.radians(48)
beam.data.spot_blend = 0.85
beam.data.shadow_soft_size = 0.35
beam.rotation_euler = (target - src).to_track_quat('-Z', 'Y').to_euler()

world = bpy.data.worlds.new('sky')
scene.world = world
world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.96, 0.92, 0.86, 1)
world.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.45

# ---- camera: square, the board in the middle two thirds (Android's safe zone)
# straight at the board's middle: its edges stay parallel to the picture's (from the side, the
# perspective made it look crooked); its depth shows in the light and the shadows
bpy.ops.object.camera_add(location=(0, -3.35, 0), rotation=(math.radians(90), 0, 0))
cam = bpy.context.object
cam.data.lens = 85
cam.data.sensor_width = 36
scene.camera = cam

scene.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'
prefs.get_devices()
for d in prefs.devices:
    d.use = d.type == 'METAL'
scene.cycles.device = 'GPU'
scene.cycles.samples = int(sys.argv[sys.argv.index('--') + 2]) if '--' in sys.argv and len(sys.argv) > sys.argv.index('--') + 2 else 160
scene.cycles.use_denoising = True
scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.film_transparent = False
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = -0.15
scene.render.filepath = str(OUT / f'c3d-{MODE}-art.png')
bpy.ops.render.render(write_still=True)
print('wrote', scene.render.filepath)

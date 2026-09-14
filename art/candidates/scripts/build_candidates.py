"""Editable Acorn Hopper / Moss Mouse proof, built in a disposable Blender 5.2.

No generated 3D mesh, hair, external textures, or add-ons. Every pose is a real
armature Action with separate export compensation. Review renders stay in .build.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[3]
BUILDER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
sys.path.insert(0, str(ROOT / "art/sprout/scripts"))
from build_design import (aim, area, blend, camera, collection, ellipsoid,
                          face_point, leaf, line, linear, material, mesh_object,
                          move_to, smoothstep, subdivide)
from sample_motion import apply_pose, around, linear_keys, new_action, rotation, translation

FPS, COUNT, PIXELS, POINTS, REVIEW_POINTS = 30, 24, 448, 224, 96
NAMES = {"acorn-hopper": "Acorn Hopper", "moss-mouse": "Moss Mouse"}
TRAVEL = {'acorn-hopper': 3.2, 'moss-mouse': 3.0}
GREEN, CREAM, LEAF, BLUSH = map(linear, ("8C9351", "F4DDB1", "737F3E", "DD947A"))


def json_file(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def freeze(obj):
    if obj.type == 'CURVE':
        source = obj.data
        source.use_fake_user = True
        bpy.ops.object.select_all(action='DESELECT')
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.convert(target='MESH')
        obj = bpy.context.object
    obj.data.transform(obj.matrix_world)
    obj.matrix_world = Matrix.Identity(4)
    return obj


def paint(obj, fn):
    colors = obj.data.color_attributes.new(name="CoatTint", type='FLOAT_COLOR', domain='POINT')
    values = array('f')
    for v in obj.data.vertices:
        values.extend((*fn(v.co), 1))
    colors.data.foreach_set('color', values)


def face_color(point, mouse=False):
    x, y, z = point
    if mouse:
        eye_z, eye_x, forehead, lower = .62, .205, .51, .28
        ex, ez, bx, bz = .245, .29, .49, .35
        front = smoothstep(.38, .65, -y)
    else:
        eye_z, eye_x, forehead, lower = .94, .24, .89, .48
        ex, ez, bx, bz = .26, .38, .52, .57
        front = smoothstep(.08, .26, -y)
    eyes = max(1 - ((x - side * eye_x) / ex) ** 2 - ((z - eye_z) / ez) ** 2 for side in (-1, 1))
    belly = 1 - (x / bx) ** 2 - ((z - lower) / bz) ** 2
    mask = smoothstep(-.19, .14, max(eyes, belly))
    brow_width = max(0, .54 * (z - forehead))
    mask *= 1 - smoothstep(-.028, .028, brow_width - abs(x)) * smoothstep(forehead, forehead + .06, z)
    mask *= front
    color = blend(GREEN, CREAM, mask)
    blush = math.exp(-((abs(x) - (eye_x + .08)) / .115) ** 2 - ((z - eye_z + .13) / .075) ** 2)
    return blend(color, BLUSH, blush * mask * .67)


def profile_mesh(name, profile, depth, bucket, mat):
    vertices, faces, segments = [], [], 64
    for z, radius in profile:
        for j in range(segments):
            a = j * 2 * math.pi / segments
            vertices.append((radius * math.cos(a), radius * depth * math.sin(a), z))
    for row in range(len(profile) - 1):
        for j in range(segments):
            k = (j + 1) % segments
            faces.append((row * segments + j, row * segments + k,
                          (row + 1) * segments + k, (row + 1) * segments + j))
    bottom, top = len(vertices), len(vertices) + 1
    vertices.extend(((0, 0, profile[0][0]), (0, 0, profile[-1][0])))
    for j in range(segments):
        k = (j + 1) % segments
        faces.extend(((bottom, k, j), (top, (len(profile) - 1) * segments + j,
                                     (len(profile) - 1) * segments + k)))
    obj = mesh_object(name, vertices, faces, bucket, mat)
    subdivide(obj, 3 if name.startswith('Body') else 2)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier=obj.modifiers[0].name)
    return obj


class Character:
    def __init__(self, candidate):
        self.candidate = candidate
        self.mouse = candidate == 'moss-mouse'
        self.bucket = collection(NAMES[candidate] + " · editable character")
        self.parts, self.specs, self.feet, self.eyes = [], [], {}, []
        self.body_pivot = Vector((0, 0, .11))
        self.head_pivot = Vector((0, -.28, .57)) if self.mouse else self.body_pivot
        self.coat = material("Moss and cream · vertex paint", GREEN, .80, .07, attribute=True)
        self.green = material("Moss · soft matte", GREEN, .80, .07)
        self.leaf_mat = material("Leaves · olive", LEAF, .77, .05)
        self.ink = material("Face · warm dark brown", linear("382D21"), .56)
        self.eye_mat = material("Eyes · dark glass", linear("181710"), .24)
        self.eye_mat.node_tree.nodes.get('Principled BSDF').inputs['Specular IOR Level'].default_value = .40
        self.spec('Stage', (0, 0, 0), None)
        self.spec('Root', (0, 0, 0), 'Stage')
        self.spec('Body', self.body_pivot, 'Root')
        if self.mouse:
            self.spec('Head', self.head_pivot, 'Body')

    def spec(self, name, pivot, parent):
        self.specs.append((name, Vector(pivot), parent))

    def part(self, obj, bone):
        obj = freeze(obj)
        self.parts.append((obj, bone))
        return obj

    def ball(self, name, center, scale, mat, bone, color_fn=None):
        obj = self.part(ellipsoid(name, center, scale, self.bucket, mat), bone)
        if color_fn:
            subdivide(obj, 2)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.modifier_apply(modifier=obj.modifiers[-1].name)
            paint(obj, color_fn)
        return obj

    def curve(self, name, points, radius, mat, bone):
        return self.part(line(name, points, radius, self.bucket, mat), bone)

    def foliage(self, name, base, tip, width, bone, thickness=.05):
        obj = leaf(name, base, tip, width, thickness, self.bucket, self.leaf_mat, LEAF, bend=.055)
        self.part(obj, bone)
        # One shallow ridge, never hundreds of modeled veins or cap scales.
        a, b = Vector(base), Vector(tip)
        points = [a.lerp(b, t) + Vector((0, -.055 * math.sin(math.pi * t), .012)) for t in (.10, .45, .82)]
        self.curve(name + " · midrib", points, .009, self.leaf_mat, bone)

    def face(self, surface):
        mouse = self.mouse
        control = 'Head' if mouse else 'Body'
        eye_x, eye_z = (.205, .62) if mouse else (.235, .95)
        for side, label in ((-1, 'L'), (1, 'R')):
            pos = face_point(surface, side * eye_x, eye_z, .008)
            eye = self.ball("Eye." + label, pos, (.103, .061, .114) if mouse else (.111, .064, .126), self.eye_mat, control)
            eye.shape_key_add(name='Basis')
            blink = eye.shape_key_add(name='Blink')
            for v in blink.data:
                v.co.z = pos.z + (v.co.z - pos.z) * .085
            self.eyes.append(eye)
            brow_z = eye_z + (.183 if mouse else .219)
            points = [face_point(surface, side * x, z, .014) for x, z in (
                (eye_x - .054, brow_z), (eye_x, brow_z + (.027 if side < 0 else -.012)),
                (eye_x + .058, brow_z - .007))]
            self.curve('Brow.' + label, points, .009, self.ink, control)
        nose_z = .501 if mouse else .804
        pos = face_point(surface, 0, nose_z, .017)
        self.ball('Nose', pos, (.035, .029, .023), self.ink, control)
        self.curve('Nose philtrum', [face_point(surface, 0, z, .013) for z in (nose_z - .018, nose_z - .061)], .009, self.ink, control)
        for side in (-1, 1):
            points = [face_point(surface, side * x, z, .013) for x, z in (
                (0, nose_z - .059), (.039, nose_z - .081), (.077, nose_z - .055))]
            self.curve('Smile.' + str(side), points, .009, self.ink, control)

    def build(self):
        if self.mouse:
            self.ball('Body · low bean', (0, .35, .43), (.49, .79, .36), self.coat, 'Body',
                      lambda p: blend(GREEN, CREAM, (1 - smoothstep(.23, .36, p.z)) * .96))
            head = self.ball('Head · round cheeks', (0, -.40, .535), (.57, .46, .455), self.coat, 'Head',
                             lambda p: face_color(p, True))
            for side, label in ((-1, 'L'), (1, 'R')):
                base = (side * .28, -.31, .89)
                tip = (side * (.56 if side < 0 else .65), -.20, 1.57 if side < 0 else 1.40)
                self.spec('Ear.' + label, base, 'Head')
                self.foliage('Leaf ear.' + label, base, tip, .205, 'Ear.' + label, .065)
                for y, suffix in ((-.39, 'front'), (.65, 'back')):
                    name = 'Foot.' + label + '.' + suffix
                    center = Vector((side * .32, y, .105))
                    self.spec(name, center, 'Root')
                    self.feet[name] = center
                    self.ball(name, center, (.15, .21, .105), self.leaf_mat, name)
            self.spec('Tail', (0, .97, .47), 'Body')
            self.curve('Tail · tapered sprig', [(0, .97, .47), (-.035, 1.12, .48), (-.07, 1.26, .63), (-.055, 1.32, .77)], .029, self.leaf_mat, 'Tail')
            self.foliage('Tail leaf', (-.055, 1.26, .68), (-.105, 1.49, .96), .091, 'Tail', .025)
        else:
            profile = [(.12, .10), (.15, .31), (.25, .50), (.44, .63), (.69, .67),
                       (.96, .65), (1.20, .58), (1.39, .47), (1.51, .28), (1.54, .06)]
            head = self.part(profile_mesh('Body · rounded acorn', profile, .77, self.bucket, self.coat), 'Body')
            paint(head, face_color)
            cap_mat = material('Cap · warm chestnut', linear('96643B'), .88, .04)
            nodes = cap_mat.node_tree.nodes
            noise = nodes.new('ShaderNodeTexVoronoi')
            noise.inputs['Scale'].default_value = 13
            bump = nodes.new('ShaderNodeBump')
            bump.inputs['Strength'].default_value = .24
            bump.inputs['Distance'].default_value = .028
            cap_mat.node_tree.links.new(noise.outputs['Distance'], bump.inputs['Height'])
            cap_mat.node_tree.links.new(bump.outputs['Normal'], nodes.get('Principled BSDF').inputs['Normal'])
            self.spec('Cap', (0, 0, 1.30), 'Body')
            cap_profile = [(1.27, .59), (1.28, .69), (1.33, .725), (1.43, .71),
                           (1.57, .60), (1.69, .43), (1.75, .22), (1.76, .025)]
            self.part(profile_mesh('Cap · single shell', cap_profile, .80, self.bucket, cap_mat), 'Cap')
            self.curve('Stem', [(0, .015, 1.68), (-.022, .018, 1.85), (-.075, .018, 2.00)], .052, cap_mat, 'Cap')
            self.spec('Leaf', (.01, .02, 1.80), 'Cap')
            self.foliage('Off-center leaf', (.01, .02, 1.80), (.61, .04, 2.12), .211, 'Leaf')
            for side, label in ((-1, 'L'), (1, 'R')):
                name = 'Foot.' + label
                center = Vector((side * .30, -.13, .104))
                self.spec(name, center, 'Root')
                self.feet[name] = center
                self.ball(name, center, (.19, .22, .104), self.leaf_mat, name)
                self.spec('Arm.' + label, (side * .52, -.24, .66), 'Body')
                self.ball('Paw.' + label, (side * .565, -.275, .565), (.139, .149, .189), self.green, 'Arm.' + label)
        bpy.context.view_layer.update()
        self.face(head)
        if not self.mouse:
            # The first camera review was too upright. Broaden the complete
            # construction and lower it while keeping feature/rig alignment.
            proportion = Matrix.Diagonal((1.09, 1.02, .92, 1))
            for obj, _ in self.parts:
                obj.data.transform(proportion, shape_keys=True)
            self.specs = [(name, proportion @ pivot, parent) for name, pivot, parent in self.specs]
            self.feet = {name: proportion @ pivot for name, pivot in self.feet.items()}
            self.body_pivot = proportion @ self.body_pivot
        self.rig = self.make_rig()

    def make_rig(self):
        data = bpy.data.armatures.new(NAMES[self.candidate] + ' · control skeleton')
        rig = bpy.data.objects.new(NAMES[self.candidate] + ' Rig', data)
        self.bucket.objects.link(rig)
        rig.show_in_front, data.display_type = True, 'STICK'
        bpy.ops.object.select_all(action='DESELECT')
        rig.select_set(True)
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.mode_set(mode='EDIT')
        for name, pivot, parent in self.specs:
            bone = data.edit_bones.new(name)
            bone.head, bone.tail = pivot, pivot + Vector((0, 0, .17))
            if parent:
                bone.parent = data.edit_bones[parent]
        bpy.ops.object.mode_set(mode='OBJECT')
        for bone in rig.pose.bones:
            bone.rotation_mode = 'QUATERNION'
        for obj, bone in self.parts:
            obj.vertex_groups.new(name=bone).add(list(range(len(obj.data.vertices))), 1, 'REPLACE')
            modifier = obj.modifiers.new('Editable character rig', 'ARMATURE')
            modifier.object = rig
        rig['notes'] = '24-frame authored dash/hop; Stage cancels travel only for sprite export. Eye Blink shape keys remain editable.'
        return rig


def smooth(t):
    t = min(1, max(0, t))
    return t * t * (3 - 2 * t)


def pulse(t, start, peak, end):
    return smooth((t - start) / (peak - start)) if t < peak else 1 - smooth((t - peak) / (end - peak))


def motion(character, index, axis, direction=1):
    """Two low bounds for mouse, one bigger sideways hop for acorn.

    Root movement happens only in the airborne intervals. All planted sole
    markers remain fixed in world space, including anticipation and landing.
    """
    mouse = character.mouse
    travel, lift, airborne = 0., 0., False
    if mouse:
        if 4 < index < 16:
            cycle = 0 if index <= 10 else 1
            u = (index - (4 + cycle * 6)) / 6
            travel = 1.5 * (cycle + smooth(u))
            lift = .13 * math.sin(math.pi * u)
            airborne = 0 < u < 1
        elif index >= 16:
            travel = 3.
        compression = .11 * pulse(index, 0, 3, 6) + .14 * pulse(index, 15, 17, 23)
        stretch = .12 * (pulse(index, 4, 7, 10) + pulse(index, 10, 13, 16))
    else:
        u = min(1, max(0, (index - 5) / 10))
        travel = TRAVEL[character.candidate] * smooth(u)
        lift = .49 * math.sin(math.pi * u)
        airborne = 5 < index < 15
        compression = .15 * pulse(index, 0, 4, 7) + .17 * pulse(index, 14, 17, 23)
        stretch = .105 * pulse(index, 5, 8, 13)
    shift = axis * travel * direction
    root = translation(shift)
    z_scale = 1 - compression + stretch
    scale = Matrix.Diagonal((1 + compression * .45, 1 + compression * .45, z_scale, 1))
    if mouse:
        scale = Matrix.Diagonal((1 + compression * .22, 1 + stretch, 1 - compression - stretch * .35, 1))
    envelope = math.sin(math.pi * index / (COUNT - 1)) ** 2
    lean_axis = Vector((-axis.y, axis.x, 0))
    lean = Matrix.Rotation(direction * (.11 if mouse else .17) * envelope, 4, lean_axis)
    yaw = 0.
    if mouse:
        heading = math.atan2(axis.x * direction, -axis.y * direction) * .62
        yaw = heading * smooth((index - 4) / 2) * (1 - smooth((index - 13) / 3))
    turn = around((0, .30, 0), rotation('Z', yaw)) if mouse else Matrix.Identity(4)
    body = root @ turn @ translation((0, 0, lift)) @ around(character.body_pivot, lean @ scale)
    deforms = {'Stage': Matrix.Identity(4), 'Root': root, 'Body': body}
    if mouse:
        head = body @ around(character.head_pivot, rotation('X', -.055 * envelope))
        deforms['Head'] = head
    else:
        head = body
    for name, pivot, parent in character.specs:
        if name in deforms or name in character.feet:
            continue
        amount = math.sin((index - 4) * .56) * envelope
        if name.startswith('Ear'):
            deform = head @ around(pivot, rotation('X', .23 * envelope + .10 * amount))
        elif name == 'Tail':
            deform = body @ around(pivot, rotation('X', -.25 * envelope) @ rotation('Z', .14 * amount))
        elif name == 'Cap':
            deform = body @ around(pivot, Matrix.Rotation(-direction * .08 * amount, 4, lean_axis))
        elif name == 'Leaf':
            deform = deforms['Cap'] @ around(pivot, rotation('Y', -.24 * amount))
        else:
            side = -1 if name.endswith('.L') else 1
            deform = body @ around(pivot, rotation('Y', side * .28 * envelope))
        deforms[name] = deform
    contacts = {}
    for foot_index, (name, center) in enumerate(character.feet.items()):
        offset = Vector((0, 0, lift))
        if airborne:
            # Feet fold only during flight and return to a flat, fixed sole.
            offset += axis * (.08 * math.sin(index * .8 + foot_index) * envelope)
            offset.z += .04 * envelope
        deforms[name] = translation(shift + offset) @ turn
        marker = deforms[name] @ Vector((center.x, center.y, 0))
        contacts[name] = {'planted': not airborne, 'world': list(marker)}
    matrices = {name: deform @ character.rig.data.bones[name].matrix_local for name, deform in deforms.items()}
    blink = .94 * pulse(index, 1, 3, 5) + .65 * pulse(index, 16, 17, 19)
    return matrices, contacts, shift, blink


def stage(character, args):
    scene = bpy.context.scene
    studio = collection('STUDIO · fixed camera and soft lights')
    world = bpy.data.worlds.new('Soft neutral ambient')
    world.node_tree.nodes.get('Background').inputs['Color'].default_value = (.82, .86, .93, 1)
    world.node_tree.nodes.get('Background').inputs['Strength'].default_value = .45
    scene.world = world
    area('Key · large softbox', (-3, -4, 6), 370, 4., studio, (1, .94, .83))
    area('Fill', (4, -2, 3.5), 95, 3.5, studio, (.88, .94, 1))
    area('Rim', (1, 4, 4.5), 190, 3., studio, (1, .94, .80))
    target = (0, .32, .98) if character.mouse else (0, 0, 1.32)
    scale = args.camera_scale or (2.80 if character.mouse else 3.00)
    hero_location = (7.5, -10, 3.15) if character.mouse else (3.0, -10, 3.1)
    cameras = {
        'hero': camera('Camera · runtime', hero_location, studio, target, scale),
        'front': camera('Camera · front orthographic', (0, -12, target[2]), studio, target, scale),
        'side': camera('Camera · side orthographic', (12, target[1], target[2]), studio, target, 3.20 if character.mouse else scale),
        'back': camera('Camera · back orthographic', (0, 12, target[2]), studio, target, scale),
    }
    scene.camera = cameras['hero']
    scene.render.engine = 'CYCLES'
    scene.cycles.samples, scene.cycles.use_denoising = args.samples, False
    scene.view_layers[0].cycles.denoising_store_passes = True
    scene.cycles.use_animated_seed = False
    scene.cycles.seed = 317
    scene.cycles.max_bounces = 5
    scene.render.dither_intensity = 0
    scene.cycles.device = 'CPU'
    if args.device == 'METAL':
        preferences = bpy.context.preferences.addons['cycles'].preferences
        preferences.compute_device_type = 'METAL'
        preferences.refresh_devices()
        for device in preferences.devices:
            device.use = device.type == 'METAL'
        if any(device.use for device in preferences.devices):
            scene.cycles.device = 'GPU'
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.look = 'None'
    scene.view_settings.exposure = -.30
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.image_settings.color_depth = '8'
    scene.render.film_transparent = True
    # Cycles' shadow-catcher denoising can pollute empty alpha pixels. Denoise
    # RGB independently and preserve the original coverage pass, as Sprout does.
    compositor = bpy.data.node_groups.new('Clean sprite alpha', 'CompositorNodeTree')
    scene.compositing_node_group = compositor
    scene.render.use_compositing = True
    compositor.interface.new_socket(name='Image', in_out='OUTPUT', socket_type='NodeSocketColor')
    layers = compositor.nodes.new('CompositorNodeRLayers')
    denoise = compositor.nodes.new('CompositorNodeDenoise')
    denoise.inputs['HDR'].default_value = True
    alpha = compositor.nodes.new('CompositorNodeSetAlpha')
    alpha.inputs['Type'].default_value = 'Replace Alpha'
    output = compositor.nodes.new('NodeGroupOutput')
    for source, dest in (('Image', 'Image'), ('Denoising Normal', 'Normal'), ('Denoising Albedo', 'Albedo')):
        compositor.links.new(layers.outputs[source], denoise.inputs[dest])
    compositor.links.new(denoise.outputs['Image'], alpha.inputs['Image'])
    compositor.links.new(layers.outputs['Alpha'], alpha.inputs['Alpha'])
    compositor.links.new(alpha.outputs['Image'], output.inputs['Image'])
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.frame_start, scene.frame_end = 1, COUNT
    scene.render.filepath = '//runtime/'
    scene['candidate'] = character.candidate
    scene['proof_status'] = 'Prototype for likeness and movement review; not the shipping pet or a complete action library.'
    scene['review_canvas_points'] = REVIEW_POINTS
    bpy.context.view_layer.update()
    return cameras


def contact_shadow(character):
    """Small, feathered Cycles catcher carried by the world-travel control."""
    bucket = collection('Contact shadow · bounded transparent catcher')
    mat = bpy.data.materials.new('Contact shadow · feathered boundary')
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    tint = nodes.new('ShaderNodeAttribute')
    tint.attribute_name = 'CatchWeight'
    transparent = nodes.new('ShaderNodeBsdfTransparent')
    diffuse = nodes.new('ShaderNodeBsdfDiffuse')
    diffuse.inputs['Color'].default_value = (.6, .6, .6, 1)
    mix = nodes.new('ShaderNodeMixShader')
    output = nodes.new('ShaderNodeOutputMaterial')
    links.new(tint.outputs['Fac'], mix.inputs[0])
    links.new(transparent.outputs[0], mix.inputs[1])
    links.new(diffuse.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs['Surface'])
    vertices, faces, weights = [], [], []
    for radius, opacity in ((0.001, 1.), (.48, 1.), (.72, .75), (1., 0.)):
        for i in range(64):
            angle = 2 * math.pi * i / 64
            vertices.append((radius * math.cos(angle) * (.85 if character.mouse else .94),
                             radius * math.sin(angle) * (1.08 if character.mouse else .70) + (.26 if character.mouse else 0), 0))
            weights.extend((opacity, opacity, opacity, 1))
    for row in range(3):
        for i in range(64):
            j = (i + 1) % 64
            faces.append((row * 64 + i, row * 64 + j, (row + 1) * 64 + j, (row + 1) * 64 + i))
    obj = mesh_object('Contact shadow', vertices, faces, bucket, mat)
    colors = obj.data.color_attributes.new(name='CatchWeight', type='FLOAT_COLOR', domain='POINT')
    colors.data.foreach_set('color', array('f', weights))
    obj.is_shadow_catcher = True
    obj.vertex_groups.new(name='Root').add(list(range(len(vertices))), 1, 'REPLACE')
    modifier = obj.modifiers.new('Follow travel, keep ground contact', 'ARMATURE')
    modifier.object = character.rig


def render(path, resolution):
    path.parent.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.resolution_x = scene.render.resolution_y = resolution
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def build(args):
    if not bpy.app.background or '--factory-startup' not in sys.argv:
        raise RuntimeError('Use an isolated --background --factory-startup Blender process.')
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    candidate = args.candidate
    character = Character(candidate)
    character.build()
    cameras = stage(character, args)
    contact_shadow(character)
    scene, rig = bpy.context.scene, character.rig
    runtime_camera = cameras['hero']
    axis = runtime_camera.matrix_world.to_3x3() @ Vector((1, 0, 0))
    axis.z = 0
    axis.normalize()
    output = Path(args.output).resolve() / candidate
    review = Path(args.review).resolve() / candidate
    runtime = output / 'runtime'
    output.mkdir(parents=True, exist_ok=True)
    bpy.context.view_layer.update()
    actions, contact_clips = {}, {}
    for clip, direction in (('walkRight', 1), ('walkLeft', -1)):
        action = new_action(rig, NAMES[candidate] + ' · ' + ('dash' if character.mouse else 'hop') + (' right' if direction == 1 else ' left'))
        action['clip_id'], action['duration_seconds'] = clip, COUNT / FPS
        frames = []
        for index in range(COUNT):
            scene.frame_set(index + 1)
            matrices, contacts, shift, blink = motion(character, index, axis, direction)
            apply_pose(rig, matrices)
            for bone in rig.pose.bones:
                if bone.name != 'Stage':
                    for channel in ('location', 'rotation_quaternion', 'scale'):
                        bone.keyframe_insert(channel, frame=index + 1, group=bone.name)
            frames.append({'index': index, 'rootWorld': list(shift), 'feet': contacts})
            if clip == 'walkRight':
                for eye in character.eyes:
                    key = eye.data.shape_keys.key_blocks['Blink']
                    key.value = blink
                    key.keyframe_insert('value', frame=index + 1)
        linear_keys(action)
        actions[clip], contact_clips[clip] = action, frames
    for eye in character.eyes:
        action = eye.data.shape_keys.animation_data.action
        action.name = eye.name + ' · anticipation and landing blink'
        linear_keys(action)
    for frame, name in ((1, 'Ready'), (4, 'Anticipation'), (8, 'Launch'), (15, 'Landing'), (18, 'Squash'), (24, 'Settle')):
        scene.timeline_markers.new(name, frame=frame)

    def select(clip, index, compensate=False):
        rig.animation_data.action = actions[clip]
        rig.animation_data.action_slot = actions[clip].slots[0]
        rig.pose.bones['Stage'].matrix_basis = Matrix.Identity(4)
        scene.frame_set(index + 1)
        if compensate:
            shift = Vector(contact_clips[clip][index]['rootWorld'])
            bone = rig.pose.bones['Stage']
            bone.matrix_basis = bone.bone.matrix_local.inverted() @ translation(-shift) @ bone.bone.matrix_local
        bpy.context.view_layer.update()

    select('walkRight', 0)
    # A separate inspection Action lets Space play the editable pose without
    # leaving the close camera. The two export Actions retain true world travel.
    inspection = new_action(rig, NAMES[candidate] + ' · IN-PLACE INSPECTION')
    for index in range(COUNT):
        scene.frame_set(index + 1)
        matrices, _, shift, _ = motion(character, index, axis)
        for name in matrices:
            if name != 'Stage':
                matrices[name] = translation(-shift) @ matrices[name]
        apply_pose(rig, matrices)
        for bone in rig.pose.bones:
            if bone.name != 'Stage':
                for channel in ('location', 'rotation_quaternion', 'scale'):
                    bone.keyframe_insert(channel, frame=index + 1, group=bone.name)
    linear_keys(inspection)
    scene.frame_set(1)
    bpy.context.view_layer.update()
    scene.render.resolution_x = scene.render.resolution_y = PIXELS
    for screen in bpy.data.screens:
        for region in screen.areas:
            if region.type == 'VIEW_3D':
                region.spaces.active.region_3d.view_perspective = 'CAMERA'
    bpy.ops.object.select_all(action='DESELECT')
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    scene.render.filepath = '//runtime/'
    bpy.ops.wm.save_as_mainfile(filepath=str(output / (candidate + '.blend')), compress=True)
    select('walkRight', 0)

    if args.mode in ('preview', 'all'):
        for name in args.views.split(','):
            scene.camera = cameras[name]
            render(review / (name + '.png'), args.resolution)
        scene.camera = runtime_camera
        clay = material('Review · neutral clay', linear('B7B6AE'), .83)
        originals = [(obj, tuple(obj.data.materials)) for obj, bone in character.parts if not obj.name.startswith(('Eye.', 'Brow.', 'Smile.', 'Nose'))]
        for obj, _ in originals:
            obj.data.materials.clear()
            obj.data.materials.append(clay)
        render(review / 'clay.png', args.resolution)
        for obj, mats in originals:
            obj.data.materials.clear()
            for mat in mats:
                obj.data.materials.append(mat)
        for index, label in ((4, 'anticipation'), (9, 'airborne'), (17, 'landing')):
            select('walkRight', index, True)
            render(review / (label + '.png'), args.resolution)
        select('walkRight', 0)

    if args.mode in ('export', 'all'):
        scene.camera = runtime_camera
        select('walkRight', 0)
        render(runtime / 'rest.png', PIXELS)
        manifests = {}
        for clip in ('walkRight', 'walkLeft'):
            frames = []
            for index in range(COUNT):
                select(clip, index, True)
                # Measure the evaluated authored rig, not only its motion
                # function, so missed keys/parent transforms cannot self-certify.
                shift = Vector(contact_clips[clip][index]['rootWorld'])
                for name, center in character.feet.items():
                    bone = rig.pose.bones[name]
                    marker = (bone.matrix @ bone.bone.matrix_local.inverted()) @ Vector((center.x, center.y, 0))
                    contact_clips[clip][index]['feet'][name]['evaluatedWorld'] = list(marker + shift)
                    p = world_to_camera_view(scene, runtime_camera, marker)
                    contact_clips[clip][index]['feet'][name]['canvasPixels'] = [p.x * PIXELS, p.y * PIXELS]
                file = f'clips/{clip}/{index:04d}.png'
                render(runtime / file, PIXELS)
                root = Vector(contact_clips[clip][index]['rootWorld'])
                frames.append({'file': file, 'rootOffsetPoints': {'x': root.dot(axis) * POINTS / runtime_camera.data.ortho_scale, 'y': 0.}})
            manifests[clip] = {'frames': frames}
        # The review invokes only locomotion. Static aliases satisfy the current
        # app manifest contract, and are explicitly not additional animations.
        for clip in ('idle', 'pet', 'settle'):
            manifests[clip] = {'frames': [{'file': 'rest.png', 'rootOffsetPoints': {'x': 0., 'y': 0.}}]}
        ground = world_to_camera_view(scene, runtime_camera, Vector((0, 0, 0)))
        manifest = {'schemaVersion': 1, 'canvasPixels': {'width': PIXELS, 'height': PIXELS},
                    'displaySizePoints': {'width': POINTS, 'height': POINTS}, 'framesPerSecond': FPS,
                    'groundAnchorPixels': {'x': ground.x * PIXELS, 'y': ground.y * PIXELS},
                    'restFrame': 'rest.png', 'sleepFrame': 'rest.png', 'clips': manifests}
        json_file(runtime / 'manifest.json', manifest)
        json_file(output / 'motion.json', {'schemaVersion': 1, 'framesPerSecond': FPS, 'worldGroundZ': 0.,
                  'sourceCanvasPoints': POINTS, 'reviewCanvasPoints': REVIEW_POINTS,
                  'cameraScale': runtime_camera.data.ortho_scale, 'travelAxis': list(axis), 'clips': contact_clips})
    select('walkRight', 0)
    evidence = {'candidate': candidate, 'blenderVersion': bpy.app.version_string,
                'meshObjects': len(character.parts), 'controlBones': len(character.specs),
                'vertices': sum(len(obj.data.vertices) for obj, _ in character.parts),
                'framesPerClip': COUNT, 'framesPerSecond': FPS, 'reviewCanvasPoints': REVIEW_POINTS,
                'runtimeCameraScale': runtime_camera.data.ortho_scale,
                'travelAtReviewSizePoints': TRAVEL[candidate] * REVIEW_POINTS / runtime_camera.data.ortho_scale,
                'externalTextures': 0, 'hairObjects': 0,
                'builderSHA256': BUILDER_SHA256,
                'samples': args.samples, 'renderDevice': scene.cycles.device,
                'helperSHA256': {name: hashlib.sha256((ROOT / 'art/sprout/scripts' / name).read_bytes()).hexdigest()
                                 for name in ('build_design.py', 'sample_motion.py')}}
    json_file(output / 'build.json', evidence)
    print('CANDIDATE_BUILD ' + json.dumps(evidence), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', choices=NAMES, required=True)
    parser.add_argument('--output', default=str(ROOT / 'art/candidates/proof-v01'))
    parser.add_argument('--review', default=str(ROOT / '.build/candidate-review'))
    parser.add_argument('--mode', choices=('preview', 'export', 'all'), default='all')
    parser.add_argument('--views', default='hero,front,side,back')
    parser.add_argument('--resolution', type=int, default=768)
    parser.add_argument('--samples', type=int, default=32)
    parser.add_argument('--camera-scale', type=float, help='Optional fixed orthographic framing override')
    parser.add_argument('--device', choices=('CPU', 'METAL'), default='METAL')
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    build(parser.parse_args(args))

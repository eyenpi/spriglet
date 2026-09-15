"""Editable Acorn Hopper / Moss Mouse, built in a disposable Blender 5.2.

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
COUNTS = {'idle': 42, 'walkRight': COUNT, 'walkLeft': COUNT, 'pet': 30, 'settle': 18,
          'fallAsleep': 30, 'wakeUp': 24, 'sleep': 1}
BOUNDARIES = {'idle': ('ready', 'ready'), 'walkRight': ('ready', 'ready'),
              'walkLeft': ('ready', 'ready'), 'pet': ('ready', 'happy'),
              'settle': ('happy', 'ready'), 'fallAsleep': ('ready', 'asleep'),
              'wakeUp': ('asleep', 'ready'), 'sleep': ('asleep', 'asleep')}
NAMES = {"acorn-hopper": "Acorn Hopper", "moss-mouse": "Moss Mouse"}
TRAVEL = {'acorn-hopper': 3.2, 'moss-mouse': 3.0}
GREEN, CREAM, LEAF, BLUSH = map(linear, ("90995B", "F8E5BF", "768C48", "E6A18D"))


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
    return blend(color, BLUSH, blush * mask * .77)


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
        self.parts, self.specs, self.feet, self.expressions = [], [], {}, []
        self.body_pivot = Vector((0, 0, .11))
        self.head_pivot = Vector((0, -.28, .57)) if self.mouse else self.body_pivot
        self.coat = material("Moss and cream · soft velvet vertex paint", GREEN, .84, .24, attribute=True)
        self.green = material("Moss · soft velvet", GREEN, .84, .24)
        self.leaf_mat = material("Leaves · folded satin", LEAF, .65, .13)
        self.vein_mat = material("Leaves · quiet midrib", linear('94A65D'), .72, .08)
        self.ink = material("Face · warm dark brown", linear("382D21"), .56)
        self.eye_mat = material("Eyes · dark glass", linear("211B15"), .20)
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

    def foliage(self, name, base, tip, width, bone, thickness=.07):
        # A closed, softly folded volume, not an infinitely thin leaf plane.
        obj = leaf(name, base, tip, width, thickness, self.bucket, self.leaf_mat, LEAF, bend=.095)
        self.part(obj, bone)
        a, b = Vector(base), Vector(tip)
        # The midrib is deliberately subtle: silhouette carries at desktop size.
        points = [a.lerp(b, t) + Vector((0, -thickness * math.sin(math.pi * t), .035 * math.sin(math.pi * t)))
                  for t in (.10, .40, .72, .91)]
        self.curve(name + " · midrib", points, .007, self.vein_mat, bone)

    def cap(self, mat):
        """One editable domed shell with shallow staggered scallop relief.

        Relief is actual geometry and survives material overrides. No generated
        texture, displacement dependency or hundreds of separate scale objects.
        """
        segments, rows = 128, 48
        vertices, faces = [], []
        for row in range(rows + 1):
            t = row / rows
            angle = t * math.pi / 2
            radius = .738 * math.cos(angle)
            for j in range(segments):
                theta = 2 * math.pi * j / segments
                band = t * 4.2
                phase = theta * 24 + math.floor(band) * math.pi
                scallop = math.sin(math.pi * (band % 1)) ** 2 * (.5 + .5 * math.cos(phase)) ** 2
                relief = .010 * scallop * math.sin(math.pi * t) ** .55
                r = radius + relief * math.cos(angle)
                vertices.append((r * math.cos(theta), r * .80 * math.sin(theta),
                                 1.305 + .425 * math.sin(angle) + relief * math.sin(angle)))
        for row in range(rows):
            for j in range(segments):
                k = (j + 1) % segments
                faces.append((row * segments + j, row * segments + k,
                              (row + 1) * segments + k, (row + 1) * segments + j))
        faces.append(tuple(reversed(range(segments))))
        obj = self.part(mesh_object('Cap · scalloped single shell', vertices, faces, self.bucket, mat), 'Cap')
        subdivide(obj, 1)
        # Rounded rolled edge makes the cap read as an acorn cup, not a helmet.
        rim = [(math.cos(t * 2 * math.pi / 64) * .730, math.sin(t * 2 * math.pi / 64) * .584, 1.305)
               for t in range(65)]
        self.curve('Cap · rolled lip', rim, .025, mat, 'Cap')

    def face(self, surface):
        mouse = self.mouse
        control = 'Head' if mouse else 'Body'
        eye_x, eye_z = (.205, .62) if mouse else (.235, .95)
        for side, label in ((-1, 'L'), (1, 'R')):
            pos = face_point(surface, side * eye_x, eye_z, .008)
            radius = (.111, .064, .123) if mouse else (.120, .066, .131)
            eye = self.ball("Eye." + label, pos, radius, self.eye_mat, control)
            eye.shape_key_add(name='Basis')
            blink = eye.shape_key_add(name='Blink')
            for v in blink.data:
                depth = v.co.y - pos.y
                v.co.z = pos.z + (v.co.z - pos.z) * .10
                v.co.y = face_point(surface, v.co.x, v.co.z, .032).y + depth * .12
            happy = eye.shape_key_add(name='Happy')
            for v in happy.data:
                dx, dz = v.co.x - pos.x, v.co.z - pos.z
                depth = v.co.y - pos.y
                v.co.z = pos.z + .041 * (1 - (dx / radius[0]) ** 2) + dz * .13
                v.co.y = face_point(surface, v.co.x, v.co.z, .032).y + depth * .12
            self.expressions.append(eye)
            brow_z = eye_z + (.186 if mouse else .220)
            points = [face_point(surface, side * x, z, .014) for x, z in (
                (eye_x - .042, brow_z - .009), (eye_x, brow_z + .009),
                (eye_x + .046, brow_z - .011))]
            self.curve('Brow.' + label, points, .007, self.ink, control)
            # A matte crease keeps a closed eye legible at 96 points. It lives
            # inside the face when open; the same two shape controls reveal it.
            closed = [face_point(surface, side * eye_x + dx,
                                 eye_z + .041 * (1 - (dx / radius[0]) ** 2), .038)
                      for dx in (-radius[0] * .86, 0., radius[0] * .86)]
            lid = self.curve('Eye.Lid.' + label, closed, .0105, self.ink, control)
            visible = [v.co.copy() for v in lid.data.vertices]
            basis = lid.shape_key_add(name='Basis')
            for v in basis.data:
                v.co.y += .12
            happy_lid = lid.shape_key_add(name='Happy', from_mix=False)
            blink_lid = lid.shape_key_add(name='Blink', from_mix=False)
            for i, point in enumerate(visible):
                happy_lid.data[i].co = point
                dx = point.x - side * eye_x
                straight = point.copy()
                straight.z -= .041 * (1 - (dx / radius[0]) ** 2)
                straight.y = face_point(surface, straight.x, straight.z, .038).y
                blink_lid.data[i].co = straight
            self.expressions.append(lid)
        # Closed eyes should read as dark soft arcs, not reflective little lids.
        # One shared material follows the synchronized eye expression controls.
        shader = self.eye_mat.node_tree.nodes.get('Principled BSDF')
        for socket, expression in (('Roughness', '.20 + .65 * max(blink, happy)'),
                                   ('Specular IOR Level', '.40 * (1 - max(blink, happy))')):
            driver = shader.inputs[socket].driver_add('default_value').driver
            for variable_name, key_name in (('blink', 'Blink'), ('happy', 'Happy')):
                variable = driver.variables.new()
                variable.name = variable_name
                variable.type = 'SINGLE_PROP'
                variable.targets[0].id_type = 'KEY'
                variable.targets[0].id = self.expressions[0].data.shape_keys
                variable.targets[0].data_path = f'key_blocks["{key_name}"].value'
            driver.expression = expression
        nose_z = .501 if mouse else .804
        pos = face_point(surface, 0, nose_z, .017)
        self.ball('Nose', pos, (.035, .029, .023), self.ink, control)
        self.curve('Nose philtrum', [face_point(surface, 0, z, .013) for z in (nose_z - .018, nose_z - .061)], .009, self.ink, control)
        for side in (-1, 1):
            points = [face_point(surface, side * x, z, .013) for x, z in (
                (0, nose_z - .059), (.039, nose_z - .081), (.077, nose_z - .055))]
            smile = self.curve('Smile.' + str(side), points, .011, self.ink, control)
            smile.shape_key_add(name='Basis')
            happy = smile.shape_key_add(name='Happy')
            for v in happy.data:
                v.co.z += .036 * min(1, abs(v.co.x) / .077) ** 2
            self.expressions.append(smile)

    def build(self):
        if self.mouse:
            self.ball('Body · low bean', (0, .30, .43), (.51, .73, .37), self.coat, 'Body',
                      lambda p: blend(GREEN, CREAM, (1 - smoothstep(.23, .36, p.z)) * .96))
            head = self.ball('Head · round cheeks', (0, -.40, .535), (.59, .49, .465), self.coat, 'Head',
                             lambda p: face_color(p, True))
            for side, label in ((-1, 'L'), (1, 'R')):
                base = (side * .28, -.31, .89)
                tip = (side * (.55 if side < 0 else .68), -.26 if side < 0 else -.37, 1.55 if side < 0 else 1.35)
                self.spec('Ear.' + label, base, 'Head')
                self.foliage('Leaf ear.' + label, base, tip, .226, 'Ear.' + label, .098)
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
            cap_mat = material('Cap · warm chestnut', linear('A47449'), .80, .12)
            self.spec('Cap', (0, 0, 1.30), 'Body')
            self.cap(cap_mat)
            self.curve('Stem', [(0, .015, 1.68), (-.018, .018, 1.84), (-.088, .018, 1.94)], .050, cap_mat, 'Cap')
            self.spec('Leaf', (.01, .02, 1.80), 'Cap')
            self.foliage('Off-center leaf', (.01, .02, 1.80), (.61, -.02, 2.06), .232, 'Leaf', .083)
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
        # Expressions belong to the same Action as the body. Changing an Action
        # in Blender automatically changes every eye/lid/smile and its material.
        for name in ('Blink', 'Happy'):
            self.rig[name] = 0.
            self.rig.id_properties_ui(name).update(min=0., max=1., description=name + ' facial expression')
        for obj in self.expressions:
            for key in list(obj.data.shape_keys.key_blocks)[1:]:
                driver = key.driver_add('value').driver
                variable = driver.variables.new()
                variable.name = 'expression'
                variable.type = 'SINGLE_PROP'
                variable.targets[0].id = self.rig
                variable.targets[0].data_path = f'["{key.name}"]'
                driver.expression = 'expression'

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
        rig['notes'] = 'Finite idle, dash/hop, pet, settle and sleep Actions. Stage cancels travel only for sprite export. Blink and Happy shape keys stay editable.'
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
        yaw = heading * smooth((index - 4) / 4) * (1 - smooth((index - 13) / 3))
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
            delay = .65 if name.endswith('.R') else 0
            flutter = math.sin((index - 5) * .62 - delay) * envelope
            deform = head @ around(pivot, rotation('X', .23 * envelope + .16 * flutter)
                                   @ rotation('Y', .07 * flutter))
        elif name == 'Tail':
            deform = body @ around(pivot, rotation('X', -.25 * envelope) @ rotation('Z', .14 * amount))
        elif name == 'Cap':
            deform = body @ around(pivot, Matrix.Rotation(-direction * .11 * amount, 4, lean_axis))
        elif name == 'Leaf':
            lag = math.sin((index - 6) * .56) * envelope
            deform = deforms['Cap'] @ around(pivot, rotation('Y', -.29 * lag))
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
    return matrices, contacts, shift, {'Blink': blink, 'Happy': 0.}


def stationary_motion(character, clip, index):
    """Distinct personalities, with matched pet/settle endpoints and fixed feet.

    Quiet means a static image after a finite gesture; these are not perpetual
    idle loops. Sleep is an intentionally authored held pose, not a rest alias.
    """
    mouse = character.mouse
    t = index / max(1, COUNTS[clip] - 1)
    affection = 0.
    flourish = glance = blink = sleeping = stretch = nod = 0.
    breath = math.sin(math.pi * t) ** 2
    if clip == 'idle':
        glance = pulse(index, 3, 14, 36)
        blink = pulse(index, 21, 23, 26)
    elif clip == 'pet':
        affection = smooth(t / .30)
        flourish = math.sin(4 * math.pi * t) * math.sin(math.pi * t) ** 2
    elif clip == 'settle':
        affection = 1 - smooth(t)
    elif clip == 'sleep':
        sleeping, blink = 1., 1.
    elif clip == 'fallAsleep':
        # A failed attempt to stay awake, then the cap/ears gently fold down.
        sleeping = smooth((index - 6) / 23)
        blink = max(.72 * pulse(index, 1, 5, 9), smooth((index - 9) / 13))
        nod = pulse(index, 2, 7, 14)
    elif clip == 'wakeUp':
        # Begin at the exact held sleep pose. Open the eyes, stretch, then
        # recover to the shared ready pose without moving the planted feet.
        sleeping = 1 - smooth((index - 2) / 18)
        blink = max(1 - smooth((index - 4) / 7), .7 * pulse(index, 16, 18, 21))
        stretch = pulse(index, 5, 12, 21)
        flourish = .22 * math.sin(index * .7) * pulse(index, 8, 15, 23)
    squash = .042 * affection + .115 * sleeping - .09 * stretch + (.012 * breath if clip == 'idle' else 0.)
    body_roll = (-.028 if mouse else -.055) * affection + (.025 if mouse else .075) * flourish
    body_roll += (.012 if mouse else .052) * glance + (.018 if mouse else .045) * nod
    scale = Matrix.Diagonal((1 + squash * .38, 1 + squash * .38, 1 - squash, 1))
    body = around(character.body_pivot, rotation('Y', body_roll) @ scale)
    deforms = {'Stage': Matrix.Identity(4), 'Root': Matrix.Identity(4), 'Body': body}
    if mouse:
        head = body @ around(character.head_pivot,
                            rotation('Y', -.115 * affection + .10 * glance + .09 * sleeping)
                            @ rotation('Z', -.105 * glance)
                            @ rotation('X', -.07 * affection + .12 * sleeping + .075 * nod - .045 * stretch))
        deforms['Head'] = head
    else:
        head = body
    for name, pivot, parent in character.specs:
        if name in deforms or name in character.feet:
            continue
        side = -1 if name.endswith('.L') else 1
        if name.startswith('Ear'):
            twitch = .16 * pulse(index, 7 if side < 0 else 11, 9 if side < 0 else 14, 14 if side < 0 else 20) if clip == 'idle' else 0.
            if clip == 'wakeUp':
                twitch = -.16 * pulse(index, 9 if side < 0 else 12, 13 if side < 0 else 16, 21 if side < 0 else 23)
            deform = head @ around(pivot, rotation('X', .20 * affection + .08 * side * flourish + .45 * sleeping + twitch)
                                   @ rotation('Y', side * (.10 * affection + .44 * sleeping)))
        elif name == 'Tail':
            deform = body @ around(pivot, rotation('Z', .32 * flourish + .10 * glance)
                                   @ rotation('X', .12 * affection - .43 * sleeping))
        elif name == 'Cap':
            deform = body @ around(pivot, rotation('X', .035 * affection + .15 * sleeping + .055 * nod - .045 * stretch)
                                   @ rotation('Y', -.065 * flourish - .025 * glance))
        elif name == 'Leaf':
            deform = deforms['Cap'] @ around(pivot, rotation('Y', -.12 * affection + .16 * flourish - .18 * sleeping + .10 * glance))
        else:
            deform = body @ around(pivot, rotation('Y', -side * (1.12 * affection + .32 * flourish - .14 * sleeping))
                                   @ rotation('X', -.18 * affection))
        deforms[name] = deform
    contacts = {}
    for name, center in character.feet.items():
        deforms[name] = Matrix.Identity(4)
        contacts[name] = {'planted': True, 'world': [center.x, center.y, 0.]}
    matrices = {name: deform @ character.rig.data.bones[name].matrix_local for name, deform in deforms.items()}
    return matrices, contacts, Vector((0, 0, 0)), {'Blink': blink, 'Happy': affection}


def evaluate(character, clip, index, axis):
    if clip.startswith('walk'):
        return motion(character, index, axis, 1 if clip == 'walkRight' else -1)
    return stationary_motion(character, clip, index)


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
    scale = args.camera_scale or (2.86 if character.mouse else 3.00)
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
    scene['proof_status'] = 'Refinement v02: real idle, locomotion, pet, settle and sleeping pose. Review-only; shipping pet unchanged.'
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
    for clip, count in COUNTS.items():
        action = new_action(rig, NAMES[candidate] + ' · ' + clip)
        action['clip_id'], action['duration_seconds'] = clip, count / FPS
        action['starts_at'], action['ends_at'] = BOUNDARIES[clip]
        frames = []
        for index in range(count):
            scene.frame_set(index + 1)
            matrices, contacts, shift, expression = evaluate(character, clip, index, axis)
            apply_pose(rig, matrices)
            for bone in rig.pose.bones:
                if bone.name != 'Stage':
                    for channel in ('location', 'rotation_quaternion', 'scale'):
                        bone.keyframe_insert(channel, frame=index + 1, group=bone.name)
            frame = {'index': index, 'rootWorld': list(shift), 'feet': contacts, 'expression': expression}
            if index in (0, count - 1):
                frame['inPlacePose'] = {name: [value for row in (translation(-shift) @ matrix) for value in row]
                                        for name, matrix in matrices.items() if name != 'Stage'}
            frames.append(frame)
            for name, value in expression.items():
                # Clamp endpoints may be Python ints. Keep a float property so
                # Blender does not flag this F-curve as discrete/rounded.
                rig[name] = float(value)
                rig.keyframe_insert(data_path=f'["{name}"]', frame=index + 1, group='Face')
        linear_keys(action)
        actions[clip], contact_clips[clip] = action, frames
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

    # Verify fractional expressions before paying for any renders. A custom
    # property's accidental integer F-curve would otherwise make blinks snap.
    for clip, samples in contact_clips.items():
        for index, sample in enumerate(samples):
            select(clip, index, True)
            for obj in character.expressions:
                for key in list(obj.data.shape_keys.key_blocks)[1:]:
                    if abs(key.value - sample['expression'][key.name]) > 1e-5:
                        raise RuntimeError(f'Facial preflight failed: {clip}/{index} {obj.name}/{key.name}')

    # Every entrance and exit must match its canonical pose AND expression.
    # This verifies the full transition graph before the expensive render pass.
    canonical = {'ready': contact_clips['idle'][0], 'happy': contact_clips['pet'][-1],
                 'asleep': contact_clips['sleep'][0]}
    for clip, states in BOUNDARIES.items():
        for index, state in zip((0, -1), states):
            sample, expected = contact_clips[clip][index], canonical[state]
            error = max(abs(a - b) for name in expected['inPlacePose']
                        for a, b in zip(sample['inPlacePose'][name], expected['inPlacePose'][name]))
            if error > 2e-5 or any(abs(sample['expression'][key] - value) > 1e-6
                                  for key, value in expected['expression'].items()):
                raise RuntimeError(f'Transition preflight failed: {clip}/{index} → {state}')

    select('walkRight', 0)
    # A separate inspection Action lets Space play the editable pose without
    # leaving the close camera. The two export Actions retain true world travel.
    inspection = new_action(rig, NAMES[candidate] + ' · IN-PLACE INSPECTION')
    for index in range(COUNT):
        scene.frame_set(index + 1)
        matrices, _, shift, expression = motion(character, index, axis)
        for name in matrices:
            if name != 'Stage':
                matrices[name] = translation(-shift) @ matrices[name]
        apply_pose(rig, matrices)
        for bone in rig.pose.bones:
            if bone.name != 'Stage':
                for channel in ('location', 'rotation_quaternion', 'scale'):
                    bone.keyframe_insert(channel, frame=index + 1, group=bone.name)
        for name, value in expression.items():
            rig[name] = float(value)
            rig.keyframe_insert(data_path=f'["{name}"]', frame=index + 1, group='Face')
    linear_keys(inspection)
    scene.frame_set(1)
    bpy.context.view_layer.update()
    scene.render.resolution_x = scene.render.resolution_y = PIXELS
    for screen in bpy.data.screens:
        for region in screen.areas:
            if region.type == 'VIEW_3D':
                region.spaces.active.region_3d.view_perspective = 'CAMERA'
                region.spaces.active.shading.type = 'MATERIAL'
                region.spaces.active.shading.use_scene_lights = True
                region.spaces.active.shading.use_scene_world = True
    bpy.ops.object.select_all(action='DESELECT')
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    scene.render.filepath = '//runtime/'
    notes = bpy.data.texts.new('START HERE · editable actions')
    notes.write('Transitions v03 · ' + NAMES[candidate] + '\n\n'
                'Space plays the default in-place 24-frame movement inspection.\n'
                'Each named Action includes its face: change only the rig Action to inspect another gesture.\n'
                'Rig custom properties Blink and Happy drive editable eye, eyelid and smile shape keys.\n'
                'Frame ranges: idle 1–42; walkRight/Left 1–24; pet 1–30; settle 1–18; fallAsleep 1–30; wakeUp 1–24; sleep 1.\n'
                'Pet ends in affection; settle begins in the identical pose and returns to rest.\n'
                'FallAsleep connects ready to the held sleep pose. WakeUp connects sleep back to ready.\n'
                'Every Action carries starts_at / ends_at state metadata; both geometry and expression endpoints match.\n'
                'Finish an airborne action before changing states. Route happy through settle and sleep through wakeUp.\n'
                'Travel Actions move in world space. Stage remains unkeyed and cancels root movement only during export.\n'
                'No external images, groom, generated mesh, or add-on dependencies.\n')
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
        for clip, index in (('idle', 14), ('pet', 15), ('sleep', 0), ('fallAsleep', 15), ('wakeUp', 12)):
            select(clip, index, True)
            render(review / (clip + '.png'), args.resolution)
        select('walkRight', 0)

    if args.mode in ('export', 'all'):
        scene.camera = runtime_camera
        select('walkRight', 0)
        render(runtime / 'rest.png', PIXELS)
        manifests = {}
        for clip, count in COUNTS.items():
            frames = []
            for index in range(count):
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
                contact_clips[clip][index]['evaluatedExpressions'] = {
                    obj.name: {key.name: key.value for key in list(obj.data.shape_keys.key_blocks)[1:]}
                    for obj in character.expressions}
                file = 'sleep.png' if clip == 'sleep' else f'clips/{clip}/{index:04d}.png'
                render(runtime / file, PIXELS)
                root = Vector(contact_clips[clip][index]['rootWorld'])
                frames.append({'file': file, 'rootOffsetPoints': {'x': root.dot(axis) * POINTS / runtime_camera.data.ortho_scale, 'y': 0.}})
            if clip != 'sleep':
                manifests[clip] = {'frames': frames}
        ground = world_to_camera_view(scene, runtime_camera, Vector((0, 0, 0)))
        manifest = {'schemaVersion': 2, 'canvasPixels': {'width': PIXELS, 'height': PIXELS},
                    'displaySizePoints': {'width': POINTS, 'height': POINTS}, 'framesPerSecond': FPS,
                    'groundAnchorPixels': {'x': ground.x * PIXELS, 'y': ground.y * PIXELS},
                    'restFrame': 'rest.png', 'sleepFrame': 'sleep.png', 'clips': manifests}
        json_file(runtime / 'manifest.json', manifest)
        json_file(output / 'motion.json', {'schemaVersion': 1, 'framesPerSecond': FPS, 'worldGroundZ': 0.,
                  'sourceCanvasPoints': POINTS, 'reviewCanvasPoints': REVIEW_POINTS,
                  'boundaries': BOUNDARIES,
                  'cameraScale': runtime_camera.data.ortho_scale, 'travelAxis': list(axis), 'clips': contact_clips})
    select('walkRight', 0)
    evidence = {'candidate': candidate, 'blenderVersion': bpy.app.version_string,
                'meshObjects': len(character.parts), 'controlBones': len(character.specs),
                'vertices': sum(len(obj.data.vertices) for obj, _ in character.parts),
                'revision': 'transitions-v03', 'framesPerClip': COUNTS, 'framesPerSecond': FPS, 'reviewCanvasPoints': REVIEW_POINTS,
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
    parser.add_argument('--output', default=str(ROOT / 'art/candidates/transitions-v03'))
    parser.add_argument('--review', default=str(ROOT / '.build/candidate-transitions'))
    parser.add_argument('--mode', choices=('preview', 'export', 'all'), default='all')
    parser.add_argument('--views', default='hero,front,side,back')
    parser.add_argument('--resolution', type=int, default=768)
    parser.add_argument('--samples', type=int, default=32)
    parser.add_argument('--camera-scale', type=float, help='Optional fixed orthographic framing override')
    parser.add_argument('--device', choices=('CPU', 'METAL'), default='METAL')
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    build(parser.parse_args(args))

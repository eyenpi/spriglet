"""Build the editable Sprout design study in an isolated Blender 5.2 process.

Run with --background --factory-startup; output defaults to .build/art/sprout.
The model is a design draft. Its geometry and groom precede the production rig.
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
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[3]
GREEN_HEX = "63662E"
CREAM_HEX = "F1DBAB"
LEAF_HEX = "536730"
VIEWS = ("hero", "front", "side", "back")


def linear(hex_color):
    values = [int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in values)


GREEN, CREAM, LEAF = map(linear, (GREEN_HEX, CREAM_HEX, LEAF_HEX))


def smoothstep(low, high, value):
    t = max(0.0, min(1.0, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)


def blend(a, b, t):
    return tuple(x * (1 - t) + y * t for x, y in zip(a, b))


def body_color(point):
    x, y, z = point
    belly = 1 - (x / .50) ** 2 - ((z - .72) / .51) ** 2
    neck = 1 - (x / .25) ** 2 - ((z - 1.14) / .20) ** 2
    eye_patches = max(1 - ((x - side * .275) / .19) ** 2 - ((z - 1.515) / .235) ** 2
                      for side in (-1, 1))
    cheeks = max(1 - ((x - side * .31) / .27) ** 2 - ((z - 1.33) / .19) ** 2
                 for side in (-1, 1))
    muzzle = 1 - (x / .29) ** 2 - ((z - 1.355) / .155) ** 2
    cream = smoothstep(-.10, .12, max(belly, neck, eye_patches, cheeks, muzzle))
    # A tapered olive brow reaches between the eye patches toward the nose.
    # This avoids a flat lower edge across the center of the forehead.
    brow_half_width = max(0, .50 * (z - 1.39))
    brow = smoothstep(-.012, .012, brow_half_width - abs(x)) * smoothstep(1.395, 1.42, z)
    cream *= 1 - brow
    cream *= smoothstep(.035, .22, -y)
    color = blend(GREEN, CREAM, cream)
    blush = math.exp(-((abs(x) - .41) / .105) ** 2 - ((z - 1.34) / .070) ** 2)
    blush *= cream * .70
    return blend(color, linear("D78065"), blush)


def collection(name, parent=None):
    result = bpy.data.collections.new(name)
    (parent or bpy.context.scene.collection).children.link(result)
    return result


def move_to(obj, destination):
    for owner in tuple(obj.users_collection):
        owner.objects.unlink(obj)
    destination.objects.link(obj)


def material(name, color, roughness=.6, sheen=0, attribute=False):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    # In Blender 5.2 new materials already have node trees. use_nodes is deprecated.
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*color, 1)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Specular IOR Level"].default_value = .28
    shader.inputs["Sheen Weight"].default_value = sheen
    shader.inputs["Sheen Roughness"].default_value = .7
    if sheen:
        shader.inputs["Subsurface Weight"].default_value = .035
        shader.inputs["Subsurface Scale"].default_value = .035
        noise = mat.node_tree.nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 155
        noise.inputs["Detail"].default_value = 2
        bump = mat.node_tree.nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = .10
        bump.inputs["Distance"].default_value = .009
        mat.node_tree.links.new(noise.outputs["Fac"], bump.inputs["Height"])
        mat.node_tree.links.new(bump.outputs["Normal"], shader.inputs["Normal"])
    if attribute:
        tint = mat.node_tree.nodes.new("ShaderNodeAttribute")
        tint.attribute_name = "CoatTint"
        mat.node_tree.links.new(tint.outputs["Color"], shader.inputs["Base Color"])
    return mat


def coat_colors(obj, color_fn):
    colors = obj.data.color_attributes.get("CoatTint")
    if colors is None:
        colors = obj.data.color_attributes.new(name="CoatTint", type="FLOAT_COLOR", domain="POINT")
    values = array("f")
    for vertex in obj.data.vertices:
        values.extend((*color_fn(obj.matrix_world @ vertex.co), 1))
    colors.data.foreach_set("color", values)


def mesh_object(name, vertices, faces, destination, mat, color_fn=None):
    mesh = bpy.data.meshes.new(name + " geometry")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    destination.objects.link(obj)
    mesh.materials.append(mat)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    if color_fn:
        coat_colors(obj, color_fn)
    return obj


def subdivide(obj, level=2):
    modifier = obj.modifiers.new("Soft surface", "SUBSURF")
    modifier.levels = level
    modifier.render_levels = level


def body(destination, mat):
    profile = [(.14, .22), (.24, .48), (.45, .69), (.76, .77),
               (1.07, .75), (1.35, .66), (1.62, .62), (1.84, .61),
               (2.04, .52), (2.20, .34), (2.27, .12)]
    segments = 64
    vertices = []
    for z, radius in profile:
        radius *= 1.07 if z < 1.35 else 1
        for i in range(segments):
            angle = 2 * math.pi * i / segments
            vertices.append((radius * math.cos(angle), radius * .79 * math.sin(angle), z * .86))
    faces = []
    for row in range(len(profile) - 1):
        for i in range(segments):
            j = (i + 1) % segments
            faces.append((row * segments + i, row * segments + j,
                          (row + 1) * segments + j, (row + 1) * segments + i))
    bottom = len(vertices)
    vertices.append((0, 0, .105 * .86))
    top = len(vertices)
    vertices.append((0, 0, 2.285 * .86))
    last = (len(profile) - 1) * segments
    for i in range(segments):
        j = (i + 1) % segments
        faces.append((bottom, j, i))
        faces.append((top, last + i, last + j))
    obj = mesh_object("Sprout body", vertices, faces, destination, mat)
    subdivide(obj)
    # Paint the actual smooth surface so sparse construction rings do not blur
    # the eye patches into a rectangular bib. This remains an editable mesh.
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=obj.modifiers[0].name)
    for vertex in obj.data.vertices:
        x, y, z = vertex.co
        fullness = math.exp(-((abs(x) - .27) / .245) ** 2 - ((z - 1.335) / .205) ** 2)
        vertex.co.y -= .065 * fullness * smoothstep(.10, .36, -y)
    obj.data.update()
    coat_colors(obj, body_color)
    return obj


def ellipsoid(name, center, scale, destination, mat, color=None, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=32, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.rotation_euler = rotation
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    move_to(obj, destination)
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    if color is not None:
        coat_colors(obj, lambda _: color)
    return obj


def leaf(name, base, tip, width, thickness, destination, mat, color, bend=.035):
    base, tip = Vector(base), Vector(tip)
    direction = (tip - base).normalized()
    across = direction.cross(Vector((0, 1, 0))).normalized()
    depth = direction.cross(across).normalized()
    rings, segments = 18, 24
    vertices = []
    for row in range(rings + 1):
        t = (row + .02) / (rings + .04)
        bulge = math.sin(math.pi * t) ** .60
        center = base.lerp(tip, t) + depth * bend * math.sin(math.pi * t)
        for i in range(segments):
            angle = 2 * math.pi * i / segments
            point = center + across * (width * bulge * math.cos(angle))
            point += depth * (thickness * bulge * math.sin(angle))
            vertices.append(tuple(point))
    faces = []
    for row in range(rings):
        for i in range(segments):
            j = (i + 1) % segments
            faces.append((row * segments + i, row * segments + j,
                          (row + 1) * segments + j, (row + 1) * segments + i))
    bottom, top = len(vertices), len(vertices) + 1
    vertices.extend((tuple(base), tuple(tip)))
    for i in range(segments):
        j = (i + 1) % segments
        faces.extend(((bottom, j, i), (top, rings * segments + i, rings * segments + j)))
    obj = mesh_object(name, vertices, faces, destination, mat, lambda _: color)
    subdivide(obj, 1)
    return obj


def line(name, points, radius, destination, mat):
    data = bpy.data.curves.new(name, type="CURVE")
    data.dimensions = "3D"
    data.resolution_u = 16
    data.bevel_depth = radius
    data.bevel_resolution = 3
    spline = data.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for point, position in zip(spline.bezier_points, points):
        point.co = position
        point.handle_left_type = "AUTO"
        point.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, data)
    destination.objects.link(obj)
    data.materials.append(mat)
    return obj


def face_point(surface, x, z, offset=0):
    """Place a feature on the identity-transform body's evaluated front."""
    evaluated = surface.evaluated_get(bpy.context.evaluated_depsgraph_get())
    hit, location, normal, _ = evaluated.ray_cast(Vector((x, -3, z)), Vector((0, 1, 0)))
    if not hit:
        raise RuntimeError(f"Face placement missed the body at x={x}, z={z}.")
    return location + normal * offset


def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def camera(name, location, destination, target=(0, 0, 1.26), scale=3.2):
    data = bpy.data.cameras.new(name)
    data.type = "ORTHO"
    data.ortho_scale = scale
    obj = bpy.data.objects.new(name, data)
    destination.objects.link(obj)
    obj.location = location
    aim(obj, target)
    return obj


def area(name, location, energy, size, destination, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.shape, data.size, data.color = energy, "DISK", size, color
    obj = bpy.data.objects.new(name, data)
    destination.objects.link(obj)
    obj.location = location
    aim(obj, (0, 0, 1.3))


def build(args):
    if not bpy.app.background or "--factory-startup" not in sys.argv:
        raise RuntimeError("Run in a new Blender process with --background --factory-startup.")
    if bpy.app.version[:2] != (5, 2):
        raise RuntimeError("This draft is verified with Blender 5.2; review the API before another version.")
    requested_views = args.views.split(",")
    if not requested_views or any(name not in VIEWS for name in requested_views):
        raise ValueError(f"Views must be a comma-separated selection from {VIEWS}.")
    if not 64 <= args.resolution <= 4096 or not 1 <= args.samples <= 1024:
        raise ValueError("Resolution must be 64–4096 pixels and samples must be 1–1024.")
    if not math.isfinite(args.fur_density) or not 0 < args.fur_density <= 50000:
        raise ValueError("Fur density must be finite, greater than zero, and at most 50000.")
    sources = [Path(__file__), Path(__file__).with_name("coat_fibers.py")]
    source_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in sources}
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for existing in tuple(bpy.data.collections):
        bpy.data.collections.remove(existing)

    character = collection("SPROUT · editable design")
    anatomy = collection("01 · Body and limbs", character)
    foliage = collection("02 · Leaf ears and crown", character)
    face = collection("03 · Face", character)
    studio = collection("STUDIO · design review")
    groom = collection("04 · Short velvet groom", character)

    coat = material("Coat · moss and cream", GREEN, .69, .10, attribute=True)
    ink = material("Face · warm ink", linear("2C2117"), .42)
    eye_mat = material("Eyes · soft dark gloss", linear("221C12"), .24)
    eye_mat.node_tree.nodes.get("Principled BSDF").inputs["Specular IOR Level"].default_value = .26

    surfaces = [(body(anatomy, coat), body_color, 1.0)]
    for side in (-1, 1):
        label = "Left" if side < 0 else "Right"
        foot = ellipsoid(label + " foot", (side * .29, -.24, .105), (.18, .235, .105), anatomy, coat, LEAF)
        arm = ellipsoid(label + " paw", (side * .54, -.46, 1.005), (.18, .18, .21),
                        anatomy, coat, GREEN, rotation=(.18, side * -.58, side * -.30))
        surfaces.extend(((foot, lambda _, c=LEAF: c, .32), (arm, lambda _, c=GREEN: c, .55)))
        ear = leaf(label + " leaf ear", (side * .32, .015, 1.84),
                   (side * (.60 if side > 0 else .50), .035, 2.43 if side < 0 else 2.34),
                   .195, .125, foliage, coat, GREEN)
        surfaces.append((ear, lambda _, c=GREEN: c, .5))

    tail = ellipsoid("Rounded tail", (.14, .62, .43), (.245, .23, .245), anatomy, coat, GREEN,
                     rotation=(.15, .1, 0))
    surfaces.append((tail, lambda _, c=GREEN: c, .65))
    crowns = [((-.015, -.10, 1.95), (-.075, -.085, 2.23), .060),
              ((.005, -.095, 1.95), (.14, -.075, 2.17), .058),
              ((-.025, -.07, 1.95), (-.17, -.035, 2.12), .052)]
    for i, (base, tip, width) in enumerate(crowns, 1):
        sprout = leaf(f"Crown leaf {i}", base, tip, width, .032, foliage, coat,
                      blend(LEAF, GREEN, .55), bend=.015)
        surfaces.append((sprout, lambda _, c=blend(LEAF, GREEN, .55): c, .16))

    bpy.context.view_layer.update()
    face_surface = surfaces[0][0]
    for side in (-1, 1):
        position = face_point(face_surface, side * .25, 1.52)
        position.y -= .010
        eye = ellipsoid(("Left" if side < 0 else "Right") + " eye", position,
                        (.112, .061, .127), face, eye_mat, rotation=(.015, 0, side * .10))
        eye["review_role"] = "Eye proportions remain adjustable before rigging."
    brow_mat = material("Brows · soft olive", blend(LEAF, GREEN, .45), .85)
    for side in (-1, 1):
        brow = [face_point(face_surface, side * x, z, .011)
                for x, z in ((.19, 1.755), (.235, 1.777), (.29, 1.766))]
        line(("Left" if side < 0 else "Right") + " brow", brow, .0055, face, brow_mat)
    nose = face_point(face_surface, 0, 1.385)
    nose.y -= .012
    ellipsoid("Nose", nose, (.047, .034, .025), face, ink)
    line("Nose to smile", [face_point(face_surface, 0, z, .008) for z in (1.368, 1.329)],
         .006, face, ink)
    for side in (-1, 1):
        smile = [face_point(face_surface, side * x, z, .008)
                 for x, z in ((0, 1.328), (.043, 1.309), (.081, 1.329))]
        line(("Left" if side < 0 else "Right") + " smile", smile, .006, face, ink)

    if args.fur:
        sys.path.insert(0, str(Path(__file__).parent))
        from coat_fibers import add_groom
        add_groom(surfaces, groom, args.fur_density)

    floor_mat = material("Studio · warm neutral", linear("F5EDDE"), .87)
    floor_shader = floor_mat.node_tree.nodes.get("Principled BSDF")
    floor_shader.inputs["Emission Color"].default_value = (*linear("F5EDDE"), 1)
    floor_shader.inputs["Emission Strength"].default_value = .45
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, 0))
    floor = bpy.context.object
    floor.name = "Studio floor"
    move_to(floor, studio)
    floor.data.materials.append(floor_mat)
    world = bpy.data.worlds.new("Studio · soft ambient")
    world.node_tree.nodes.get("Background").inputs["Color"].default_value = (.80, .74, .64, 1)
    world.node_tree.nodes.get("Background").inputs["Strength"].default_value = .28
    bpy.context.scene.world = world
    area("Key · large softbox", (-3.2, -4.5, 6), 650, 4, studio, (1, .965, .90))
    area("Fill · soft", (4.2, -3, 3), 130, 3.5, studio, (1, .98, .94))
    area("Rim · soft", (1.7, 3.2, 4.6), 350, 3, studio, (1, .965, .90))
    views = {
        "hero": camera("Camera · three-quarter", (4.5, -10, 3.25), studio),
        "front": camera("Camera · front", (0, -10, 2.65), studio),
        "side": camera("Camera · side", (10, 0, 2.65), studio),
        "back": camera("Camera · back", (0, 10, 2.65), studio),
    }
    scene = bpy.context.scene
    scene.camera = views["hero"]
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 6
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.render.resolution_x = scene.render.resolution_y = args.resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.film_transparent = False
    scene["design_status"] = "A · Sprout selected; first 3D model awaiting user review. Unrigged."
    scene["source_concept"] = "Sprout original character"
    scene["authoring_version"] = bpy.app.version_string
    scene["ground_anchor"] = "z = 0; front is -Y; distances in authoring units, not app points."
    scene["palette_srgb"] = json.dumps({"moss": GREEN_HEX, "cream": CREAM_HEX, "leaf": LEAF_HEX})
    bpy.ops.object.select_all(action="DESELECT")
    surfaces[0][0].select_set(True)
    bpy.context.view_layer.objects.active = surfaces[0][0]
    for screen in bpy.data.screens:
        for area_ui in screen.areas:
            if area_ui.type == "VIEW_3D":
                area_ui.spaces.active.region_3d.view_perspective = "CAMERA"
                area_ui.spaces.active.clip_end = 1000

    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    model_path = output / "sprout-design-v01.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(model_path), compress=True)
    paths = []
    for name in requested_views:
        scene.camera = views[name]
        image = output / f"sprout-v01-{name}.png"
        scene.render.filepath = str(image)
        bpy.ops.render.render(write_still=True)
        paths.append(image.name)
    if any(hashlib.sha256(path.read_bytes()).hexdigest() != source_hashes[str(path.relative_to(ROOT))]
           for path in sources):
        raise RuntimeError("Authoring source changed during the build; rebuild to record matching provenance.")
    artifact_paths = [model_path, *(output / name for name in paths)]
    manifest = {"kind": "sprout-model-review", "status": "awaiting-user-review",
                "blender": bpy.app.version_string, "blender_build_hash": bpy.app.build_hash.decode(),
                "model": model_path.name, "renders": paths,
                "resolution": args.resolution, "samples": args.samples,
                "fur": args.fur, "fur_density": args.fur_density,
                "rigged": False, "animated": False, "engine": scene.render.engine,
                "concept": "A · Sprout", "source": "Sprout original character",
                "palette_srgb": {"moss": GREEN_HEX, "cream": CREAM_HEX, "leaf": LEAF_HEX},
                "groom_binding": "rigid parenting; not bound for surface deformation",
                "strand_count": sum(obj.get("strand_count", 0) for obj in groom.objects),
                "source_sha256": source_hashes,
                "artifact_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                    for path in artifact_paths}}
    (output / "model-review.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("SPROUT_MODEL_REVIEW=" + json.dumps(manifest))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default=str(ROOT / ".build/art/sprout"))
    parser.add_argument("--resolution", type=int, default=768)
    parser.add_argument("--samples", type=int, default=48)
    parser.add_argument("--views", default="hero")
    parser.add_argument("--fur", action="store_true")
    parser.add_argument("--fur-density", type=float, default=6500)
    arguments = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    build(parser.parse_args(arguments))

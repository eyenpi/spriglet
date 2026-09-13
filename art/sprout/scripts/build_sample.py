"""Build/export the editable, surface-bound Sprout Step 1 sample in Blender 5.2.

Use a disposable --background --factory-startup process. The reviewed source
model is only read; the sample model and runtime frame set are separate outputs.
--mode preview builds the rig, measures contacts, and renders a few key poses.
--mode export loads the saved rig and publishes manifest.json after all PNGs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time

import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).parent))
from build_design import GREEN, CREAM, LEAF, blend, body_color
from sample_groom import add_bound_groom
from sample_motion import (COUNTS, FPS, bake_actions, select_action, translation)

ROOT = Path(__file__).resolve().parents[3]
SAMPLE = ROOT / "art/sprout/sample-v01"
RUNTIME = ROOT / "Sources/Spriglet/Resources/SproutSample"
SOURCE = ROOT / "art/sprout/review-01/sprout-design-v01.blend"


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def armature_for(objects, collection, centers):
    data = bpy.data.armatures.new("Sprout · editable control skeleton")
    rig = bpy.data.objects.new("Sprout Rig", data)
    collection.objects.link(rig)
    rig.show_in_front = True
    data.display_type = 'STICK'
    bpy.ops.object.select_all(action='DESELECT')
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    specs = [
        ("Stage · export compensation", (0, 0, 0), (0, 0, .12), None),
        ("Root · world travel", (0, 0, 0), (0, 0, .30), "Stage · export compensation"),
        ("Body · breathe", (0, 0, .22), (0, 0, 1.05), "Root · world travel"),
        ("Head · expression", (0, 0, 1.34), (0, 0, 1.85), "Body · breathe"),
        ("Crown · follow", (0, -.08, 1.95), (0, -.08, 2.20), "Head · expression"),
        ("Tail · balance", (.14, .46, .43), (.14, .78, .43), "Body · breathe"),
    ]
    for s, label in ((-1, "Left"), (1, "Right")):
        eye = centers[label + " eye"]
        specs.extend([
            (label + " ear", (s * .32, .015, 1.84), (s * .51, .03, 2.33), "Head · expression"),
            (label + " paw", (s * .54, -.39, 1.17), (s * .54, -.46, .90), "Body · breathe"),
            (label + " foot · plant", (s * .29, -.24, .105), (s * .29, -.24, .30), "Root · world travel"),
            (label + " eye · blink", eye, eye + Vector((0, 0, .12)), "Head · expression"),
        ])
    for name, head, tail, parent in specs:
        bone = data.edit_bones.new(name)
        bone.head, bone.tail = head, tail
        if parent:
            bone.parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode='OBJECT')
    groups = {name: data.collections.new(name) for name in ("01 Master", "02 Body and face", "03 Feet", "04 Ears and paws")}
    for bone in data.bones:
        bucket = "01 Master" if bone.name.startswith(("Root", "Stage")) else "03 Feet" if "plant" in bone.name else "04 Ears and paws" if any(word in bone.name for word in ("ear", "paw", "Crown", "Tail")) else "02 Body and face"
        groups[bucket].assign(bone)
        rig.pose.bones[bone.name].rotation_mode = 'QUATERNION'
    for obj in objects:
        if obj.name == "Sprout body":
            body_group = obj.vertex_groups.new(name="Body · breathe")
            head_group = obj.vertex_groups.new(name="Head · expression")
            for vertex in obj.data.vertices:
                t = min(1, max(0, (vertex.co.z - 1.03) / .31))
                weight = t * t * (3 - 2 * t)
                if weight < 1:
                    body_group.add([vertex.index], 1 - weight, 'REPLACE')
                if weight > 0:
                    head_group.add([vertex.index], weight, 'REPLACE')
        else:
            name = obj.name
            if name.endswith(" eye"):
                control = name + " · blink"
            elif name.endswith(" foot"):
                control = name + " · plant"
            elif name.endswith(" paw"):
                control = name
            elif name.endswith(" leaf ear"):
                control = name.replace(" leaf ear", " ear")
            elif name.startswith("Crown leaf"):
                control = "Crown · follow"
            elif name == "Rounded tail":
                control = "Tail · balance"
            else:
                control = "Head · expression"
            obj.vertex_groups.new(name=control).add(list(range(len(obj.data.vertices))), 1, 'REPLACE')
        modifier = obj.modifiers.new("Sprout control rig", 'ARMATURE')
        modifier.object = rig
        modifier.use_vertex_groups = True
        modifier.use_bone_envelopes = False
    rig["rig_notes"] = "Named pose controls; mesh vertex groups; surface-bound fur; editable Action slots. Stage is export-only compensation."
    return rig


def prepare_geometry():
    character = bpy.data.collections["SPROUT · editable design"]
    groom_collection = bpy.data.collections["04 · Short velvet groom"]
    for obj in tuple(groom_collection.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    groom_collection.name = "04 · Surface-bound velvet groom"
    rig_collection = bpy.data.collections.new("05 · Editable animation controls")
    character.children.link(rig_collection)
    objects = [obj for obj in character.all_objects if obj.type in ('MESH', 'CURVE')]
    centers = {obj.name: obj.matrix_world.translation.copy() for obj in objects}
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for object_index, obj in enumerate(objects):
        transform = obj.matrix_world.copy()
        mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph), preserve_all_data_layers=True, depsgraph=depsgraph)
        if obj.type == 'CURVE':
            # Keep the authored Bézier source available in this .blend too.
            obj.data.use_fake_user = True
        for modifier in tuple(obj.modifiers):
            obj.modifiers.remove(modifier)
        if obj.type == 'CURVE':
            replacement = bpy.data.objects.new(obj.name + " skin", mesh)
            owners = tuple(obj.users_collection)
            name = obj.name
            for owner in owners:
                owner.objects.link(replacement)
            bpy.data.objects.remove(obj, do_unlink=True)
            replacement.name = name
            objects[object_index] = replacement
            obj = replacement
        else:
            obj.data = mesh
        mesh.transform(transform)
        mesh.update()
        obj.parent = None
        obj.matrix_world = Matrix.Identity(4)
    surfaces = []
    for obj in objects:
        name = obj.name
        if name == "Sprout body":
            surfaces.append((obj, body_color, 1.0))
        elif name.endswith(" foot"):
            surfaces.append((obj, lambda _, c=LEAF: c, .25))
        elif name.endswith(" paw"):
            surfaces.append((obj, lambda _, c=GREEN: c, .55))
        elif name.endswith(" leaf ear"):
            surfaces.append((obj, lambda _, c=GREEN: c, .5))
        elif name == "Rounded tail":
            surfaces.append((obj, lambda _, c=GREEN: c, .65))
        elif name.startswith("Crown leaf"):
            surfaces.append((obj, lambda _, c=blend(LEAF, GREEN, .55): c, .16))
    return objects, surfaces, centers, rig_collection, groom_collection


def configure_render(scene, resolution, samples, device):
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = samples
    # Integrated catcher denoising contaminates empty alpha with faint noise.
    # Denoise color in the current compositor while retaining raw render alpha.
    scene.cycles.use_denoising = False
    scene.view_layers[0].cycles.denoising_store_passes = True
    scene.cycles.use_animated_seed = False
    scene.cycles.seed = 1107
    scene.cycles.max_bounces = 6
    scene.render.use_persistent_data = True
    scene.render.resolution_x = scene.render.resolution_y = resolution
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.image_settings.color_depth = '8'
    scene.render.film_transparent = True
    scene.render.dither_intensity = 0
    scene.cycles.device = 'CPU'
    if device == 'METAL':
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.refresh_devices()
        found = False
        for candidate in prefs.devices:
            candidate.use = candidate.type == 'METAL'
            found |= candidate.use
        if not found:
            raise RuntimeError("METAL requested but no Metal device is available; choose explicit --device CPU fallback")
        scene.cycles.device = 'GPU'
    # No preferences are saved. The render pipeline and color management remain
    # those of the reviewed design; only the background becomes transparent.
    floor = bpy.data.objects["Studio floor"]
    floor.is_shadow_catcher = True
    floor.location.z = 0
    # Bound the catcher to a small contact region. An infinite catcher with the
    # review floor's emission produced nonzero alpha at the canvas edges.
    ring = [(1.30 * math.cos(2 * math.pi * i / 96),
             1.30 * math.sin(2 * math.pi * i / 96), 0) for i in range(96)]
    mesh = bpy.data.meshes.new("Contact shadow disk")
    mesh.from_pydata([(0, 0, 0), *ring], [], [(0, i + 1, (i + 1) % 96 + 1) for i in range(96)])
    mesh.update()
    floor.data = mesh
    floor.matrix_world = Matrix.Identity(4)
    material = bpy.data.materials.new("Contact shadow · soft transparent edge")
    nodes = material.node_tree.nodes
    nodes.clear()
    geometry = nodes.new('ShaderNodeNewGeometry')
    distance = nodes.new('ShaderNodeVectorMath')
    distance.operation = 'LENGTH'
    fade = nodes.new('ShaderNodeMapRange')
    fade.interpolation_type = 'SMOOTHSTEP'
    fade.clamp = True
    fade.inputs['From Min'].default_value = .78
    fade.inputs['From Max'].default_value = 1.30
    fade.inputs['To Min'].default_value = 1.0
    fade.inputs['To Max'].default_value = 0.0
    transparent = nodes.new('ShaderNodeBsdfTransparent')
    diffuse = nodes.new('ShaderNodeBsdfDiffuse')
    diffuse.inputs['Color'].default_value = (.65, .60, .50, 1)
    mix = nodes.new('ShaderNodeMixShader')
    output = nodes.new('ShaderNodeOutputMaterial')
    links = material.node_tree.links
    links.new(geometry.outputs['Position'], distance.inputs[0])
    links.new(distance.outputs['Value'], fade.inputs['Value'])
    links.new(fade.outputs['Result'], mix.inputs[0])
    links.new(transparent.outputs['BSDF'], mix.inputs[1])
    links.new(diffuse.outputs['BSDF'], mix.inputs[2])
    links.new(mix.outputs['Shader'], output.inputs['Surface'])
    floor.data.materials.append(material)
    compositor = bpy.data.node_groups.new("Sprout · denoised color, untouched alpha", 'CompositorNodeTree')
    scene.compositing_node_group = compositor
    scene.render.use_compositing = True
    compositor.interface.new_socket(name='Image', in_out='OUTPUT', socket_type='NodeSocketColor')
    layers = compositor.nodes.new('CompositorNodeRLayers')
    denoise = compositor.nodes.new('CompositorNodeDenoise')
    denoise.inputs['HDR'].default_value = True
    alpha = compositor.nodes.new('CompositorNodeSetAlpha')
    alpha.inputs['Type'].default_value = 'Replace Alpha'
    output = compositor.nodes.new('NodeGroupOutput')
    layers.location, denoise.location = (-400, 0), (-150, 100)
    alpha.location, output.location = (100, 100), (330, 100)
    links = compositor.links
    links.new(layers.outputs['Image'], denoise.inputs['Image'])
    links.new(layers.outputs['Denoising Normal'], denoise.inputs['Normal'])
    links.new(layers.outputs['Denoising Albedo'], denoise.inputs['Albedo'])
    links.new(denoise.outputs['Image'], alpha.inputs['Image'])
    links.new(layers.outputs['Alpha'], alpha.inputs['Alpha'])
    links.new(alpha.outputs['Image'], output.inputs['Image'])


def measure_binding(probes, rig, actions):
    maximum = 0.0
    measurements = []
    for clip, index in (("idle", 14), ("walkRight", 30), ("walkLeft", 42), ("pet", 25)):
        select_action(rig, actions[clip])
        bpy.context.scene.frame_set(index + 1)
        bpy.context.view_layer.update()
        graph = bpy.context.evaluated_depsgraph_get()
        for probe in probes:
            source = bpy.data.objects[probe["surface"]].evaluated_get(graph)
            fur = bpy.data.objects[probe["surface"] + " · bound velvet"].evaluated_get(graph)
            expected = sum((source.data.vertices[i].co * w for i, w in zip(probe["vertexIndices"], probe["weights"])), Vector())
            actual = fur.data.points[probe["strand"] * 4].position
            error = (actual - expected).length
            maximum = max(maximum, error)
            measurements.append({"clip": clip, "frame": index, "surface": probe["surface"], "strand": probe["strand"], "rootError": error})
    if maximum > .0005:
        raise RuntimeError(f"Fur attachment error {maximum} exceeds .0005 authoring units")
    return {"maximumRootError": maximum, "tolerance": .0005, "samples": measurements}


def render_pose(rig, action, index, offset_points, path, points_per_unit):
    select_action(rig, action)
    scene = bpy.context.scene
    scene.frame_set(index + 1)
    axis = Vector(json.loads(scene["sample_axis_world"]))
    displacement = axis * (offset_points / points_per_unit)
    stage = rig.pose.bones["Stage · export compensation"]
    base = stage.bone.matrix_local
    stage.matrix_basis = base.inverted() @ translation(-displacement) @ base
    bpy.context.view_layer.update()
    path.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    image = bpy.data.images.load(str(path), check_existing=False)
    try:
        width, height = image.size
        rgba = np.empty(width * height * 4, dtype=np.float32)
        image.pixels.foreach_get(rgba)
        alpha = rgba.reshape(height, width, 4)[:, :, 3]
        border = max(float(alpha[0].max()), float(alpha[-1].max()),
                     float(alpha[:, 0].max()), float(alpha[:, -1].max()))
        if border != 0 or float(alpha.max()) != 1.0:
            raise RuntimeError(f"Invalid transparent export {path}: border alpha={border}, maximum alpha={alpha.max()}")
        return {"maximumBorderAlpha": border, "transparentPixels": int(np.count_nonzero(alpha == 0)),
                "opaquePixels": int(np.count_nonzero(alpha == 1)),
                "partialAlphaPixels": int(np.count_nonzero((alpha > 0) & (alpha < 1)))}
    finally:
        bpy.data.images.remove(image)


def build(args):
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE))
    scene = bpy.context.scene
    camera = bpy.data.objects["Camera · three-quarter"]
    scene.camera = camera
    camera.name = "Camera · runtime locked lighting"
    camera.data.ortho_scale = 3.2
    objects, surfaces, centers, rig_collection, groom_collection = prepare_geometry()
    rig = armature_for(objects, rig_collection, centers)
    # Generate attachment data before the rig has any non-rest pose.
    groom, probes, strands = add_bound_groom(surfaces, groom_collection, args.fur_density)
    bpy.context.view_layer.update()
    actions, contacts, axis = bake_actions(rig, camera)
    scene["sample_axis_world"] = json.dumps(list(axis))
    scene["sample_points_per_unit"] = 224 / camera.data.ortho_scale
    scene["design_status"] = "Step 1 playable Sprout sample; editable rig and surface-bound groom"
    scene["sample_clip_actions"] = json.dumps({clip: action.name for clip, action in actions.items()})
    scene["sample_canvas_pixels"] = 448
    scene["sample_display_points"] = 224
    SAMPLE.mkdir(parents=True, exist_ok=True)
    write_json(SAMPLE / "contact-samples.json", contacts)
    binding = measure_binding(probes, rig, actions)
    write_json(SAMPLE / "groom-binding-verification.json", binding)
    # The saved editable artifact retains production-resolution render settings
    # even when this invocation only produces small key-pose review images.
    configure_render(scene, 448, 48, args.device)
    scene.frame_start, scene.frame_end = 1, contacts["demoFrameCount"]
    # The editable file opens on the complete action with a wide review camera.
    review = camera.copy()
    review.data = camera.data.copy()
    bpy.data.collections["STUDIO · design review"].objects.link(review)
    review.name = "Camera · editable sequence overview"
    review.data.ortho_scale = 4.5
    review.location += axis * (4 * .28 / 2)
    select_action(rig, actions["demo"])
    scene.frame_set(1)
    scene.camera = review
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    for obj in bpy.context.selected_objects:
        if obj != rig:
            obj.select_set(False)
    notes = bpy.data.texts.new("START HERE · Sprout sample")
    notes.write("Sprout Step 1 sample, Blender 5.2.1.\n\nPlay the timeline for idle, four grounded steps, pet reaction, and settle.\nSelect Sprout Rig; Pose Mode controls are grouped in bone collections.\nEach finite clip is also an editable Action with an explicit Object action slot.\nThe Stage bone is export compensation; leave it neutral for authored world travel.\nHair uses native Curves with Deform Curves on Surface, unique attachment UVs, and rest_position.\nExisting-topology edits deform with the rig; regenerate after topology edits.\nThe runtime camera/light setup is locked and shared by both directions.\nFeet have clean soles; no groom roots under the sole band.\nThe overview camera shows the complete travelling action.\n")
    model = SAMPLE / "sprout-sample-v01.blend"
    staged_model = model.with_name(".sprout-sample-v01.building.blend")
    if staged_model.exists():
        staged_model.unlink()
    bpy.ops.wm.save_as_mainfile(filepath=str(staged_model), compress=True)
    os.replace(staged_model, model)
    sources = [Path(__file__), Path(__file__).with_name("sample_motion.py"), Path(__file__).with_name("sample_groom.py"), Path(__file__).with_name("build_design.py"), Path(__file__).with_name("coat_fibers.py")]
    metadata = {"schemaVersion": 1, "blender": bpy.app.version_string,
        "blenderBuildHash": bpy.app.build_hash.decode(), "sourceReview": str(SOURCE.relative_to(ROOT)),
        "sourceReviewSHA256": sha256(SOURCE), "model": model.name,
        "modelSHA256": sha256(model), "rigBoneCount": len(rig.data.bones),
        "contactSamplesSHA256": sha256(SAMPLE / "contact-samples.json"),
        "groomBindingVerificationSHA256": sha256(SAMPLE / "groom-binding-verification.json"),
        "strandCount": strands, "groomBinding": "Native Deform Curves on Surface with attachment UV atlas and rest_position",
        "rigActionNames": {clip: action.name for clip, action in actions.items()},
        "clipFrameCounts": COUNTS, "framesPerSecond": FPS,
        "canvasPixels": {"width": 448, "height": 448}, "displaySizePoints": {"width": 224, "height": 224},
        "groundAnchorPixels": contacts["groundAnchorPixels"],
        "maximumGroomRootError": binding["maximumRootError"],
        "shadow": "Bounded Cycles shadow catcher with smooth transparent edge; compositor denoises RGB and preserves raw alpha",
        "alphaBorderCriterion": "Every pixel on all four exported PNG borders must have alpha exactly 0",
        "savedRenderSettings": {"resolution": 448, "samples": 48, "filmTransparent": True,
                                "cyclesAutomaticDenoising": False, "compositorColorDenoising": True},
        "technologyReferences": [
            "https://docs.blender.org/manual/en/5.2/modeling/modifiers/deform/armature.html",
            "https://docs.blender.org/manual/en/5.2/modeling/geometry_nodes/curve/operations/deform_curves_on_surface.html",
            "https://docs.blender.org/api/5.2/bpy.types.ActionSlot.html",
            "https://docs.blender.org/api/5.2/bpy.types.Scene.html"],
        "sourceSHA256": {str(path.relative_to(ROOT)): sha256(path) for path in sources},
        "phase": "key-pose review"}
    write_json(SAMPLE / "sample-build.json", metadata)
    scene.camera = camera
    configure_render(scene, args.resolution, args.samples, args.device)
    return rig, actions, contacts


def load_sample(args):
    metadata = json.loads((SAMPLE / "sample-build.json").read_text())
    required = {SAMPLE / "sprout-sample-v01.blend": metadata["modelSHA256"],
                SAMPLE / "contact-samples.json": metadata["contactSamplesSHA256"]}
    required.update({ROOT / relative: expected for relative, expected in metadata["sourceSHA256"].items()})
    for path, expected in required.items():
        if sha256(path) != expected:
            raise RuntimeError(f"Sample provenance mismatch: {path}. Regenerate the rig/contact metadata with --mode preview before export. Edited Actions require fresh contact validation.")
    bpy.ops.wm.open_mainfile(filepath=str(SAMPLE / "sprout-sample-v01.blend"))
    scene = bpy.context.scene
    scene.camera = bpy.data.objects["Camera · runtime locked lighting"]
    rig = bpy.data.objects["Sprout Rig"]
    actions = {clip: bpy.data.actions[name] for clip, name in json.loads(scene["sample_clip_actions"]).items()}
    contacts = json.loads((SAMPLE / "contact-samples.json").read_text())
    configure_render(scene, args.resolution, args.samples, args.device)
    return rig, actions, contacts


def export(args, rig, actions, contacts):
    scene = bpy.context.scene
    scale = float(scene["sample_points_per_unit"])
    if args.mode == "preview":
        output = Path(args.preview_dir)
        for clip, index in (("idle", 0), ("idle", 15), ("walkRight", 18), ("walkRight", 30), ("walkLeft", 30), ("pet", 25), ("settle", 24), ("sleep", 0)):
            offset = contacts["clips"][clip]["frames"][index]["rootOffsetPoints"]["x"] if clip in contacts["clips"] else 0
            render_pose(rig, actions[clip], index, offset, output / f"{clip}-{index:04d}.png", scale)
        return
    if args.resolution != 448:
        raise ValueError("Runtime export requires exactly 448 pixels")
    manifest = {"schemaVersion": 1, "canvasPixels": {"width": 448, "height": 448},
        "displaySizePoints": {"width": 224, "height": 224}, "framesPerSecond": FPS,
        "groundAnchorPixels": contacts["groundAnchorPixels"], "restFrame": "rest.png", "sleepFrame": "sleep.png", "clips": {}}
    alpha_results = {}
    alpha_results["rest.png"] = render_pose(rig, actions["idle"], 0, 0, RUNTIME / "rest.png", scale)
    alpha_results["sleep.png"] = render_pose(rig, actions["sleep"], 0, 0, RUNTIME / "sleep.png", scale)
    for clip, count in COUNTS.items():
        frames = []
        for i in range(count):
            offset = contacts["clips"][clip]["frames"][i]["rootOffsetPoints"]
            relative = f"clips/{clip}/{i:04d}.png"
            alpha_results[relative] = render_pose(rig, actions[clip], i, offset["x"], RUNTIME / relative, scale)
            frames.append({"file": relative, "rootOffsetPoints": offset})
        manifest["clips"][clip] = {"frames": frames, "duration": count / FPS}
        print(f"SPROUT_CLIP_EXPORTED={clip}", flush=True)
    write_json(RUNTIME / "manifest.json", manifest)
    write_json(SAMPLE / "alpha-verification.json", {"criterion": "all four border rows/columns are exactly alpha 0",
        "frameCount": len(alpha_results), "maximumBorderAlpha": max(v["maximumBorderAlpha"] for v in alpha_results.values()),
        "frames": alpha_results})
    metadata = json.loads((SAMPLE / "sample-build.json").read_text())
    metadata.update(phase="exported", renderSamples=args.samples, renderDevice=args.device,
                    runtimeManifestSHA256=sha256(RUNTIME / "manifest.json"),
                    alphaVerificationSHA256=sha256(SAMPLE / "alpha-verification.json"),
                    runtimeFrameCount=2 + sum(COUNTS.values()))
    write_json(SAMPLE / "sample-build.json", metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("preview", "export"), default="preview")
    parser.add_argument("--resolution", type=int, default=256)
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--device", choices=("CPU", "METAL"), default="CPU")
    parser.add_argument("--fur-density", type=float, default=6500)
    parser.add_argument("--preview-dir", default=str(ROOT / ".build/art/sprout/sample-key-poses"))
    parser.add_argument("--reuse-model", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    if not bpy.app.background or "--factory-startup" not in sys.argv:
        raise RuntimeError("Use a disposable --background --factory-startup Blender process")
    if bpy.app.version[:2] != (5, 2):
        raise RuntimeError("This pipeline is verified against installed Blender 5.2")
    if not 64 <= args.resolution <= 1024 or not 1 <= args.samples <= 512:
        raise ValueError("Resolution or sample count outside bounded export range")
    started = time.monotonic()
    rig, actions, contacts = load_sample(args) if args.reuse_model else build(args)
    export(args, rig, actions, contacts)
    print(f"SPROUT_SAMPLE_SECONDS={time.monotonic() - started:.3f}", flush=True)


if __name__ == "__main__":
    main()

"""Render the Spriglet app icon from the saved, unchanged editable Sprout rig.

Use Blender 5.2 with --background --factory-startup --python-exit-code 1.
The output scene, foreground layer, and flattened icon are separate artifacts.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
SOURCE = ROOT / "art/sprout/sample-v01/sprout-sample-v01.blend"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def linear_hex(value):
    values = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolution", type=int, default=1024)
    parser.add_argument("--samples", type=int, default=128)
    parser.add_argument("--device", choices=("CPU", "METAL"), default="METAL")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    if not bpy.app.background or "--factory-startup" not in sys.argv:
        raise RuntimeError("Use a disposable background factory-startup Blender process")
    if bpy.app.version[:2] != (5, 2):
        raise RuntimeError("This icon source is verified with Blender 5.2")
    if args.resolution not in (512, 1024) or not 16 <= args.samples <= 512:
        raise ValueError("Use 512/1024 pixels and 16–512 samples")
    recorded = json.loads((SOURCE.parent / "sample-build.json").read_text())
    source_hash = digest(SOURCE)
    if source_hash != recorded["modelSHA256"]:
        raise RuntimeError("Saved Sprout model does not match its recorded provenance")
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE))
    sys.path.insert(0, str(ROOT / "art/sprout/scripts"))
    from sample_motion import select_action
    rig = bpy.data.objects["Sprout Rig"]
    select_action(rig, bpy.data.actions[recorded["rigActionNames"]["idle"]])
    scene = bpy.context.scene
    scene.frame_set(1)
    bpy.data.objects["Studio floor"].hide_render = True

    # A near-frontal portrait makes the existing face readable at Dock sizes.
    # Cropping the lower body is a camera choice; the model/rig stays intact.
    camera_data = bpy.data.cameras.new("Spriglet icon · portrait camera")
    camera_data.type = 'ORTHO'
    camera_data.ortho_scale = 2.10
    camera = bpy.data.objects.new(camera_data.name, camera_data)
    scene.collection.objects.link(camera)
    target = Vector((0, -.12, 1.55))
    camera.location = (0, -10, 2.10)
    camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
    scene.camera = camera
    scene.render.resolution_x = scene.render.resolution_y = args.resolution
    scene.render.resolution_percentage = 100
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = False  # Saved compositor: denoised RGB + raw alpha.
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.image_settings.color_depth = '8'
    scene.render.film_transparent = True
    scene.render.dither_intensity = 0
    scene.cycles.device = 'CPU'
    if args.device == 'METAL':
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.refresh_devices()
        for device in prefs.devices:
            device.use = device.type == 'METAL'
        if not any(device.use for device in prefs.devices):
            raise RuntimeError("No Metal render device; choose --device CPU explicitly")
        scene.cycles.device = 'GPU'

    foreground = OUTPUT / "sprout-icon-foreground.png"
    scene.render.filepath = str(foreground)
    bpy.ops.render.render(write_still=True)

    # The asset catalog receives an unmasked, full-bleed square. macOS applies
    # its icon enclosure; no rounded-corner template or drop shadow is baked in.
    mesh = bpy.data.meshes.new("Spriglet icon · background square")
    mesh.from_pydata([(-2, -2, 0), (2, -2, 0), (2, 2, 0), (-2, 2, 0)], [], [(0, 1, 2, 3)])
    plane = bpy.data.objects.new(mesh.name, mesh)
    scene.collection.objects.link(plane)
    plane.rotation_euler = camera.rotation_euler
    plane.location = camera.location + camera.rotation_euler.to_quaternion() @ Vector((0, 0, -14))
    plane.visible_diffuse = plane.visible_glossy = plane.visible_transmission = False
    plane.visible_shadow = False
    material = bpy.data.materials.new("Spriglet icon · warm paper gradient")
    nodes = material.node_tree.nodes
    nodes.clear()
    tex = nodes.new('ShaderNodeTexCoord')
    separate = nodes.new('ShaderNodeSeparateXYZ')
    ramp = nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].color = (*linear_hex("DCC395"), 1)
    ramp.color_ramp.elements[1].color = (*linear_hex("FFF2D5"), 1)
    emission = nodes.new('ShaderNodeEmission')
    emission.inputs['Strength'].default_value = 1.8
    output = nodes.new('ShaderNodeOutputMaterial')
    links = material.node_tree.links
    links.new(tex.outputs['Generated'], separate.inputs[0])
    links.new(separate.outputs['Y'], ramp.inputs['Fac'])
    links.new(ramp.outputs['Color'], emission.inputs['Color'])
    links.new(emission.outputs['Emission'], output.inputs['Surface'])
    mesh.materials.append(material)
    image_path = OUTPUT / "spriglet-app-icon-1024.png"
    scene.render.filepath = str(image_path)
    scene["icon_source_model"] = str(SOURCE.relative_to(ROOT))
    scene["icon_source_model_sha256"] = source_hash
    scene["icon_design"] = "Unmasked frontal Sprout portrait; reviewed face and palette; no floor or external shadow"
    temporary = OUTPUT / ".spriglet-icon-building.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(temporary), check_existing=False)
    temporary.replace(OUTPUT / "spriglet-icon.blend")
    bpy.ops.render.render(write_still=True)
    if digest(SOURCE) != source_hash:
        raise RuntimeError("Original saved model changed during icon export")
    metadata = {
        "schemaVersion": 1,
        "blender": bpy.app.version_string,
        "blenderBuildHash": bpy.app.build_hash.decode(),
        "sourceModel": str(SOURCE.relative_to(ROOT)),
        "sourceModelSHA256": source_hash,
        "sourceUnchanged": True,
        "scriptSHA256": digest(Path(__file__)),
        "iconScene": "spriglet-icon.blend",
        "iconSceneSHA256": digest(OUTPUT / "spriglet-icon.blend"),
        "resolution": args.resolution,
        "samples": args.samples,
        "renderDevice": args.device,
        "foregroundImage": foreground.name,
        "foregroundImageSHA256": digest(foreground),
        "appIconImage": image_path.name,
        "appIconImageSHA256": digest(image_path),
        "composition": "Near-frontal portrait from the existing neutral rig pose; lower body cropped by camera; full-bleed warm gradient; no baked outer shadow or enclosure mask",
        "preferencesSaved": False,
    }
    (OUTPUT / "icon-render.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()

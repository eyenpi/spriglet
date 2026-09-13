"""Read back the saved Sprout rig in a disposable Blender 5.2 process.

Run with --background --factory-startup --python-exit-code 1. This verifier
changes poses only in memory, never renders or saves a .blend, and writes its
result to art/sprout/sample-v01/verification.json. PNG validation is separate.
"""

import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[3]
SAMPLE = ROOT / "art/sprout/sample-v01"
POSE_SAMPLES = (("idle", 14), ("walkRight", 30), ("walkLeft", 42), ("pet", 25))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def attachment_probes(grooms, rig):
    """Independently recover rest-surface barycentric coordinates from roots."""
    probes = []
    for fur in grooms:
        surface = fur.data.surface
        require(surface is not None, f"Missing attachment surface: {fur.name}")
        require(fur.data.surface_uv_map in surface.data.uv_layers,
                f"Missing attachment UV map: {fur.name}")
        require("rest_position" in surface.data.attributes,
                f"Missing rest positions: {surface.name}")
        require("surface_uv_coordinate" in fur.data.attributes,
                f"Missing strand UV coordinates: {fur.name}")
        require(any(m.type == 'NODES' and m.node_group and any(
            n.bl_idname == 'GeometryNodeDeformCurvesOnSurface' for n in m.node_group.nodes
        ) for m in fur.modifiers), f"Missing native surface deformation: {fur.name}")
        require(any(m.type == 'ARMATURE' and m.object == rig for m in surface.modifiers),
                f"Surface is not bound to the saved rig: {surface.name}")
        require(len(fur.data.curves) >= 8 and len(fur.data.points) == 4 * len(fur.data.curves),
                f"Unexpected four-point sample groom layout: {fur.name}")
        surface.data.calc_loop_triangles()
        triangles = [tuple(t.vertices) for t in surface.data.loop_triangles]
        positions = [v.co.copy() for v in surface.data.vertices]
        tree = BVHTree.FromPolygons(positions, triangles, all_triangles=True)
        into_surface = surface.matrix_world.inverted() @ fur.matrix_world
        for strand in range(8):
            point = into_surface @ fur.data.points[strand * 4].position
            _, _, index, distance = tree.find_nearest(point)
            require(index is not None and distance < 1e-5,
                    f"Rest root misses its surface: {fur.name}, strand {strand}")
            indices = triangles[index]
            a, b, c = [positions[i] for i in indices]
            v0, v1, v2 = b - a, c - a, point - a
            d00, d01, d11 = v0.dot(v0), v0.dot(v1), v1.dot(v1)
            d20, d21 = v2.dot(v0), v2.dot(v1)
            denominator = d00 * d11 - d01 * d01
            require(abs(denominator) > 1e-20, "Degenerate attachment triangle")
            v = (d11 * d20 - d01 * d21) / denominator
            w = (d00 * d21 - d01 * d20) / denominator
            probes.append((fur.name, surface.name, strand, indices, (1 - v - w, v, w)))
    return probes


def verify_changed_model_refusal(metadata, build_sample):
    scratch = ROOT / ".build/art/sprout-api"
    scratch.mkdir(parents=True, exist_ok=True)
    original = build_sample.SAMPLE
    with tempfile.TemporaryDirectory(dir=scratch, prefix="provenance-check-") as directory:
        path = Path(directory)
        (path / "sample-build.json").write_text(json.dumps(metadata))
        (path / metadata["model"]).write_bytes(b"Deliberately changed disposable model")
        (path / "contact-samples.json").write_bytes((SAMPLE / "contact-samples.json").read_bytes())
        build_sample.SAMPLE = path
        try:
            build_sample.load_sample(SimpleNamespace(resolution=448, samples=48, device='CPU'))
        except RuntimeError as error:
            require("provenance mismatch" in str(error), f"Unexpected refusal: {error}")
        else:
            raise RuntimeError("Changed-model export guard did not reject the disposable model")
        finally:
            build_sample.SAMPLE = original


def main():
    require(bpy.app.background and "--factory-startup" in sys.argv,
            "Use a disposable --background --factory-startup Blender process")
    require(bpy.app.version[:2] == (5, 2), "This verifier is checked against Blender 5.2")
    sys.path.insert(0, str(Path(__file__).parent))
    import build_sample
    from sample_motion import select_action

    metadata = json.loads((SAMPLE / "sample-build.json").read_text())
    contacts = json.loads((SAMPLE / "contact-samples.json").read_text())
    binding = json.loads((SAMPLE / "groom-binding-verification.json").read_text())
    required_hashes = {
        SAMPLE / metadata["model"]: metadata["modelSHA256"],
        SAMPLE / "contact-samples.json": metadata["contactSamplesSHA256"],
        SAMPLE / "groom-binding-verification.json": metadata["groomBindingVerificationSHA256"],
        SAMPLE / "alpha-verification.json": metadata["alphaVerificationSHA256"],
        ROOT / metadata["sourceReview"]: metadata["sourceReviewSHA256"],
        ROOT / "Sources/Spriglet/Resources/SproutSample/manifest.json": metadata["runtimeManifestSHA256"],
        **{ROOT / path: expected for path, expected in metadata["sourceSHA256"].items()},
    }
    for path, expected in required_hashes.items():
        require(sha256(path) == expected, f"Recorded input hash mismatch: {path.relative_to(ROOT)}")
    required_hashes[SAMPLE / "sample-build.json"] = sha256(SAMPLE / "sample-build.json")

    bpy.ops.wm.open_mainfile(filepath=str(SAMPLE / metadata["model"]))
    scene = bpy.context.scene
    rig = bpy.data.objects["Sprout Rig"]
    require(scene.camera.name == "Camera · editable sequence overview", "Opening camera is not the overview")
    require(rig.animation_data.action.name == metadata["rigActionNames"]["demo"], "Opening Action is not the complete sample")
    require(scene.render.resolution_x == scene.render.resolution_y == 448, "Saved resolution changed")
    require(scene.cycles.samples == 48, "Saved sample count changed")
    require(scene.render.film_transparent and not scene.cycles.use_denoising, "Saved alpha/denoising settings changed")
    require(len(rig.data.bones) == metadata["rigBoneCount"] == 14, "Control rig bone count changed")
    compositor = scene.compositing_node_group
    require(scene.render.use_compositing and compositor is not None, "Missing active compositor")
    alpha = next(n for n in compositor.nodes if n.bl_idname == 'CompositorNodeSetAlpha')
    require(alpha.inputs['Type'].default_value == 'Replace Alpha', "Alpha replacement mode changed")
    alpha_source = alpha.inputs['Alpha'].links[0]
    require(alpha_source.from_node.bl_idname == 'CompositorNodeRLayers' and
            alpha_source.from_socket.name == 'Alpha', "Compositor does not preserve raw render alpha")
    require(alpha.inputs['Image'].links[0].from_node.bl_idname == 'CompositorNodeDenoise',
            "Compositor color is not denoised")
    output = next(n for n in compositor.nodes if n.bl_idname == 'NodeGroupOutput')
    require(output.inputs['Image'].links[0].from_node == alpha, "Alpha replacement is not the compositor output")
    floor = bpy.data.objects["Studio floor"]
    require(floor.is_shadow_catcher and max(v.co.length for v in floor.data.vertices) < 1.301,
            "Missing bounded shadow catcher")
    actions = {clip: bpy.data.actions[name] for clip, name in json.loads(scene["sample_clip_actions"]).items()}
    grooms = [o for o in bpy.data.objects if o.type == 'CURVES' and o.get("strand_count")]
    require(len(grooms) == 11 and sum(len(o.data.curves) for o in grooms) == metadata["strandCount"],
            "Saved native groom object/strand count changed")
    probes = attachment_probes(grooms, rig)
    maximum_root_error = 0.0
    for clip, frame in POSE_SAMPLES:
        select_action(rig, actions[clip])
        scene.frame_set(frame + 1)
        graph = bpy.context.evaluated_depsgraph_get()
        for fur_name, surface_name, strand, indices, weights in probes:
            skin = bpy.data.objects[surface_name].evaluated_get(graph)
            fur = bpy.data.objects[fur_name].evaluated_get(graph)
            expected = skin.matrix_world @ sum(
                (skin.data.vertices[i].co * w for i, w in zip(indices, weights)), Vector())
            actual = fur.matrix_world @ fur.data.points[strand * 4].position
            maximum_root_error = max(maximum_root_error, (actual - expected).length)
    require(maximum_root_error < binding["tolerance"], f"Evaluated groom root error: {maximum_root_error}")

    maximum_foot_height, minimum_fur_height, stance_checks = 0.0, float('inf'), 0
    for clip in ("walkRight", "walkLeft"):
        select_action(rig, actions[clip])
        clip_stance_checks = 0
        for frame in contacts["clips"][clip]["frames"]:
            scene.frame_set(frame["index"] + 1)
            graph = bpy.context.evaluated_depsgraph_get()
            for side in ("left", "right"):
                if not frame["feet"][side]["planted"]:
                    continue
                skin = bpy.data.objects[side.title() + " foot"].evaluated_get(graph)
                min_z = min((skin.matrix_world @ v.co).z for v in skin.data.vertices)
                maximum_foot_height = max(maximum_foot_height, abs(min_z - contacts["worldGroundZ"]))
                fur = bpy.data.objects[side.title() + " foot · bound velvet"].evaluated_get(graph)
                minimum_fur_height = min(minimum_fur_height,
                    min((fur.matrix_world @ p.position).z - contacts["worldGroundZ"] for p in fur.data.points))
                clip_stance_checks += 1
        require(clip_stance_checks > 0, f"No planted foot checks for {clip}")
        stance_checks += clip_stance_checks
    require(maximum_foot_height < contacts["groundHeightTolerance"], f"Planted foot mesh error: {maximum_foot_height}")
    require(minimum_fur_height > 0, f"Planted sole fibers intersect ground: {minimum_fur_height}")
    verify_changed_model_refusal(metadata, build_sample)
    for path, expected in required_hashes.items():
        require(sha256(path) == expected, f"Input changed during verification: {path.relative_to(ROOT)}")

    result = {
        "schemaVersion": 1, "passed": True,
        "verifierSHA256": sha256(Path(__file__)),
        "blender": bpy.app.version_string, "blenderBuildHash": bpy.app.build_hash.decode(),
        "modelSHA256": metadata["modelSHA256"],
        "sampleBuildSHA256": required_hashes[SAMPLE / "sample-build.json"],
        "openingAction": metadata["rigActionNames"]["demo"],
        "openingCamera": "Camera · editable sequence overview",
        "savedResolution": 448, "savedSamples": 48, "controlBoneCount": 14,
        "nativeGroomObjects": len(grooms), "nativeStrandCount": metadata["strandCount"],
        "groomProbeCount": len(probes) * len(POSE_SAMPLES),
        "groomPoseSamples": [{"clip": clip, "frameIndex": frame} for clip, frame in POSE_SAMPLES],
        "maximumReadbackGroomRootError": maximum_root_error, "groomRootErrorTolerance": binding["tolerance"],
        "nativePlantedFootMeshChecks": stance_checks,
        "maximumPlantedFootMeshGroundError": maximum_foot_height,
        "groundHeightTolerance": contacts["groundHeightTolerance"],
        "minimumPlantedSoleFiberHeight": minimum_fur_height,
        "rawAlphaCompositorVerified": True, "boundedShadowCatcherVerified": True,
        "recordedInputHashesVerified": True, "checkedInputsUnchanged": True,
        "changedModelProvenanceRefusalVerified": True,
        "rendered": False, "savedBlend": False,
        "scope": "Saved model readback; first 8 strand roots per groom at 4 poses; full evaluated foot meshes/fibers at every declared walk stance frame. Distances are world/model units. PNG pixels and projected contact drift are checked by the independent asset validator.",
    }
    output = SAMPLE / "verification.json"
    temporary = output.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(output)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

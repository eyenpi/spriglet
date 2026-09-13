"""Read saved model metadata in an isolated Blender process; never save/render.

The parent captures this process's output. Hex-encoded private values are used
only in memory to locate exact fixed-width metadata fields; do not publish raw
process output. PUBLICATION.json contains field names and byte proofs only.
"""

import hashlib
import json
from pathlib import Path
import sys

import bpy


def inspect(path):
    bpy.ops.wm.open_mainfile(filepath=str(path), load_ui=True, use_scripts=False)
    properties = []
    replacements = []
    seen = set()
    for si, screen in enumerate(bpy.data.screens):
        for ai, area in enumerate(screen.areas):
            for pi, space in enumerate(area.spaces):
                params = getattr(space, "params", None)
                if params is None or not hasattr(params, "directory") or params.as_pointer() in seen:
                    continue
                seen.add(params.as_pointer())
                value = params.directory
                if not isinstance(value, bytes):
                    raise RuntimeError("Unsupported file-browser directory representation")
                key = f"screens[{si}].areas[{ai}].spaces[{pi}].FileSelectParams.directory"
                properties.append({"property": key, "valueHex": value.hex()})
                if value.startswith(b"/Users/"):
                    replacements.append({"property": key, "originalHex": value.hex(), "replacementHex": b"//".hex()})
    for si, scene in enumerate(bpy.data.scenes):
        value = scene.render.filepath.encode("utf-8")
        key = f"scenes[{si}].render.filepath"
        properties.append({"property": key, "valueHex": value.hex()})
        if value.startswith(b"/Users/"):
            replacement = ("//" + Path(scene.render.filepath).name).encode("utf-8")
            replacements.append({"property": key, "originalHex": value.hex(), "replacementHex": replacement.hex()})
    summary = {
        "objects": len(bpy.data.objects), "meshes": len(bpy.data.meshes),
        "hairCurves": len(bpy.data.hair_curves), "materials": len(bpy.data.materials),
        "actions": len(bpy.data.actions), "armatures": len(bpy.data.armatures),
        "cameras": len(bpy.data.cameras), "lights": len(bpy.data.lights),
        "libraries": len(bpy.data.libraries),
        "scenes": [{"name": s.name, "frame": s.frame_current,
                    "camera": s.camera.name if s.camera else None,
                    "resolution": [s.render.resolution_x, s.render.resolution_y],
                    "engine": s.render.engine} for s in bpy.data.scenes],
    }
    return {"file": path.as_posix(), "properties": properties, "replacements": replacements,
            "readbackSummarySHA256": hashlib.sha256(json.dumps(summary, sort_keys=True).encode()).hexdigest()}


if __name__ == "__main__":
    if not bpy.app.background or "--factory-startup" not in sys.argv or "--disable-autoexec" not in sys.argv:
        raise RuntimeError("Use an isolated factory-startup process with autoexec disabled")
    if bpy.app.version[:2] != (5, 2):
        raise RuntimeError("This bounded model reader is verified against Blender 5.2")
    paths = [Path(value) for value in sys.argv[sys.argv.index("--") + 1:]]
    result = {"blender": bpy.app.version_string, "models": [inspect(path) for path in paths]}
    print("PUBLIC_MODEL_METADATA=" + json.dumps(result, sort_keys=True))

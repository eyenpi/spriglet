#!/usr/bin/env python3
"""Opt-in native metadata test using a disposable default cube, never Sprout art."""

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blender", default="/Applications/Blender.app/Contents/MacOS/Blender")
    parser.add_argument("--zstd", default=shutil.which("zstd"))
    args = parser.parse_args()
    if not args.zstd:
        raise RuntimeError("zstd is required for this compressed-model fixture")
    spec = importlib.util.spec_from_file_location("public_release", Path(__file__).with_name("prepare-public.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix="spriglet-public-model-fixture-") as directory:
        root = Path(directory)
        path = root / "fixture.blend"
        # The temporary artifact deliberately exercises both allowed properties.
        code = """import bpy, pathlib, sys
scene=bpy.context.scene
scene.render.filepath=str(pathlib.Path.home()/"private-fixture-output.png")
bpy.ops.wm.save_as_mainfile(filepath=sys.argv[-1], compress=True)
"""
        process = subprocess.run([args.blender, "--background", "--factory-startup", "--disable-autoexec",
            "--python-exit-code", "1", "--python-expr", code, "--", str(path)], capture_output=True)
        if process.returncode:
            raise RuntimeError("Synthetic model creation failed; raw logs suppressed")
        before = module.blender_metadata(args.blender, root, ["fixture.blend"])["models"][0]
        raw, _ = module.decode_model(path.read_bytes(), args.zstd)
        clean, proof = module.patch_model_bytes(raw, before["replacements"])
        compressed = subprocess.run([args.zstd, "-q", "-c"], input=clean, capture_output=True, check=True).stdout
        path.write_bytes(compressed)
        if module.decode_model(path.read_bytes(), args.zstd)[0] != clean:
            raise RuntimeError("Compression roundtrip differed")
        after = module.blender_metadata(args.blender, root, ["fixture.blend"])["models"][0]
        expected = {value["property"]: value["valueHex"] for value in before["properties"]}
        expected.update({value["property"]: value["replacementHex"] for value in before["replacements"]})
        if (after["replacements"] or before["readbackSummarySHA256"] != after["readbackSummarySHA256"]
                or expected != {value["property"]: value["valueHex"] for value in after["properties"]}):
            raise RuntimeError("Native metadata readback mismatch")
        print(json.dumps({"passed": True, "fixture": "disposable default cube",
                          "redactedFieldCount": proof["redactedFieldCount"],
                          "allNonMetadataBytesIdentical": proof["bytesOutsideMetadataRangesIdentical"],
                          "isolatedBlenderReopenPassed": True, "existingArtworkTouched": False}, indent=2))


if __name__ == "__main__":
    main()

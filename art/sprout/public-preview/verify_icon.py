"""Verify icon pixels, source provenance, and current Xcode catalog compilation.

Run in a disposable Blender background process. No images or models are edited.
"""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

import bpy
import numpy as np

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
CATALOG = ROOT / "Sources/Spriglet/Assets.xcassets"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if not bpy.app.background or "--factory-startup" not in sys.argv:
        raise RuntimeError("Use a disposable --background --factory-startup process")
    metadata = json.loads((OUTPUT / "icon-render.json").read_text())
    for path, expected in {
        ROOT / metadata["sourceModel"]: metadata["sourceModelSHA256"],
        OUTPUT / metadata["iconScene"]: metadata["iconSceneSHA256"],
        OUTPUT / metadata["appIconImage"]: metadata["appIconImageSHA256"],
        OUTPUT / metadata["foregroundImage"]: metadata["foregroundImageSHA256"],
        OUTPUT / "render_icon.py": metadata["scriptSHA256"],
    }.items():
        if digest(path) != expected:
            raise RuntimeError(f"Recorded icon provenance mismatch: {path.relative_to(ROOT)}")
    icon_dir = CATALOG / "AppIcon.appiconset"
    catalog = json.loads((icon_dir / "Contents.json").read_text())
    expected_slots = {(f"{size}x{size}", f"{scale}x") for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
    if len(catalog["images"]) != 10 or {(v["size"], v["scale"]) for v in catalog["images"]} != expected_slots:
        raise RuntimeError("macOS icon catalog does not contain exactly the ten required slots")
    images = []
    for slot in catalog["images"]:
        path = icon_dir / slot["filename"]
        if slot["idiom"] != "mac" or path.parent != icon_dir:
            raise RuntimeError("Unexpected app icon catalog entry")
        pixels = int(slot["size"].split('x')[0]) * int(slot["scale"][:-1])
        loaded = bpy.data.images.load(str(path), check_existing=False)
        alpha = np.asarray(loaded.pixels[:], dtype=np.float32).reshape(-1, 4)[:, 3]
        if tuple(loaded.size) != (pixels, pixels) or not np.all(alpha == 1):
            raise RuntimeError(f"Icon size/opaque-alpha check failed: {path.name}")
        images.append({"file": str(path.relative_to(ROOT)), "pixels": pixels,
            "colorSpace": loaded.colorspace_settings.name, "minimumAlpha": float(alpha.min()),
            "maximumAlpha": float(alpha.max()), "sha256": digest(path)})
        bpy.data.images.remove(loaded)
    scratch = ROOT / ".build/art/sprout-icon"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix="verify-catalog-") as directory:
        compiled = Path(directory)
        partial_info = compiled / "app-icon-info.plist"
        args = ["xcrun", "actool", str(CATALOG), "--compile", str(compiled),
            "--platform", "macosx", "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
            "--output-partial-info-plist", str(partial_info), "--output-format", "xml1",
            "--notices", "--warnings", "--errors"]
        process = subprocess.run(args, capture_output=True, check=True)
        report = plistlib.loads(process.stdout)
        diagnostics = {key: value for key, value in report.items() if any(
            word in key for word in ("warnings", "errors")) and value}
        if diagnostics:
            raise RuntimeError(f"Asset compiler diagnostics: {diagnostics}")
        info = plistlib.loads(partial_info.read_bytes())
        if info.get("CFBundleIconName") != "AppIcon" or info.get("CFBundleIconFile") != "AppIcon":
            raise RuntimeError("Compiler did not declare AppIcon in the partial Info.plist")
        if not (compiled / "Assets.car").exists() or not (compiled / "AppIcon.icns").exists():
            raise RuntimeError("Compiler did not produce the expected macOS icon resources")
    result = {"schemaVersion": 1, "passed": True,
        "verifierSHA256": digest(Path(__file__)), "blender": bpy.app.version_string,
        "xcode": subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout.strip(),
        "originalModelSHA256": metadata["sourceModelSHA256"], "provenanceVerified": True,
        "catalogCompiled": True, "compilerWarningsOrErrors": [], "appIconName": "AppIcon",
        "images": images, "rendered": False, "savedBlend": False,
        "scope": "All ten catalog slot dimensions, decoded opaque alpha, source hashes, and a clean current macOS actool compile. System masking and appearance transformations need native app review."}
    (OUTPUT / "icon-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

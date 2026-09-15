"""Verify the current icon's provenance, ten macOS sizes, and Xcode compilation.

Run with Python 3 on a Mac with full Xcode selected. No Blender or Python packages
are needed. The report and compiled review resources stay under .build/.
"""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = Path(__file__).resolve().parent
CATALOG = ROOT / "Sources/Spriglet/Assets.xcassets"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_image(path, pixels):
    properties = ("pixelWidth", "pixelHeight", "format", "space", "hasAlpha", "profile")
    arguments = ["/usr/bin/sips"]
    for name in properties:
        arguments.extend(["--getProperty", name])
    result = subprocess.run([*arguments, str(path)], capture_output=True, text=True, check=True)
    values = dict(line.strip().split(": ", 1) for line in result.stdout.splitlines()[1:] if ": " in line)
    expected = {"pixelWidth": str(pixels), "pixelHeight": str(pixels),
                "format": "png", "space": "RGB", "hasAlpha": "no"}
    if any(values.get(name) != value for name, value in expected.items()):
        raise RuntimeError(f"Icon dimensions, format, or opacity mismatch: {path.name}: {values}")
    return {"file": str(path.relative_to(ROOT)), "pixels": pixels,
            "colorProfile": values.get("profile"), "opaque": True, "sha256": digest(path)}


def main():
    metadata = json.loads((OUTPUT / "provenance.json").read_text())
    if metadata["schemaVersion"] != 1:
        raise RuntimeError("Unsupported icon provenance schema")
    for name in ("sourceImage", "masterImage", "prompt"):
        entry = metadata[name]
        path = OUTPUT / entry["file"]
        if path.parent != OUTPUT or digest(path) != entry["sha256"]:
            raise RuntimeError(f"Recorded icon provenance mismatch: {entry['file']}")
    source = inspect_image(OUTPUT / metadata["sourceImage"]["file"], metadata["sourceImage"]["pixels"])
    master = inspect_image(OUTPUT / metadata["masterImage"]["file"], 1024)
    if master["colorProfile"] != "sRGB IEC61966-2.1":
        raise RuntimeError("The icon master must carry the sRGB color profile")
    icon_dir = CATALOG / "AppIcon.appiconset"
    catalog = json.loads((icon_dir / "Contents.json").read_text())
    expected_slots = {(f"{size}x{size}", f"{scale}x") for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
    slots = catalog["images"]
    if len(slots) != 10 or {(v["size"], v["scale"]) for v in slots} != expected_slots:
        raise RuntimeError("macOS icon catalog does not contain exactly the ten required slots")
    filenames = {slot["filename"] for slot in slots}
    if len(filenames) != 10 or filenames != set(metadata["catalogImages"]) or filenames != {path.name for path in icon_dir.glob("*.png")}:
        raise RuntimeError("Unexpected or duplicate icon catalog files")
    images = []
    for slot in slots:
        path = icon_dir / slot["filename"]
        if slot["idiom"] != "mac" or path.parent != icon_dir:
            raise RuntimeError("Unexpected app icon catalog entry")
        pixels = int(slot["size"].split("x")[0]) * int(slot["scale"][:-1])
        inspected = inspect_image(path, pixels)
        if inspected["colorProfile"] != master["colorProfile"]:
            raise RuntimeError(f"Icon color profile differs from the master: {path.name}")
        if inspected["sha256"] != metadata["catalogImages"][path.name]:
            raise RuntimeError(f"Catalog slot differs from the approved export: {path.name}")
        images.append(inspected)
    scratch = ROOT / ".build/art/app-icon"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix="verify-catalog-") as directory:
        compiled = Path(directory)
        partial_info = compiled / "app-icon-info.plist"
        arguments = ["xcrun", "actool", str(CATALOG), "--compile", str(compiled),
                     "--platform", "macosx", "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
                     "--output-partial-info-plist", str(partial_info), "--output-format", "xml1",
                     "--notices", "--warnings", "--errors"]
        process = subprocess.run(arguments, capture_output=True, check=True)
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
              "verifierSHA256": digest(Path(__file__)),
              "xcode": subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout.strip(),
              "provenanceVerified": True, "source": source, "master": master,
              "catalogMatchesApprovedExport": True, "catalogCompiled": True,
              "compilerWarningsOrErrors": [], "appIconName": "AppIcon", "images": images,
              "scope": "Source/prompt/master/catalog hashes, all ten opaque RGB icon sizes, sRGB profiles, and a clean macOS actool compile. Visual quality and system masking require native review."}
    report_path = scratch / "icon-verification.json"
    report_path.write_text(json.dumps(result, indent=2) + "\n")
    print("Icon check passed: provenance, all ten sizes and approved artwork, sRGB, opacity, and Xcode compilation.")
    print(f"Report: {report_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

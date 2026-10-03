#!/usr/bin/env python3
"""Enforce the dependency boundaries that keep the companion maintainable."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/CompanionKit/Sources/CompanionCore"
RENDERING = ROOT / "Packages/CompanionKit/Sources/CompanionRendering"
for directory, forbidden in ((CORE, r"\b(?:AppKit|QuartzCore|SwiftUI|CoreGraphics|NSScreen|NSWindow|NSEvent|NSView|UserDefaults|Timer|URLSession)\b"),
                              (RENDERING, r"\b(?:CompanionEngine|NSWindow|NSPanel|NSScreen|NSEvent|CADisplayLink|Timer|URLSession)\b")):
    if not directory.is_dir(): sys.exit(f"Required source layer missing: {directory.relative_to(ROOT)}")
    for path in directory.rglob("*.swift"):
        # Documentation may describe a boundary; inspect actual code only.
        code = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", path.read_text())
        if re.search(forbidden, code):
            sys.exit(f"Dependency boundary violation: {path.relative_to(ROOT)}")
for name in ("Packages/SprigletCore", "Sources/Spriglet/Resources/AcornHopper", "Sources/Spriglet/Resources/SproutSample", "Sources/Spriglet/Resources/MossMouse", "Sources/Spriglet/Resources/PetSounds",
             "tools/MallowMotionLab", "tools/CharacterAssets", "tools/CandidateReview",
             "tools/CharacterSampleValidation", "art/source", "art/candidates", "art/sprout"):
    if (ROOT / name).exists(): sys.exit(f"Retired implementation still present: {name}")

for directory in (ROOT / "Sources", ROOT / "Packages", ROOT / "art"):
    for path in directory.rglob("*"):
        if ".build" in path.parts: continue
        if path.suffix.lower() in {".blend", ".fbx", ".obj", ".gltf", ".glb", ".usdz"}:
            sys.exit(f"Retired 3D asset still present: {path.relative_to(ROOT)}")
print("Architecture boundaries passed: platform-free core, snapshot-only rendering, no retired runtime/assets.")

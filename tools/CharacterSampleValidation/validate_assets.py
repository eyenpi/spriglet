#!/usr/bin/env python3
"""Validate exported sample metadata, transparent PNGs, and authored contacts.

Read-only for assets. Only --output is written. No Blender, app, or GPU is run.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys

from png_validation import alpha_measurements, endpoint_difference, read_rgba_png


CLIPS = ("idle", "walkRight", "walkLeft", "pet", "settle")


def checked_json(path):
    def reject_constant(value):
        raise ValueError(f"Nonfinite JSON number: {value}")
    return json.loads(path.read_text(), parse_constant=reject_constant)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def result(name, passed, evidence):
    return {"name": name, "status": "pass" if passed else "fail", "evidence": evidence}


def point(value, keys=("x", "y")):
    values = tuple(value[key] for key in keys)
    if any(isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item) for item in values):
        raise ValueError("Point contains a nonfinite or nonnumeric coordinate")
    return values


def contained_path(directory, name):
    if not isinstance(name, str) or not name.endswith(".png") or "\\" in name or ":" in name:
        raise ValueError(f"Invalid local PNG path: {name!r}")
    parts = name.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ValueError(f"Invalid local PNG path: {name!r}")
    path = (directory / name).resolve()
    if not path.is_relative_to(directory.resolve()):
        raise ValueError(f"PNG resolves outside the asset directory: {name!r}")
    return path


def contact_measurements(manifest, contacts, drift_tolerance=0.05, height_tolerance=1e-5):
    """Tolerances are the animator's declared mathematical invariants.

    Contact pixels use a bottom-left origin. Both coordinate components receive
    the same cumulative root offset as the displayed frame, converted to pixels.
    """
    scales = (manifest["canvasPixels"]["width"] / manifest["displaySizePoints"]["width"],
              manifest["canvasPixels"]["height"] / manifest["displaySizePoints"]["height"])
    rows = []
    offsets_match = True
    heights_match = True
    ground_z = contacts.get("worldGroundZ", 0)
    if not isinstance(ground_z, (int, float)) or not math.isfinite(ground_z):
        raise ValueError("Invalid world ground plane")
    for name in CLIPS:
        frames = manifest["clips"][name]["frames"]
        samples = contacts["clips"][name]["frames"]
        if len(frames) != len(samples):
            raise ValueError(f"Contact/frame count differs for {name}")
        for side in ("left", "right"):
            intervals = []
            active = []
            maximum_height_error = 0.0

            def finish_interval():
                if not active:
                    return
                first = active[0]
                intervals.append({
                    "startFrame": first[0], "endFrame": active[-1][0], "samples": len(active),
                    "maximumScreenDisplacementFromFirstPixels": max(math.dist(first[1], sample[1]) for sample in active),
                    "maximumWorldDisplacementFromFirst": max(math.dist(first[2], sample[2]) for sample in active),
                })
                active.clear()

            for index, (frame, sample) in enumerate(zip(frames, samples)):
                authored_offset = point(frame["rootOffsetPoints"])
                sampled_offset = point(sample["rootOffsetPoints"])
                offsets_match &= all(abs(a - b) <= 1e-9 for a, b in zip(authored_offset, sampled_offset))
                foot = sample["feet"][side]
                canvas = point(foot["canvasPixels"])
                world = point(foot["worldPosition"], ("x", "y", "z"))
                reported_height = foot["groundHeight"]
                if not isinstance(foot["planted"], bool) or not isinstance(reported_height, (int, float)) or not math.isfinite(reported_height):
                    raise ValueError(f"Invalid planted/ground sample: {name}/{index}/{side}")
                # The exporter records marker.z as groundHeight, not the plane.
                heights_match &= abs(world[2] - reported_height) <= 1e-9
                if foot["planted"]:
                    screen = tuple(canvas[axis] + authored_offset[axis] * scales[axis] for axis in range(2))
                    active.append((index, screen, world))
                    maximum_height_error = max(maximum_height_error, abs(world[2] - ground_z))
                else:
                    finish_interval()
            finish_interval()
            measurable = [interval for interval in intervals if interval["samples"] >= 2]
            rows.append({"clip": name, "foot": side,
                         "plantedFrames": sum(interval["samples"] for interval in intervals),
                         "measurablePlantedIntervals": len(measurable),
                         "maximumScreenDisplacementFromFirstPixels": max((interval["maximumScreenDisplacementFromFirstPixels"] for interval in measurable), default=0),
                         "maximumWorldDisplacementFromFirst": max((interval["maximumWorldDisplacementFromFirst"] for interval in measurable), default=0),
                         "maximumGroundHeightError": maximum_height_error})
    walk_rows = [row for row in rows if row["clip"] in {"walkRight", "walkLeft"}]
    coverage = all(row["measurablePlantedIntervals"] > 0 for row in walk_rows)
    maximum_drift = max(row["maximumScreenDisplacementFromFirstPixels"] for row in rows)
    maximum_height = max(row["maximumGroundHeightError"] for row in rows)
    checks = [
        result("contact-offsets-match-playback", offsets_match, "Every sampled offset matches its manifest frame within 1e-9 points."),
        result("reported-contact-height-matches-marker", heights_match, "Exported groundHeight equals the independent worldPosition.z field; errors below use the declared worldGroundZ plane."),
        result("both-walks-have-measured-stance", coverage, "Each foot has at least one contiguous planted interval with two or more samples in both directions."),
        result("planted-screen-stance", coverage and maximum_drift <= drift_tolerance,
               {"maximumDisplacementPixels": maximum_drift, "authoredTolerancePixels": drift_tolerance,
                "pixelToPointScale": list(scales), "method": "Projected sole center plus cumulative window travel; maximum displacement from each planted interval's first sample."}),
        result("planted-ground-height", coverage and maximum_height <= height_tolerance,
               {"maximumAbsoluteErrorAuthoringUnits": maximum_height, "authoredToleranceAuthoringUnits": height_tolerance}),
    ]
    return checks, rows


def hit_test_probes(image):
    """Choose opaque/clear locations independently of the app's 64px mask."""
    alpha = image.pixels[3::4]
    radius = 5

    def patch(x, y):
        return [alpha[row * image.width + column]
                for row in range(y - radius, y + radius + 1)
                for column in range(x - radius, x + radius + 1)]

    candidates = []
    for y in range(14, image.height - 14, 7):
        for x in range(14, image.width - 14, 7):
            if min(patch(x, y)) >= 240 and max(patch(x, image.height - 1 - y)) <= 24:
                candidates.append((abs(x - image.width / 2) + abs(y - image.height / 2), x, y))
    probes = [{"name": "transparent-corner", "normalizedBottomLeft": {"x": 0.01, "y": 0.01}, "expectedHit": False}]
    if candidates:
        _, x, y = min(candidates)
        probes.extend([
            {"name": "opaque-asymmetric-region", "normalizedBottomLeft": {"x": (x + 0.5) / image.width, "y": 1 - (y + 0.5) / image.height}, "expectedHit": True},
            {"name": "transparent-vertical-opposite", "normalizedBottomLeft": {"x": (x + 0.5) / image.width, "y": (y + 0.5) / image.height}, "expectedHit": False},
        ])
    return probes


def endpoint_pose_measurements(contacts, tolerance=1e-5):
    expected_poses = {name: ("neutral", "neutral") for name in CLIPS}
    expected_poses["pet"] = ("neutral", "petted")
    expected_poses["settle"] = ("petted", "neutral")
    references = {"neutral": contacts["clips"]["idle"]["endpoints"]["entry"]["boneMatrices"],
                  "petted": contacts["clips"]["pet"]["endpoints"]["exit"]["boneMatrices"]}
    rows = []
    for name in CLIPS:
        for boundary, expected_pose in zip(("entry", "exit"), expected_poses[name]):
            endpoint = contacts["clips"][name]["endpoints"][boundary]
            matrices = endpoint["boneMatrices"]
            reference = references[expected_pose]
            same_bones = bool(matrices) and set(matrices) == set(reference)
            valid_values = all(len(matrix) == 16 and all(isinstance(value, (int, float))
                                                        and math.isfinite(value) for value in matrix)
                               for matrix in matrices.values())
            maximum_delta = None
            if same_bones and valid_values:
                maximum_delta = max(abs(value - reference[bone][index]) for bone, matrix in matrices.items()
                                    for index, value in enumerate(matrix))
            rows.append({"clip": name, "boundary": boundary, "pose": endpoint["pose"],
                         "expectedPose": expected_pose, "boneCount": len(matrices),
                         "sameBoneInventory": same_bones, "finiteSixteenValueMatrices": valid_values,
                         "maximumMatrixElementDifference": maximum_delta,
                         "passed": same_bones and valid_values and endpoint["pose"] == expected_pose
                                   and maximum_delta is not None and maximum_delta <= tolerance})
    return result("authored-endpoint-pose-signatures", all(row["passed"] for row in rows),
                  {"authoredMatrixElementTolerance": tolerance,
                   "coordinateContract": "Armature-space bone matrices with cumulative travel subtracted; export compensation excluded.",
                   "endpoints": rows})


def validate(manifest_path, contact_path):
    manifest = checked_json(manifest_path)
    directory = manifest_path.parent
    checks = []
    canvas = manifest["canvasPixels"]
    display = manifest["displaySizePoints"]
    expected_size = (canvas["width"], canvas["height"])
    anchor = point(manifest["groundAnchorPixels"])
    format_ok = (manifest["schemaVersion"] == 1 and expected_size == (448, 448)
                 and (display["width"], display["height"]) == (224, 224)
                 and manifest["framesPerSecond"] == 30 and set(manifest["clips"]) == set(CLIPS)
                 and 0 <= anchor[0] <= 448 and 0 <= anchor[1] <= 448)
    checks.append(result("sample-format-and-anchor", format_ok,
                         {"canvasPixels": canvas, "displaySizePoints": display,
                          "framesPerSecond": manifest["framesPerSecond"], "groundAnchorPixels": manifest["groundAnchorPixels"],
                          "coordinateOrigin": "bottom-left"}))
    if not format_ok:
        raise ValueError("Manifest does not match the agreed 448px / 224pt / 30fps sample format")
    references = {manifest["restFrame"], manifest["sleepFrame"]}
    endpoint_files = set(references)
    clip_rows = []
    for name in CLIPS:
        frames = manifest["clips"][name]["frames"]
        if not 1 <= len(frames) <= 600:
            raise ValueError(f"Invalid bounded frame count: {name}")
        offsets = [point(frame["rootOffsetPoints"]) for frame in frames]
        if offsets[0] != (0, 0):
            raise ValueError(f"Clip must begin at zero cumulative offset: {name}")
        references.update(frame["file"] for frame in frames)
        endpoint_files.update((frames[0]["file"], frames[-1]["file"]))
        direction_ok = (all(abs(y) <= 1e-9 for _, y in offsets)
                        and ((name == "walkRight" and offsets[-1][0] > 0)
                             or (name == "walkLeft" and offsets[-1][0] < 0)
                             or (name not in {"walkRight", "walkLeft"} and all(abs(x) <= 1e-9 for x, _ in offsets))))
        clip_rows.append({"clip": name, "frames": len(frames), "durationSeconds": len(frames) / 30,
                          "finalRootOffsetPoints": list(offsets[-1]), "directionAndInPlaceContract": direction_ok})
    checks.append(result("clip-travel-directions", all(row["directionAndInPlaceContract"] for row in clip_rows), clip_rows))

    frame_rows = []
    endpoints = {}
    inventory = hashlib.sha256()
    for index, name in enumerate(sorted(references), 1):
        image = read_rgba_png(contained_path(directory, name), (448, 448))
        alpha = alpha_measurements(image)
        inventory.update(f"{name}\0{image.file_sha256}\n".encode())
        frame_rows.append({"file": name, **alpha})
        if name in endpoint_files:
            endpoints[name] = image
        if index % 30 == 0:
            print(f"Validated {index}/{len(references)} PNG frames", file=sys.stderr, flush=True)
    invisible = [row["file"] for row in frame_rows if row["alphaBoundsTopLeftPixels"] is None]
    opaque = [row["file"] for row in frame_rows if row["transparentPixels"] == 0]
    clipped = [row["file"] for row in frame_rows if row["maximumBorderAlpha"] > 0]
    checks.append(result("png-integrity-and-alpha", not invisible and not opaque,
                         {"uniquePNGsDecoded": len(frame_rows), "allChunkCRCsAndScanlinesValid": True,
                          "emptyFrames": invisible, "framesWithoutTransparency": opaque,
                          "framesWithPartialAlpha": sum(row["partialAlphaPixels"] > 0 for row in frame_rows),
                          "frameInventorySHA256": inventory.hexdigest()}))
    checks.append(result("transparent-canvas-perimeter", not clipped,
                         {"framesTouchingAnyCanvasEdge": clipped,
                          "criterion": "All outermost RGBA alpha samples are zero; this detects crop contact, not halo quality."}))

    def entry(name):
        return manifest["clips"][name]["frames"][0]["file"]

    def exit_frame(name):
        return manifest["clips"][name]["frames"][-1]["file"]

    transitions = [("rest→idle", manifest["restFrame"], entry("idle")),
                   ("idle→walkRight", exit_frame("idle"), entry("walkRight")),
                   ("idle→walkLeft", exit_frame("idle"), entry("walkLeft")),
                   ("walkRight→pet", exit_frame("walkRight"), entry("pet")),
                   ("walkLeft→pet", exit_frame("walkLeft"), entry("pet")),
                   ("pet→settle", exit_frame("pet"), entry("settle")),
                   ("settle→rest", exit_frame("settle"), manifest["restFrame"])]
    transition_rows = [{"transition": name, "from": first, "to": second,
                        **endpoint_difference(endpoints[first], endpoints[second])}
                       for name, first, second in transitions]

    contact_rows = []
    if contact_path and contact_path.is_file():
        contacts = checked_json(contact_path)
        contact_checks, contact_rows = contact_measurements(manifest, contacts)
        checks.extend(contact_checks)
        if all("endpoints" in contacts["clips"][name] for name in CLIPS):
            checks.append(endpoint_pose_measurements(contacts))
        else:
            checks.append({"name": "authored-endpoint-pose-signatures", "status": "pending",
                           "evidence": "Rig endpoint matrices were not exported; pixel measurements alone do not establish pose continuity."})
    else:
        checks.append({"name": "authored-contact-evidence", "status": "pending",
                       "evidence": "No contact-samples.json was supplied; grounded stance is not claimed."})
    return {
        "kind": "sprout-character-sample-assets", "verifiedAtUTC": datetime.now(timezone.utc).isoformat(),
        "manifest": str(manifest_path), "manifestSHA256": digest(manifest_path),
        "contactSamples": str(contact_path) if contact_path else None,
        "contactSamplesSHA256": digest(contact_path) if contact_path and contact_path.is_file() else None,
        "checks": checks, "clipSummary": clip_rows, "contactSummary": contact_rows,
        "hitTestProbes": hit_test_probes(endpoints[manifest["restFrame"]]),
        "endpointPixelMeasurements": transition_rows,
        "limitations": [
            "Numerical file, alpha, projection, and authored-marker checks do not establish visual likeness, whole-foot contact, rig deformation quality, or attractive movement.",
            "PNG color values are unassociated alpha by the format contract. Halo quality and color-managed compositing require actual light/dark display review.",
            "The 224-point native size, synchronized window movement, cancellation, and stopped resource use are separate integration checks.",
            "No GPU, battery, energy, or long-session performance claim is made by this asset reader.",
        ],
        "sources": ["https://www.w3.org/TR/png-3/"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--contacts", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = validate(args.manifest.resolve(), args.contacts.resolve() if args.contacts else None)
    except (ValueError, KeyError, TypeError, OSError) as error:
        report = {"kind": "sprout-character-sample-assets", "verifiedAtUTC": datetime.now(timezone.utc).isoformat(),
                  "checks": [{"name": "asset-readback", "status": "fail", "evidence": str(error)}]}
    failures = sum(check["status"] == "fail" for check in report["checks"])
    pending = sum(check["status"] == "pending" for check in report["checks"])
    report["status"] = "failed" if failures else ("incomplete" if pending else "passed-numerical-checks")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    print(json.dumps({"status": report["status"], "checks": len(report["checks"]),
                      "failed": failures, "pending": pending, "output": str(args.output)}))
    return 1 if failures else (2 if pending else 0)


if __name__ == "__main__":
    raise SystemExit(main())

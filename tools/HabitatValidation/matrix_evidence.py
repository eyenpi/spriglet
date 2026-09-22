#!/usr/bin/env python3
"""Capture and verify privacy-preserving Milestone 5 physical evidence.

This tool deliberately does not change Dock, menu-bar, Stage Manager, Space, or
display settings. It combines reports produced by the signed native harnesses
with a human attestation and hashes of user-supplied visual evidence.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


SCHEMA_VERSION = 1
ROOT = pathlib.Path(__file__).resolve().parents[2]

COMMON_CHECKS = (
    "configuredStateMatchesCase",
    "upperHabitatStaysBelowProtectedUI",
    "mouseAndMenuInputRemainAvailable",
    "foregroundFocusRemainsUnchanged",
    "portalSequenceHasNoBlinkJumpOrBlankFrame",
    "returnAndSettlementAreCorrect",
)
TRANSITION_CHECKS = ("systemTransitionReconcilesSafely",)
ART_CHECKS = (
    "allSevenClipsReviewed",
    "sizes72_96_120AreLegible",
    "lightDarkBusyBackgroundsAreClean",
    "noFringeBlurDoubleImageOrShimmer",
    "pawsAndLedgeStayVisuallyAttached",
    "motionHasAnticipationWeightAndSettle",
)


@dataclass(frozen=True)
class Scenario:
    description: str
    geometry_requirement: str | None = None
    transition: bool = False
    art: bool = False
    minimum_artifacts: int = 1

    @property
    def required_checks(self) -> tuple[str, ...]:
        if self.art:
            return ART_CHECKS
        return COMMON_CHECKS + (TRANSITION_CHECKS if self.transition else ())


SCENARIOS: dict[str, Scenario] = {
    "ordinary-menu-shown": Scenario("Ordinary display with the menu bar shown", "ordinary"),
    "ordinary-menu-auto-hidden": Scenario("Ordinary display with menu-bar auto-hide active", "ordinary"),
    "ordinary-full-screen": Scenario("Ordinary display while another app is full screen", "ordinary", transition=True),
    "ordinary-stage-manager": Scenario("Ordinary display with Stage Manager active", "ordinary", transition=True),
    "notched-menu-shown": Scenario("Notched display with the menu bar shown", "notched"),
    "notched-menu-auto-hidden": Scenario("Notched display with menu-bar auto-hide active", "notched"),
    "notched-full-screen": Scenario("Notched display while another app is full screen", "notched", transition=True),
    "notched-stage-manager": Scenario("Notched display with Stage Manager active", "notched", transition=True),
    "mixed-scale-multi-display": Scenario("At least two displays with different backing scales", "mixed-scale"),
    "display-hot-plug": Scenario("A display is disconnected and reconnected during preview", "multi-display", transition=True),
    "space-transition": Scenario("The foreground Space changes during preview", transition=True),
    "dock-left": Scenario("Visible Dock on the left edge", "dock-left"),
    "dock-right": Scenario("Visible Dock on the right edge", "dock-right"),
    "dock-bottom": Scenario("Visible Dock on the bottom edge", "dock-bottom"),
    "dock-auto-hidden": Scenario("Dock auto-hide active", transition=True),
    "art-native-size-board": Scenario(
        "All habitat clips on 72-, 96-, and 120-point light/dark/busy boards",
        art=True,
        minimum_artifacts=3,
    ),
}


class EvidenceError(ValueError):
    pass


def load_json_report(path: pathlib.Path) -> dict[str, Any]:
    """Read JSON directly or find the final JSON object after build output."""
    text = path.read_text(encoding="utf-8")
    try:
        value = json.loads(text)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    starts = [index for index, character in enumerate(text) if character == "{"]
    for start in reversed(starts):
        try:
            value = json.loads(text[start:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise EvidenceError(f"No JSON report found in {path}")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_hashed_file(
    source: pathlib.Path,
    destination: pathlib.Path,
    evidence_root: pathlib.Path,
) -> dict[str, Any]:
    if not source.is_file() or source.stat().st_size == 0:
        raise EvidenceError(f"Evidence file is missing or empty: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.resolve() != destination.resolve():
        shutil.copy2(source, destination)
    return {
        "path": destination.relative_to(evidence_root).as_posix(),
        "sha256": sha256(destination),
        "bytes": destination.stat().st_size,
    }


def write_hashed_json(
    value: dict[str, Any],
    destination: pathlib.Path,
    evidence_root: pathlib.Path,
) -> dict[str, Any]:
    """Persist only the anonymized native payload, without build-machine paths."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return {
        "path": destination.relative_to(evidence_root).as_posix(),
        "sha256": sha256(destination),
        "bytes": destination.stat().st_size,
    }


def repository_state() -> dict[str, Any]:
    def git(*arguments: str) -> str:
        return subprocess.check_output(
            ["git", *arguments], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()

    return {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("branch", "--show-current"),
        "sourceTreeClean": git("status", "--porcelain") == "",
    }


def validate_attestation(value: dict[str, Any], case_id: str, scenario: Scenario) -> None:
    if value.get("schemaVersion") != SCHEMA_VERSION:
        raise EvidenceError("Attestation schemaVersion must be 1")
    if value.get("caseID") != case_id:
        raise EvidenceError(f"Attestation caseID must be {case_id}")
    reviewer = value.get("reviewer")
    if not isinstance(reviewer, str) or not reviewer.strip():
        raise EvidenceError("Attestation reviewer must be a non-empty label")
    checks = value.get("checks")
    if not isinstance(checks, dict):
        raise EvidenceError("Attestation checks must be an object")
    missing = [name for name in scenario.required_checks if checks.get(name) is not True]
    if missing:
        raise EvidenceError(f"Manual checks are not attested true: {', '.join(missing)}")


def validate_geometry_report(report: dict[str, Any], requirement: str | None) -> None:
    if report.get("safeAreaGeometryMatches") is not True:
        raise EvidenceError("Native geometry did not preserve the current AppKit snapshot")
    if report.get("topPortalBoundsStayVisible") is not True:
        raise EvidenceError("Native geometry allowed a top portal outside visible bounds")
    if report.get("ledgeCapabilitiesCannotSelectWalls") is not True:
        raise EvidenceError("Ordinary ledge capabilities activated a wall route")
    if report.get("displayIdentifiersEmitted") is not False:
        raise EvidenceError("Geometry report emitted display identifiers")
    if report.get("safeAreaCompatibilityModeChanged") is not False:
        raise EvidenceError("Geometry validation changed safe-area compatibility mode")
    coverage = report.get("currentDeviceCoverage")
    displays = report.get("displays")
    if not isinstance(coverage, dict) or not isinstance(displays, list) or not displays:
        raise EvidenceError("Geometry report lacks current-device coverage")
    predicates = {
        "ordinary": coverage.get("hasOrdinaryDisplay") is True,
        "notched": coverage.get("hasNotchedDisplay") is True,
        "multi-display": coverage.get("hasMultipleDisplays") is True,
        "mixed-scale": coverage.get("hasMultipleDisplays") is True
        and coverage.get("hasMixedBackingScale") is True,
        "dock-left": any(_inset(display, "left") > 0 for display in displays),
        "dock-right": any(_inset(display, "right") > 0 for display in displays),
        "dock-bottom": any(_inset(display, "bottom") > 0 for display in displays),
    }
    if requirement is not None and predicates.get(requirement) is not True:
        raise EvidenceError(f"Current geometry does not establish the {requirement} prerequisite")


def _inset(display: Any, edge: str) -> float:
    try:
        value = display["inferredReservedInsets"][edge]
        return float(value)
    except (KeyError, TypeError, ValueError):
        return -1


def validate_habitat_report(report: dict[str, Any]) -> None:
    required_true = (
        "automaticGateDefaultedOff",
        "menuSafeUpperPlacement",
        "clickTransparentVisit",
        "focusStayedPassive",
        "actualFloorOriginRestored",
        "savedHomePreserved",
        "clickThroughRestored",
        "frameClockStopped",
        "allDeclaredInterruptionMarkersObserved",
        "preRelocationCancellationCompleted",
        "visibleTopologyChangeRecovered",
        "allInjectedEffectFailuresRecovered",
        "recoveryStopAborted",
    )
    failed = [name for name in required_true if report.get(name) is not True]
    if failed:
        raise EvidenceError(f"Native habitat checks failed or are absent: {', '.join(failed)}")
    if report.get("semanticHiddenEndpoints") != 4:
        raise EvidenceError("Native habitat traversal did not use exactly four hidden endpoints")
    if report.get("preRelocationCancellationRelocationDelta") != 0:
        raise EvidenceError("Cancellation during floor exit relocated the habitat host")
    if report.get("preRelocationCancellationHiddenEndpoints") != 1:
        raise EvidenceError("Cancellation during floor exit did not reverse at one hidden endpoint")
    if report.get("declaredInterruptionMarkers") != report.get("observedInterruptionMarkers"):
        raise EvidenceError("Native habitat interruption-marker coverage is incomplete")
    if report.get("maximumBufferedFrames", sys.maxsize) > report.get("configuredFrameBufferLimit", -1):
        raise EvidenceError("Native habitat playback exceeded its frame-buffer limit")
    if report.get("bufferUnderruns") != 0:
        raise EvidenceError("Native habitat playback reported a frame-buffer underrun")
    if report.get("injectedEffectFailureCases") != 7:
        raise EvidenceError("Native habitat effect-failure coverage is incomplete")
    for field in (
        "settledSubmittedFrameDelta",
        "settledDisplayLinkCallbackDelta",
        "settledWindowMovementDelta",
    ):
        if report.get(field) != 0:
            raise EvidenceError(f"Native habitat resource settlement failed: {field}")


def make_template(case_id: str) -> dict[str, Any]:
    scenario = scenario_for(case_id)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "caseID": case_id,
        "reviewer": "",
        "observedState": scenario.description,
        "checks": {name: False for name in scenario.required_checks},
        "notes": "",
    }


def capture(
    case_id: str,
    geometry_path: pathlib.Path,
    habitat_path: pathlib.Path,
    attestation_path: pathlib.Path,
    artifact_paths: list[pathlib.Path],
    output_directory: pathlib.Path,
    allow_dirty: bool,
) -> pathlib.Path:
    scenario = scenario_for(case_id)
    geometry = load_json_report(geometry_path)
    habitat = load_json_report(habitat_path)
    attestation = load_json_report(attestation_path)
    validate_geometry_report(geometry, scenario.geometry_requirement)
    validate_habitat_report(habitat)
    validate_attestation(attestation, case_id, scenario)
    if len(artifact_paths) < scenario.minimum_artifacts:
        raise EvidenceError(
            f"{case_id} requires at least {scenario.minimum_artifacts} visual evidence file(s)"
        )
    source = repository_state()
    if not source["sourceTreeClean"] and not allow_dirty:
        raise EvidenceError("Commit the exact source before capturing physical evidence")

    output_directory.mkdir(parents=True, exist_ok=True)
    report_directory = output_directory / "reports" / case_id
    geometry_record = write_hashed_json(
        geometry, report_directory / "geometry.json", output_directory
    )
    habitat_record = write_hashed_json(
        habitat, report_directory / "habitat.json", output_directory
    )
    artifact_directory = output_directory / "artifacts" / case_id
    artifact_directory.mkdir(parents=True, exist_ok=True)
    artifacts = []
    for index, source_path in enumerate(artifact_paths, start=1):
        safe_name = "".join(
            character if character.isalnum() or character in ".-_" else "_"
            for character in source_path.name
        )
        destination = artifact_directory / f"{index:02d}-{safe_name}"
        artifacts.append(copy_hashed_file(source_path, destination, output_directory))

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "spriglet-habitat-physical-evidence",
        "caseID": case_id,
        "description": scenario.description,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": source,
        "attestation": attestation,
        "automatedEvidence": {
            "geometryReport": geometry_record,
            "habitatReport": habitat_record,
            "geometry": geometry,
            "habitat": habitat,
        },
        "artifacts": artifacts,
    }
    output = output_directory / f"{case_id}.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def verify_directory(directory: pathlib.Path) -> dict[str, Any]:
    evidence: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    for path in sorted(directory.glob("*.json")):
        try:
            value = load_json_report(path)
            case_id = value.get("caseID")
            if value.get("kind") != "spriglet-habitat-physical-evidence" or case_id not in SCENARIOS:
                continue
            if case_id in evidence:
                raise EvidenceError(f"Duplicate evidence for {case_id}")
            validate_evidence(value, directory)
            evidence[case_id] = value
        except (EvidenceError, OSError) as error:
            errors.append(f"{path.name}: {error}")

    missing = sorted(set(SCENARIOS) - set(evidence))
    commits = sorted({item["source"]["commit"] for item in evidence.values()})
    if len(commits) > 1:
        errors.append("Evidence was captured from more than one source commit")
    complete = not missing and not errors
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "spriglet-habitat-matrix-summary",
        "complete": complete,
        "physicalHardwareMatrixComplete": complete,
        "requiredCases": len(SCENARIOS),
        "verifiedCases": len(evidence),
        "missingCases": missing,
        "errors": errors,
        "sourceCommit": commits[0] if len(commits) == 1 else None,
        "currentDeviceCoverage": aggregate_coverage(evidence.values()),
    }


def validate_evidence(value: dict[str, Any], directory: pathlib.Path) -> None:
    if value.get("schemaVersion") != SCHEMA_VERSION:
        raise EvidenceError("Unsupported evidence schema")
    case_id = value.get("caseID")
    scenario = scenario_for(case_id)
    source = value.get("source")
    if not isinstance(source, dict) or source.get("sourceTreeClean") is not True:
        raise EvidenceError("Evidence source tree was not clean")
    commit = source.get("commit")
    if not isinstance(commit, str) or len(commit) != 40:
        raise EvidenceError("Evidence lacks a full source commit")
    automated = value.get("automatedEvidence")
    if not isinstance(automated, dict):
        raise EvidenceError("Automated evidence is missing")
    validate_geometry_report(automated.get("geometry", {}), scenario.geometry_requirement)
    validate_habitat_report(automated.get("habitat", {}))
    validate_hashed_file(automated.get("geometryReport"), directory)
    validate_hashed_file(automated.get("habitatReport"), directory)
    validate_attestation(value.get("attestation", {}), case_id, scenario)
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) < scenario.minimum_artifacts:
        raise EvidenceError("Visual evidence is incomplete")
    for artifact in artifacts:
        validate_hashed_file(artifact, directory)


def validate_hashed_file(value: Any, directory: pathlib.Path) -> None:
    relative = value.get("path") if isinstance(value, dict) else None
    if not isinstance(relative, str) or not relative:
        raise EvidenceError("Evidence path is malformed")
    root = directory.resolve()
    path = (root / relative).resolve()
    if path != root and root not in path.parents:
        raise EvidenceError(f"Evidence path escapes its directory: {relative}")
    if not path.is_file() or path.stat().st_size == 0 or sha256(path) != value.get("sha256"):
        raise EvidenceError(f"Evidence is missing or changed: {relative}")


def aggregate_coverage(values: Any) -> dict[str, bool]:
    coverage = {
        "hasNotchedDisplay": False,
        "hasOrdinaryDisplay": False,
        "hasMultipleDisplays": False,
        "hasMixedBackingScale": False,
    }
    for value in values:
        observed = value["automatedEvidence"]["geometry"].get("currentDeviceCoverage", {})
        for key in coverage:
            coverage[key] = coverage[key] or observed.get(key) is True
    return coverage


def scenario_for(case_id: Any) -> Scenario:
    if not isinstance(case_id, str) or case_id not in SCENARIOS:
        raise EvidenceError(f"Unknown matrix case: {case_id}")
    return SCENARIOS[case_id]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List every required physical case")
    template = commands.add_parser("template", help="Write a false-by-default attestation template")
    template.add_argument("--case", required=True, choices=SCENARIOS)
    template.add_argument("--output", required=True, type=pathlib.Path)
    capture_parser = commands.add_parser("capture", help="Combine native reports and reviewed visual evidence")
    capture_parser.add_argument("--case", required=True, choices=SCENARIOS)
    capture_parser.add_argument("--geometry-report", required=True, type=pathlib.Path)
    capture_parser.add_argument("--habitat-report", required=True, type=pathlib.Path)
    capture_parser.add_argument("--attestation", required=True, type=pathlib.Path)
    capture_parser.add_argument("--artifact", action="append", default=[], type=pathlib.Path)
    capture_parser.add_argument("--output-directory", required=True, type=pathlib.Path)
    capture_parser.add_argument("--allow-dirty", action="store_true", help=argparse.SUPPRESS)
    verify = commands.add_parser("verify", help="Verify completeness, hashes, and a single clean source commit")
    verify.add_argument("--directory", required=True, type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "list":
            for case_id, scenario in SCENARIOS.items():
                print(f"{case_id}\t{scenario.description}")
            return 0
        if arguments.command == "template":
            arguments.output.parent.mkdir(parents=True, exist_ok=True)
            arguments.output.write_text(
                json.dumps(make_template(arguments.case), indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            print(arguments.output)
            return 0
        if arguments.command == "capture":
            output = capture(
                arguments.case,
                arguments.geometry_report,
                arguments.habitat_report,
                arguments.attestation,
                arguments.artifact,
                arguments.output_directory,
                arguments.allow_dirty,
            )
            print(output)
            return 0
        summary = verify_directory(arguments.directory)
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0 if summary["complete"] else 1
    except (EvidenceError, OSError, subprocess.CalledProcessError) as error:
        print(f"Habitat matrix evidence failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

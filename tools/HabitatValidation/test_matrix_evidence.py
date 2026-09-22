import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("matrix_evidence.py")
SPEC = importlib.util.spec_from_file_location("matrix_evidence", MODULE_PATH)
matrix = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = matrix
SPEC.loader.exec_module(matrix)


class MatrixEvidenceTests(unittest.TestCase):
    def test_templates_fail_closed(self):
        template = matrix.make_template("notched-menu-shown")
        self.assertEqual(template["caseID"], "notched-menu-shown")
        self.assertTrue(template["checks"])
        self.assertFalse(any(template["checks"].values()))

    def test_report_parser_ignores_build_preamble(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "native.log"
            path.write_text("Built signed app\n{\"passed\": true}\n", encoding="utf-8")
            self.assertEqual(matrix.load_json_report(path), {"passed": True})

    def test_incomplete_matrix_lists_every_missing_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            summary = matrix.verify_directory(pathlib.Path(temporary))
            self.assertFalse(summary["complete"])
            self.assertEqual(summary["verifiedCases"], 0)
            self.assertEqual(set(summary["missingCases"]), set(matrix.SCENARIOS))

    def test_hashed_evidence_cannot_escape_the_matrix_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            directory = root / "matrix"
            directory.mkdir()
            outside = root / "outside.txt"
            outside.write_text("private", encoding="utf-8")
            record = {
                "path": "../outside.txt",
                "sha256": matrix.sha256(outside),
                "bytes": outside.stat().st_size,
            }
            with self.assertRaisesRegex(matrix.EvidenceError, "escapes"):
                matrix.validate_hashed_file(record, directory)

    def test_habitat_report_requires_visible_topology_recovery(self):
        report = self._habitat_report()
        report.pop("visibleTopologyChangeRecovered")
        with self.assertRaisesRegex(
            matrix.EvidenceError, "visibleTopologyChangeRecovered"
        ):
            matrix.validate_habitat_report(report)

    def test_complete_matrix_requires_intact_artifacts_and_one_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            for case_id, scenario in matrix.SCENARIOS.items():
                self._write_evidence(directory, case_id, scenario)
            summary = matrix.verify_directory(directory)
            self.assertTrue(summary["complete"], summary)
            self.assertTrue(summary["physicalHardwareMatrixComplete"])
            self.assertEqual(summary["verifiedCases"], len(matrix.SCENARIOS))

            artifact = next((directory / "artifacts").rglob("*.txt"))
            artifact.write_text("changed", encoding="utf-8")
            changed = matrix.verify_directory(directory)
            self.assertFalse(changed["complete"])
            self.assertTrue(any("missing or changed" in error for error in changed["errors"]))

    def _write_evidence(self, directory, case_id, scenario):
        artifacts = []
        artifact_directory = directory / "artifacts" / case_id
        artifact_directory.mkdir(parents=True, exist_ok=True)
        for index in range(scenario.minimum_artifacts):
            path = artifact_directory / f"{index}.txt"
            path.write_text(f"{case_id}-{index}", encoding="utf-8")
            artifacts.append({
                "path": path.relative_to(directory).as_posix(),
                "sha256": matrix.sha256(path),
                "bytes": path.stat().st_size,
            })
        value = {
            "schemaVersion": matrix.SCHEMA_VERSION,
            "kind": "spriglet-habitat-physical-evidence",
            "caseID": case_id,
            "source": {
                "commit": "a" * 40,
                "branch": "test",
                "sourceTreeClean": True,
            },
            "attestation": {
                "schemaVersion": matrix.SCHEMA_VERSION,
                "caseID": case_id,
                "reviewer": "tester",
                "checks": {name: True for name in scenario.required_checks},
            },
            "automatedEvidence": {
                "geometryReport": self._write_report_file(
                    directory, case_id, "geometry.log", self._geometry_report()
                ),
                "habitatReport": self._write_report_file(
                    directory, case_id, "habitat.log", self._habitat_report()
                ),
                "geometry": self._geometry_report(),
                "habitat": self._habitat_report(),
            },
            "artifacts": artifacts,
        }
        (directory / f"{case_id}.json").write_text(
            json.dumps(value), encoding="utf-8"
        )

    @staticmethod
    def _write_report_file(directory, case_id, name, value):
        path = directory / "reports" / case_id / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return {
            "path": path.relative_to(directory).as_posix(),
            "sha256": matrix.sha256(path),
            "bytes": path.stat().st_size,
        }

    @staticmethod
    def _geometry_report():
        return {
            "safeAreaGeometryMatches": True,
            "topPortalBoundsStayVisible": True,
            "ledgeCapabilitiesCannotSelectWalls": True,
            "displayIdentifiersEmitted": False,
            "safeAreaCompatibilityModeChanged": False,
            "currentDeviceCoverage": {
                "hasNotchedDisplay": True,
                "hasOrdinaryDisplay": True,
                "hasMultipleDisplays": True,
                "hasMixedBackingScale": True,
            },
            "displays": [
                {"inferredReservedInsets": {"top": 24, "left": 80, "bottom": 0, "right": 0}},
                {"inferredReservedInsets": {"top": 24, "left": 0, "bottom": 80, "right": 0}},
                {"inferredReservedInsets": {"top": 24, "left": 0, "bottom": 0, "right": 80}},
                {"inferredReservedInsets": {"top": 0, "left": 0, "bottom": 0, "right": 0}},
            ],
        }

    @staticmethod
    def _habitat_report():
        return {
            "automaticGateDefaultedOff": True,
            "menuSafeUpperPlacement": True,
            "clickTransparentVisit": True,
            "focusStayedPassive": True,
            "actualFloorOriginRestored": True,
            "savedHomePreserved": True,
            "clickThroughRestored": True,
            "frameClockStopped": True,
            "allDeclaredInterruptionMarkersObserved": True,
            "preRelocationCancellationCompleted": True,
            "visibleTopologyChangeRecovered": True,
            "allInjectedEffectFailuresRecovered": True,
            "recoveryStopAborted": True,
            "semanticHiddenEndpoints": 4,
            "preRelocationCancellationRelocationDelta": 0,
            "preRelocationCancellationHiddenEndpoints": 1,
            "declaredInterruptionMarkers": 25,
            "observedInterruptionMarkers": 25,
            "maximumBufferedFrames": 12,
            "configuredFrameBufferLimit": 12,
            "bufferUnderruns": 0,
            "injectedEffectFailureCases": 7,
            "settledSubmittedFrameDelta": 0,
            "settledDisplayLinkCallbackDelta": 0,
            "settledWindowMovementDelta": 0,
        }


if __name__ == "__main__":
    unittest.main()

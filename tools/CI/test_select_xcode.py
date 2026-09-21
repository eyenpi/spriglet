import plistlib
import re
import tempfile
import unittest
from pathlib import Path

from select_xcode import (PINS, ROOT, find_xcode, load_pins, mismatches, parse_swift, parse_xcodebuild,
                          version_matches)

WORKFLOW = ROOT / ".github/workflows/pr-ci.yml"
CODEQL_MAXIMUM_SWIFT = (6, 3)


class VersionTests(unittest.TestCase):
    def test_pin_names_a_release_line(self):
        self.assertTrue(version_matches("27.0", "27.0"))
        self.assertTrue(version_matches("27.0", "27.0.1"))
        self.assertTrue(version_matches("6.3", "6.3.3"))
        for observed in ("27.1", "26.6", "27", "270.0", "27.01"):
            with self.subTest(observed=observed):
                self.assertFalse(version_matches("27.0", observed))
        self.assertFalse(version_matches("6.3", "6.4"))

    def test_parses_current_tool_output(self):
        self.assertEqual(parse_xcodebuild("Xcode 27.0\nBuild version 27A266a"), ("27.0", "27A266a"))
        self.assertEqual(parse_xcodebuild("Xcode 26.6\nBuild version 17F113\n"), ("26.6", "17F113"))
        self.assertEqual(parse_swift("swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1)"), "6.4")
        self.assertEqual(parse_swift("Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"), "6.3.3")

    def test_unrecognized_output_is_an_error(self):
        with self.assertRaises(ValueError):
            parse_xcodebuild("xcode-select: error: tool 'xcodebuild' requires Xcode")
        with self.assertRaises(ValueError):
            parse_swift("no swift here")

    def test_mismatches_name_each_drifted_field(self):
        pin = {"xcode": "27.0", "macOSSDK": "27.0", "swift": "6.4"}
        observed = {"xcode": "26.6", "macOSSDK": "26.5", "swift": "6.4"}
        self.assertEqual(mismatches(pin, observed), ["xcode: pinned 27.0, found 26.6", "macOSSDK: pinned 27.0, found 26.5"])
        self.assertEqual(mismatches(pin, {"xcode": "27.0.1", "macOSSDK": "27.0", "swift": "6.4.1"}), [])


class DiscoveryTests(unittest.TestCase):
    def make_xcode(self, applications, name, version):
        contents = applications / name / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": version}))

    def test_prefers_the_runner_images_versioned_path(self):
        with tempfile.TemporaryDirectory() as directory:
            applications = Path(directory)
            self.make_xcode(applications, "Xcode.app", "27.0")
            self.make_xcode(applications, "Xcode_27.0.app", "27.0")
            self.assertEqual(find_xcode("27.0", applications).name, "Xcode_27.0.app")

    def test_falls_back_to_any_installed_xcode_of_that_version(self):
        with tempfile.TemporaryDirectory() as directory:
            applications = Path(directory)
            self.make_xcode(applications, "Xcode_26.6.app", "26.6")
            self.make_xcode(applications, "Xcode.app", "27.0")
            self.assertEqual(find_xcode("27.0", applications).name, "Xcode.app")

    def test_a_misnamed_bundle_is_not_trusted(self):
        with tempfile.TemporaryDirectory() as directory:
            applications = Path(directory)
            self.make_xcode(applications, "Xcode_27.0.app", "26.6")
            with self.assertRaisesRegex(LookupError, "Xcode 27.0 is not installed"):
                find_xcode("27.0", applications)


class PinConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.pins = load_pins(PINS)
        self.workflow = WORKFLOW.read_text()

    def job(self, name):
        match = re.search(rf"^  {name}:\n(.*?)(?=^  [a-z][\w-]*:\n|\Z)", self.workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, f"job {name} not found")
        return match.group(1)

    def test_pins_define_the_build_and_codeql_toolchains(self):
        self.assertEqual(set(self.pins), {"build", "codeql"})

    def test_build_job_runs_on_and_selects_the_build_pin(self):
        job = self.job("macos")
        self.assertIn(f"runs-on: {self.pins['build']['runner']}", job)
        self.assertIn("python3 tools/CI/select_xcode.py build", job)

    def test_codeql_swift_runs_on_and_selects_the_codeql_pin(self):
        job = self.job("codeql")
        self.assertRegex(job, rf"language: swift\n\s+runner: {re.escape(self.pins['codeql']['runner'])}")
        self.assertIn("python3 tools/CI/select_xcode.py codeql", job)

    def test_codeql_toolchain_stays_within_codeqls_swift_support(self):
        major, minor = (int(part) for part in self.pins["codeql"]["swift"].split(".")[:2])
        self.assertLessEqual((major, minor), CODEQL_MAXIMUM_SWIFT,
                             "CodeQL analyzes Swift 5.4 through 6.3; keep the codeql pin on an Xcode 26 toolchain")

    def test_build_toolchain_compiles_the_modern_error_mapping(self):
        self.assertGreaterEqual(int(self.pins["build"]["macOSSDK"].split(".")[0]), 27)
        self.assertIn("--require-modern-error-mapping", self.job("macos"))


if __name__ == "__main__":
    unittest.main()

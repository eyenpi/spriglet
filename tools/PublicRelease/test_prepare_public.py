"""Synthetic regression fixtures; no real artwork, app launches, or network."""

import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zlib


SPEC = importlib.util.spec_from_file_location("prepare_public", Path(__file__).with_name("prepare-public.py"))
PUBLIC = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PUBLIC
SPEC.loader.exec_module(PUBLIC)
PRIVATE_HOME = "/" + "Users/" + "example-person"


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png(file_value):
    pixels = bytes((128, 60, 20, 255, 12, 200, 40, 0))
    result = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 6, 0, 0, 0))
    result += chunk(b"sRGB", b"\0") + chunk(b"gAMA", struct.pack(">I", 45455))
    result += chunk(b"tEXt", b"File\0" + file_value) + chunk(b"tEXt", b"Author\0Public artist")
    result += chunk(b"IDAT", zlib.compress(b"\0" + pixels)) + chunk(b"IEND", b"")
    return result, pixels


class PNGPrivacyTests(unittest.TestCase):
    def test_private_file_removal_preserves_pixels_profiles_and_other_text(self):
        original, pixels = png((PRIVATE_HOME + "/work/render.blend").encode())
        clean, proof = PUBLIC.strip_png_file(original)
        self.assertNotIn(PRIVATE_HOME.encode(), clean)
        self.assertTrue(proof["idatUnchanged"])
        before = [(kind, payload) for kind, payload, _ in PUBLIC.png_chunks(original) if kind != b"tEXt"]
        after = [(kind, payload) for kind, payload, _ in PUBLIC.png_chunks(clean) if kind != b"tEXt"]
        self.assertEqual(before, after)
        self.assertIn((b"tEXt", b"Author\0Public artist"), [(k, p) for k, p, _ in PUBLIC.png_chunks(clean)])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clean.png"
            path.write_bytes(clean)
            self.assertEqual(PUBLIC.load_png_reader()(path).pixels, pixels)

    def test_relative_provenance_is_not_removed(self):
        original, _ = png(b"art/scene.blend")
        clean, proof = PUBLIC.strip_png_file(original)
        self.assertEqual(clean, original)
        self.assertIsNone(proof)

    def test_corrupt_crc_is_rejected(self):
        original, _ = png(b"public.blend")
        corrupt = bytearray(original)
        corrupt[-1] ^= 1
        with self.assertRaises(PUBLIC.PublicationError):
            PUBLIC.strip_png_file(bytes(corrupt))

    def test_local_path_in_unapproved_png_field_blocks_audit(self):
        original, _ = png(b"public.blend")
        original = original[:-12] + chunk(b"tEXt", b"Comment\0" + PRIVATE_HOME.encode()) + original[-12:]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "image.png").write_bytes(original)
            report = PUBLIC.audit_public(root, set(), None)
            self.assertFalse(report["passed"])
            self.assertEqual(report["findings"][0]["file"], "image.png")


class TextPrivacyTests(unittest.TestCase):
    def test_markdown_checkout_link_becomes_portable(self):
        root = Path(PRIVATE_HOME) / "project"
        text = "[Image](" + str(root / "art/image.png") + ")"
        self.assertEqual(PUBLIC.scrub_text(text, "docs/review.md", root, set()), "[Image](../art/image.png)")

    def test_private_note_and_generation_locations_are_labeled(self):
        text = "`" + PRIVATE_HOME + "/Library/Mobile Documents/vault/Private Draft.md`\n"
        text += "`" + PRIVATE_HOME + "/.codex/generated_images/private-session/output.png`"
        clean = PUBLIC.scrub_text(text, "docs/provenance.md", Path(PRIVATE_HOME) / "project", set())
        self.assertIn("<private-note>", clean)
        self.assertNotIn("Private Draft", clean)
        self.assertNotIn("private-session", clean)
        self.assertNotIn(PRIVATE_HOME, clean)

    def test_json_keeps_measured_values_and_historical_hashes(self):
        original_hash = "b" * 64
        text = json.dumps({"passed": True, "cpu": .1, "artifactSHA256": original_hash,
                           "path": PRIVATE_HOME + "/project/file", "email": "private" + "@example.test"})
        clean = json.loads(PUBLIC.scrub_text(text, "docs/results/result.json", Path(PRIVATE_HOME) / "project", {"private" + "@example.test"}))
        self.assertEqual(clean["artifactSHA256"], original_hash)
        self.assertTrue(clean["passed"])
        self.assertEqual(clean["cpu"], .1)
        self.assertEqual(clean["path"], "<local-checkout>/file")
        self.assertEqual(clean["email"], "<private-email>")


class ModelMetadataTests(unittest.TestCase):
    def replacement(self, original=None):
        value = (original or PRIVATE_HOME).encode()
        return {"property": "FileSelectParams.directory", "originalHex": value.hex(), "replacementHex": b"//".hex()}

    def test_only_fixed_width_directory_bytes_change(self):
        directory = PRIVATE_HOME.encode()
        geometry = b"geometry-unchanged\x00" + bytes(range(128))
        original = b"BLENDER-test\0" + directory + b"\0" * 25 + geometry
        clean, proof = PUBLIC.patch_model_bytes(original, [self.replacement()])
        self.assertEqual(len(clean), len(original))
        self.assertTrue(clean.endswith(geometry))
        self.assertTrue(proof["bytesOutsideMetadataRangesIdentical"])
        self.assertIn(b"//\0", clean)

    def test_unexpected_duplicate_string_blocks_patch(self):
        original = (PRIVATE_HOME.encode() + b"\0") * 2
        with self.assertRaises(PUBLIC.PublicationError):
            PUBLIC.patch_model_bytes(original, [self.replacement()])

    def test_path_outside_native_allowlist_blocks_patch(self):
        original = PRIVATE_HOME.encode() + b"\0" + (PRIVATE_HOME + "/texture.png").encode() + b"\0"
        with self.assertRaises(PUBLIC.PublicationError):
            PUBLIC.patch_model_bytes(original, [self.replacement()])


class ArchiveAndProvenanceTests(unittest.TestCase):
    def archive(self, name, kind=tarfile.REGTYPE):
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w") as archive:
            entry = tarfile.TarInfo(name)
            entry.type = kind
            entry.size = 1 if kind == tarfile.REGTYPE else 0
            entry.linkname = "outside" if kind == tarfile.SYMTYPE else ""
            archive.addfile(entry, io.BytesIO(b"x") if entry.size else None)
        out.seek(0)
        return out

    def test_traversal_and_links_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, kind in [("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                               (".git/config", tarfile.REGTYPE), ("linked", tarfile.SYMTYPE)]:
                with self.subTest(name=name), self.assertRaises(PUBLIC.PublicationError):
                    PUBLIC.extract_archive(self.archive(name, kind), root)

    def test_raw_build_sessions_are_excluded_even_if_tracked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            excluded = PUBLIC.extract_archive(self.archive(".build/copilot/session.txt"), root)
            self.assertEqual(excluded, [".build/copilot/session.txt"])
            self.assertEqual(list(root.iterdir()), [])

    def test_archive_uses_commit_and_refuses_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, output = root / "repo", root / "export"
            repo.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL, text=True)
            git("init", "--quiet")
            (repo / "README.md").write_text("committed")
            git("add", "README.md")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@noreply.example", "commit", "--quiet", "-m", "fixture")
            (repo / "README.md").write_text("uncommitted")
            (repo / "untracked.txt").write_text("not exported")
            PUBLIC.archive_commit(repo, "HEAD", output)
            self.assertEqual((output / "README.md").read_text(), "committed")
            self.assertFalse((output / "untracked.txt").exists())
            self.assertFalse((output / ".git").exists())
            with self.assertRaises(PUBLIC.PublicationError):
                PUBLIC.archive_commit(repo, "HEAD", output)
            self.assertEqual((repo / "README.md").read_text(), "uncommitted")

    def test_original_provenance_mismatch_is_not_reblessed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sample = root / "art/sprout/sample-v01"
            sample.mkdir(parents=True)
            value = {"sourceReview": "art/source.blend", "sourceReviewSHA256": "old",
                     "model": "model.blend", "modelSHA256": "old", "contactSamplesSHA256": "old",
                     "groomBindingVerificationSHA256": "old", "alphaVerificationSHA256": "old",
                     "runtimeManifestSHA256": "old", "sourceSHA256": {"art/builder.py": "old"}}
            PUBLIC.write_json(sample / "sample-build.json", value)
            with self.assertRaises(PUBLIC.PublicationError):
                PUBLIC.verify_original_provenance(root, {"art/sprout/sample-v01/sample-build.json": "original"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Export one committed Spriglet snapshot into a new, independently publishable directory.

Never changes the source checkout, its index, commits, or remotes. Never publishes.
Only known local metadata is transformed. Unexpected private data blocks the result.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import zlib


TOOL_DIR = Path(__file__).resolve().parent
HOME_PATH = re.compile(rb"/Users/[A-Za-z0-9_.-]+(?:/[^\x00\r\n\"'`<>]*)?")
TEXT_SUFFIXES = {".md", ".json", ".swift", ".py", ".sh", ".plist", ".entitlements", ".xcprivacy", ".pbxproj", ".xcscheme", ".yml", ".yaml", ".toml", ".txt"}
SECRET_PATTERNS = {
    "private-key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY",
    "github-token": rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})",
    "cloud-access-key": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "service-token": rb"(?:xox[baprs]-[A-Za-z0-9-]{15,}|sk_live_[A-Za-z0-9]{16,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{30,}|AIza[A-Za-z0-9_-]{30,})",
    "credential-in-url": rb"https?://[^\s/:@]{1,80}:[^\s/@]{3,120}@",
}


class PublicationError(RuntimeError):
    """Messages contain categories and relative filenames, never matched values."""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    return sha(path.read_bytes())


def relative_file(root: Path, value: str) -> Path:
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"..", ".git"} for part in path.parts) or not path.parts:
        raise PublicationError("Unsafe repository-relative path")
    resolved = root.joinpath(*path.parts).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise PublicationError("Path escaped the export directory")
    return resolved


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise PublicationError("Git could not read the requested committed snapshot")
    return result.stdout.strip()


def extract_archive(stream, target: Path) -> list[str]:
    excluded = []
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for entry in archive:
            name = PurePosixPath(entry.name)
            if name.is_absolute() or any(part in {"..", ".git"} for part in name.parts):
                raise PublicationError("Unsafe archive member path")
            if ".build" in name.parts or "__pycache__" in name.parts:
                excluded.append(entry.name)
                continue
            if entry.issym() or entry.islnk() or not (entry.isfile() or entry.isdir()):
                raise PublicationError("Archive contains a link or unsupported file type")
            destination = relative_file(target, entry.name)
            if entry.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.exists():
                    raise PublicationError("Duplicate archive member")
                source = archive.extractfile(entry)
                if source is None:
                    raise PublicationError("Unreadable archive member")
                with destination.open("xb") as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(0o755 if entry.mode & 0o111 else 0o644)
    return excluded


def archive_commit(repo: Path, revision: str, target: Path) -> tuple[str, list[str]]:
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}")
    if target.exists() or target.is_symlink():
        raise PublicationError("Export destination must not already exist")
    if target.resolve() == repo.resolve() or ".git" in target.resolve().parts:
        raise PublicationError("Export destination cannot be the source checkout or Git metadata")
    if target.resolve().is_relative_to(repo.resolve()) and not target.resolve().is_relative_to(repo.resolve() / ".build"):
        raise PublicationError("An in-checkout export must live under the ignored .build directory")
    target.mkdir(parents=True)
    process = subprocess.Popen(["git", "-C", str(repo), "archive", "--format=tar", commit], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        excluded = extract_archive(process.stdout, target)
    except BaseException:
        process.kill()
        process.wait()
        raise
    finally:
        if process.stdout:
            process.stdout.close()
    if process.wait():
        raise PublicationError("Git archive failed; incomplete export must not be published")
    return commit, excluded


def png_chunks(data: bytes):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PublicationError("Invalid PNG signature")
    offset = 8
    while offset < len(data):
        if offset + 12 > len(data):
            raise PublicationError("Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        end = offset + size + 12
        if end > len(data):
            raise PublicationError("Truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise PublicationError("Invalid PNG chunk CRC")
        yield kind, payload, data[offset:end]
        offset = end
        if kind == b"IEND":
            if size or end != len(data):
                raise PublicationError("Invalid PNG end marker")
            return
    raise PublicationError("PNG has no end marker")


def strip_png_file(data: bytes) -> tuple[bytes, dict | None]:
    retained = []
    removed = 0
    before_idat = bytearray()
    for kind, payload, chunk in png_chunks(data):
        if kind == b"IDAT":
            before_idat.extend(payload)
        key, separator, text = payload.partition(b"\0")
        if kind == b"tEXt" and separator and key == b"File" and HOME_PATH.search(text):
            removed += 1
        else:
            retained.append(chunk)
    if not removed:
        return data, None
    exported = data[:8] + b"".join(retained)
    after_idat = b"".join(payload for kind, payload, _ in png_chunks(exported) if kind == b"IDAT")
    if after_idat != before_idat:
        raise PublicationError("PNG image-data identity check failed")
    return exported, {"removedLocalFileTextChunks": removed, "idatUnchanged": True,
                      "idatSHA256": sha(after_idat), "allOtherChunksByteIdentical": True}


def load_png_reader():
    path = TOOL_DIR.parent / "CharacterSampleValidation/png_validation.py"
    spec = importlib.util.spec_from_file_location("publication_png_reader", path)
    if spec is None or spec.loader is None:
        raise PublicationError("The independent PNG reader is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.read_rgba_png


def scrub_text(text: str, relative: str, source_root: Path, personal_emails: set[str]) -> str:
    source = source_root.as_posix()
    # Real local Markdown targets become usable relative links in the public tree.
    pattern = re.compile(r"\]\(<?" + re.escape(source) + r"/([^)>\n]+)>?\)")
    def local_link(match):
        target = PurePosixPath(match.group(1))
        if ".." in target.parts:
            return "](<local-checkout>)"
        import os
        link = os.path.relpath(str(target), str(PurePosixPath(relative).parent))
        return "](" + ("<" + link + ">" if " " in link else link) + ")"
    text = pattern.sub(local_link, text)
    # A private note reference is not part of the public app's provenance.
    text = re.sub(r"/Users/[A-Za-z0-9_.-]+/Library/Mobile Documents/[^`\r\n\"<>]+", "<private-note>", text)
    text = re.sub(r"/Users/[A-Za-z0-9_.-]+/\.codex/generated_images/[^`\r\n\s\"<>]+", "<local-home>/generated-concept-source.png", text)
    text = text.replace(source + "/", "<local-checkout>/").replace(source, "<local-checkout>")
    text = re.sub(r"/Users/[A-Za-z0-9_.-]+", "<local-home>", text)
    for email in sorted(personal_emails, key=len, reverse=True):
        text = text.replace(email, "<private-email>")
    return text


def decode_model(data: bytes, zstd: str | None) -> tuple[bytes, str]:
    if data.startswith(b"BLENDER"):
        return data, "uncompressed"
    if data.startswith(b"\x1f\x8b"):
        return gzip.decompress(data), "gzip"
    if data.startswith(b"\x28\xb5\x2f\xfd"):
        if not zstd:
            raise PublicationError("zstd is required to inspect compressed Blender artifacts")
        result = subprocess.run([zstd, "-d", "-q", "-c"], input=data, capture_output=True)
        if result.returncode or not result.stdout.startswith(b"BLENDER"):
            raise PublicationError("Blender artifact decompression failed")
        return result.stdout, "zstd"
    raise PublicationError("Unsupported Blender artifact encoding")


def patch_model_bytes(data: bytes, replacements: list[dict]) -> tuple[bytes, dict]:
    grouped = Counter((row["originalHex"], row["replacementHex"]) for row in replacements)
    changed = bytearray(data)
    ranges = []
    for (old_hex, new_hex), owners in grouped.items():
        old, new = bytes.fromhex(old_hex), bytes.fromhex(new_hex)
        if not old.startswith(b"/Users/") or b"\0" in old or not new.startswith(b"//") or len(new) > len(old):
            raise PublicationError("Unsupported model metadata replacement")
        needle = old + b"\0"
        positions = [match.start() for match in re.finditer(re.escape(needle), data)]
        if len(positions) != owners:
            raise PublicationError("Model metadata byte occurrences do not match native property owners")
        for start in positions:
            end = start + len(old)
            if any(start < b and end > a for a, b in ranges):
                raise PublicationError("Model metadata replacement ranges overlap")
            changed[start:end] = new + b"\0" * (len(old) - len(new))
            ranges.append((start, end))
    scrubbed = bytes(changed)
    if len(scrubbed) != len(data) or HOME_PATH.search(scrubbed):
        raise PublicationError("Model has unsupported remaining local paths")
    before_masked, after_masked = bytearray(data), bytearray(scrubbed)
    for start, end in ranges:
        before_masked[start:end] = after_masked[start:end] = b"\0" * (end - start)
    if before_masked != after_masked:
        raise PublicationError("Model bytes outside the approved metadata fields changed")
    return scrubbed, {"decompressedSizeUnchanged": True,
                      "bytesOutsideMetadataRangesIdentical": True,
                      "nonMetadataBytesSHA256": sha(before_masked),
                      "decompressedBeforeSHA256": sha(data), "decompressedAfterSHA256": sha(scrubbed),
                      "redactedFieldCount": len(ranges), "properties": [row["property"] for row in replacements]}


def blender_metadata(blender: str, root: Path, paths: list[str]) -> dict:
    if not paths:
        return {"models": []}
    result = subprocess.run([blender, "--background", "--factory-startup", "--disable-autoexec",
        "--python-exit-code", "1", "--python", str(TOOL_DIR / "inspect-model.py"), "--", *paths],
        cwd=root, capture_output=True, text=True, timeout=120)
    lines = [line.removeprefix("PUBLIC_MODEL_METADATA=") for line in result.stdout.splitlines()
             if line.startswith("PUBLIC_MODEL_METADATA=")]
    if result.returncode or len(lines) != 1:
        raise PublicationError("Isolated Blender metadata readback failed; raw output was not published")
    return json.loads(lines[0])


def public_files(root: Path):
    return sorted(path for path in root.rglob("*") if path.is_file()
                  and not any(part in {".git", ".build", "__pycache__"} for part in path.relative_to(root).parts))


def read_json(root: Path, relative: str):
    return json.loads(relative_file(root, relative).read_text())


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def verify_original_provenance(root: Path, original: dict[str, str]):
    """Never bless a pre-existing mismatch by merely replacing its old hash."""
    required = {}
    sample_name = "art/sprout/sample-v01/sample-build.json"
    if sample_name in original:
        value = read_json(root, sample_name)
        sample = PurePosixPath(sample_name).parent
        required[value["sourceReview"]] = value["sourceReviewSHA256"]
        for key, name in [("modelSHA256", value["model"]), ("contactSamplesSHA256", "contact-samples.json"),
                          ("groomBindingVerificationSHA256", "groom-binding-verification.json"),
                          ("alphaVerificationSHA256", "alpha-verification.json")]:
            required[(sample / name).as_posix()] = value[key]
        required["Sources/Spriglet/Resources/SproutSample/manifest.json"] = value["runtimeManifestSHA256"]
        required.update(value["sourceSHA256"])
    icon_name = "art/sprout/public-preview/icon-render.json"
    if icon_name in original:
        value = read_json(root, icon_name)
        directory = PurePosixPath(icon_name).parent
        required[value["sourceModel"]] = value["sourceModelSHA256"]
        for key, name in [("iconSceneSHA256", value["iconScene"]), ("foregroundImageSHA256", value["foregroundImage"]),
                          ("appIconImageSHA256", value["appIconImage"]), ("scriptSHA256", "render_icon.py")]:
            required[(directory / name).as_posix()] = value[key]
    mismatches = [name for name, expected in required.items() if original.get(name) != expected]
    if mismatches:
        raise PublicationError("Original authoring provenance is already stale: " + ", ".join(sorted(mismatches)))


def refresh_current_provenance(root: Path, reasons: dict[str, list[str]], original_hashes: dict[str, str] | None = None) -> list[str]:
    """Refresh only the inputs used by current authoring/verifier entry points."""
    modified = []
    relative = "art/sprout/sample-v01/sample-build.json"
    if (root / relative).exists():
        value = read_json(root, relative)
        original_metadata_hash = (original_hashes or {}).get(relative, file_sha(root / relative))
        sample = root / "art/sprout/sample-v01"
        old_model_hash = value["modelSHA256"]
        value["sourceReviewSHA256"] = file_sha(relative_file(root, value["sourceReview"]))
        for key, name in [("modelSHA256", value["model"]), ("contactSamplesSHA256", "contact-samples.json"),
                          ("groomBindingVerificationSHA256", "groom-binding-verification.json"),
                          ("alphaVerificationSHA256", "alpha-verification.json")]:
            value[key] = file_sha(relative_file(sample, name))
        value["runtimeManifestSHA256"] = file_sha(root / "Sources/Spriglet/Resources/SproutSample/manifest.json")
        value["sourceSHA256"] = {name: file_sha(relative_file(root, name)) for name in value["sourceSHA256"]}
        value["publicationTransformation"] = {
            "kind": "mechanical metadata/provenance update; not a render",
            "previousMetadataSHA256": original_metadata_hash, "previousModelSHA256": old_model_hash,
            "pixelAndModelIdentityEvidence": "PUBLICATION.json", "freshReadbackRequired": True,
        }
        write_json(root / relative, value)
        reasons.setdefault(relative, []).append("Refresh current export/reuse input hashes after recorded metadata transformations; no new render claimed")
        modified.append(relative)
    relative = "art/sprout/public-preview/icon-render.json"
    if (root / relative).exists():
        value = read_json(root, relative)
        original_metadata_hash = (original_hashes or {}).get(relative, file_sha(root / relative))
        directory = (root / relative).parent
        value["sourceModelSHA256"] = file_sha(relative_file(root, value["sourceModel"]))
        for key, name in [("iconSceneSHA256", value["iconScene"]), ("foregroundImageSHA256", value["foregroundImage"]),
                          ("appIconImageSHA256", value["appIconImage"]), ("scriptSHA256", "render_icon.py")]:
            value[key] = file_sha(relative_file(directory, name))
        value["publicationTransformation"] = {
            "kind": "mechanical metadata/provenance update; not a render",
            "previousMetadataSHA256": original_metadata_hash, "pixelAndModelIdentityEvidence": "PUBLICATION.json",
            "freshReadbackRequired": True,
        }
        write_json(root / relative, value)
        reasons.setdefault(relative, []).append("Refresh icon input hashes after recorded metadata transformations; no new render claimed")
        modified.append(relative)
    return modified


def run_saved_verifier(root: Path, blender: str, script: str, result_name: str, reasons: dict) -> dict:
    output = relative_file(root, result_name)
    if not (root / script).is_file():
        raise PublicationError("The current saved-artifact verifier is missing")
    if output.exists():
        historical = output.with_name(output.stem + "-before-publication.json")
        if historical.exists():
            raise PublicationError("Historical verification backup already exists")
        shutil.copyfile(output, historical)
        reasons.setdefault(historical.relative_to(root).as_posix(), []).append("Preserve original saved-artifact success evidence before a fresh public readback")
    before = {p.relative_to(root).as_posix(): file_sha(p) for p in public_files(root)}
    process = subprocess.run([blender, "--background", "--factory-startup", "--disable-autoexec",
        "--python-exit-code", "1", "--python", script], cwd=root, capture_output=True, text=True, timeout=180)
    if process.returncode or not output.is_file():
        raise PublicationError("Fresh saved-artifact verifier failed; raw process output was not published")
    result = json.loads(output.read_text())
    if result.get("passed") is not True:
        raise PublicationError("Fresh saved-artifact verifier did not pass")
    after = {p.relative_to(root).as_posix(): file_sha(p) for p in public_files(root)}
    unexpected = [name for name in before.keys() | after.keys()
                  if before.get(name) != after.get(name) and name != result_name]
    if unexpected:
        raise PublicationError("Verifier unexpectedly changed public files: " + ", ".join(unexpected))
    reasons.setdefault(result_name, []).append("New isolated verifier run on the sanitized artifact; original evidence preserved separately")
    return {"script": script, "result": result_name, "passed": True,
            "resultSHA256": file_sha(output), "rendered": False, "savedModel": False}


def audit_public(root: Path, personal_emails: set[str], zstd: str | None) -> dict:
    findings = []
    for path in public_files(root):
        name = path.relative_to(root).as_posix()
        data = path.read_bytes()
        if path.suffix == ".blend":
            data, _ = decode_model(data, zstd)
        elif path.suffix == ".png":
            parts = []
            for kind, payload, _ in png_chunks(data):
                if kind == b"tEXt":
                    parts.append(payload)
                elif kind == b"zTXt":
                    _, _, compressed = payload.partition(b"\0")
                    parts.append(zlib.decompress(compressed[1:]))
                elif kind == b"iTXt":
                    _, _, text = payload.partition(b"\0")
                    flag = text[0]
                    text = text[2:].split(b"\0", 2)[-1]
                    parts.append(zlib.decompress(text) if flag else text)
            data = b"\n".join(parts)
        elif path.suffix not in TEXT_SUFFIXES and path.name not in {"LICENSE", ".gitignore", "NOTICE", "SECURITY"}:
            # Still scan other binary files for exact identifiers/high-confidence
            # credentials, not email-like random compressed image bytes.
            pass
        categories = []
        if HOME_PATH.search(data):
            categories.append("remaining-private-home-path")
        if any(email.encode() in data for email in personal_emails):
            categories.append("remaining-personal-commit-email")
        for category, pattern in SECRET_PATTERNS.items():
            if re.search(pattern, data):
                categories.append(category)
        if categories:
            findings.append({"file": name, "categories": categories})
    return {"passed": not findings, "findings": findings,
            "scope": "Known local identifiers, personal commit emails, and bounded high-confidence credential patterns; not a guarantee against every possible secret."}


def prepare(repo: Path, revision: str, target: Path, blender: str, zstd: str | None) -> dict:
    repo, target = repo.resolve(), target.resolve()
    repo = Path(git(repo, "rev-parse", "--show-toplevel")).resolve()
    emails = {line for line in git(repo, "log", "--all", "--format=%ae%n%ce").splitlines()
              if line and "noreply" not in line.lower()}
    commit, excluded = archive_commit(repo, revision, target)
    original = {p.relative_to(target).as_posix(): file_sha(p) for p in public_files(target)}
    if "PUBLICATION.json" in original:
        raise PublicationError("Input snapshot already contains a publication manifest")
    verify_original_provenance(target, original)
    reasons: dict[str, list[str]] = {}
    pixel_proofs = {}
    model_proofs = {}
    read_png = load_png_reader()
    png_paths = [p for p in public_files(target) if p.suffix == ".png"]
    for index, path in enumerate(png_paths, 1):
        data = path.read_bytes()
        exported, proof = strip_png_file(data)
        if proof:
            before = read_png(path)
            path.write_bytes(exported)
            after = read_png(path)
            if (before.width, before.height, before.pixels) != (after.width, after.height, after.pixels):
                raise PublicationError("Decoded PNG pixels changed")
            proof.update(decodedRGBAIdentical=True, decodedRGBASHA256=sha(after.pixels), dimensions=[after.width, after.height])
            name = path.relative_to(target).as_posix()
            reasons.setdefault(name, []).append("Remove only a local-path PNG File text chunk")
            pixel_proofs[name] = proof
        if index % 40 == 0:
            print(f"Inspected {index}/{len(png_paths)} PNG metadata records", file=sys.stderr, flush=True)
    for path in public_files(target):
        if path.suffix in TEXT_SUFFIXES or path.name in {"LICENSE", ".gitignore", "NOTICE", "SECURITY"}:
            name = path.relative_to(target).as_posix()
            text = path.read_text()
            clean = scrub_text(text, name, repo, emails)
            if clean != text:
                if path.suffix == ".json":
                    json.loads(clean)
                path.write_text(clean)
                reasons.setdefault(name, []).append("Redact local identifiers; preserve historical measurements and original evidence hashes")
    models = [p.relative_to(target).as_posix() for p in public_files(target) if p.suffix == ".blend"]
    initial = blender_metadata(blender, target, models)
    for model in initial["models"]:
        path = relative_file(target, model["file"])
        raw, encoding = decode_model(path.read_bytes(), zstd)
        if model["replacements"]:
            clean, proof = patch_model_bytes(raw, model["replacements"])
            if encoding == "uncompressed":
                exported = clean
            elif encoding == "gzip":
                exported = gzip.compress(clean, mtime=0)
            else:
                result = subprocess.run([zstd, "-q", "-c"], input=clean, capture_output=True)
                if result.returncode:
                    raise PublicationError("Model metadata recompression failed")
                exported = result.stdout
            if decode_model(exported, zstd)[0] != clean:
                raise PublicationError("Recompressed model failed exact roundtrip")
            path.write_bytes(exported)
            model_proofs[model["file"]] = proof
            reasons.setdefault(model["file"], []).append("Replace native file-browser/output-path metadata with relative paths; all other decompressed bytes unchanged")
        elif HOME_PATH.search(raw):
            raise PublicationError("Model has a local path outside supported native metadata fields: " + model["file"])
    if models:
        final = blender_metadata(blender, target, models)
        for before, after in zip(initial["models"], final["models"], strict=True):
            expected = {p["property"]: p["valueHex"] for p in before["properties"]}
            expected.update({p["property"]: p["replacementHex"] for p in before["replacements"]})
            actual = {p["property"]: p["valueHex"] for p in after["properties"]}
            if after["replacements"] or expected != actual or before["readbackSummarySHA256"] != after["readbackSummarySHA256"]:
                raise PublicationError("Native metadata readback differed from the approved model transformation")
            if before["file"] in model_proofs:
                model_proofs[before["file"]].update(isolatedBlenderReopenPassed=True, nativeMetadataValuesVerified=True)
    refresh_current_provenance(target, reasons, original)
    fresh = []
    for script, result_name in [
        ("art/sprout/scripts/verify_sample.py", "art/sprout/sample-v01/verification.json"),
        ("art/sprout/public-preview/verify_icon.py", "art/sprout/public-preview/icon-verification.json"),
    ]:
        if (target / script).exists():
            print("Running fresh saved-artifact verification: " + script, file=sys.stderr, flush=True)
            fresh.append(run_saved_verifier(target, blender, script, result_name, reasons))
    audit = audit_public(target, emails, zstd)
    exported = {p.relative_to(target).as_posix(): file_sha(p) for p in public_files(target)}
    changes = [{"file": name, "originalSHA256": original.get(name), "exportedSHA256": exported.get(name),
                "reasons": reasons.get(name, ["Generated during recorded publication validation"]),
                **({"pixelIdentity": pixel_proofs[name]} if name in pixel_proofs else {}),
                **({"modelMetadataIdentity": model_proofs[name]} if name in model_proofs else {})}
               for name in sorted(original.keys() | exported.keys()) if original.get(name) != exported.get(name)]
    report = {
        "schemaVersion": 1, "kind": "spriglet-clean-public-snapshot", "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": commit, "sourceTrackedFiles": len(original), "exportedFilesBeforeThisManifest": len(exported),
        "historyIncluded": False, "excludedArchivePaths": excluded,
        "excludedContent": ["Git objects, refs, config, and commit metadata", "Untracked/ignored files", ".build including raw Copilot sessions, traces, build products, and verifier scratch files"],
        "toolSHA256": file_sha(Path(__file__)), "modelInspectorSHA256": file_sha(TOOL_DIR / "inspect-model.py"),
        "changedFiles": changes, "freshSavedArtifactVerifications": fresh, "privacyAudit": audit,
        "historicalEvidenceScope": "Existing historical success reports retain their original artifact/source hashes and observations. Redacted path strings do not turn them into tests of this public snapshot. Current mechanical authoring metadata is explicitly marked; saved-model/icon verification is rerun and its previous report is retained separately.",
        "requiredBeforeRelease": ["Fresh app build, asset validation, and native checks against this exported snapshot", "Public-root Git initialization with intentional public author identity; never import the private development refs", "Release/distribution and contest requirements remain separate"],
        "status": "sanitized-awaiting-release-validation" if audit["passed"] else "blocked-private-data-remains",
    }
    write_json(target / "PUBLICATION.json", report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=TOOL_DIR.parents[1])
    parser.add_argument("--commit", required=True, help="Exact commit or local ref; uncommitted changes are excluded")
    parser.add_argument("--output", required=True, type=Path, help="New directory only; existing directories are refused")
    parser.add_argument("--blender", default="/Applications/Blender.app/Contents/MacOS/Blender")
    parser.add_argument("--zstd", default=shutil.which("zstd"))
    args = parser.parse_args()
    destination_existed = args.output.exists() or args.output.is_symlink()
    try:
        report = prepare(args.repo, args.commit, args.output, args.blender, args.zstd)
    except (PublicationError, subprocess.TimeoutExpired, ValueError, OSError) as error:
        # Avoid echoing raw third-party output, filenames outside the export, or
        # exception strings that might contain the identifier being redacted.
        print("Public export failed: " + (str(error) if isinstance(error, PublicationError) else type(error).__name__), file=sys.stderr)
        print("An incomplete destination must not be published; the source checkout was not changed.", file=sys.stderr)
        if not destination_existed and args.output.is_dir() and args.output.resolve() != args.repo.resolve():
            (args.output / "PUBLICATION-BLOCKED.txt").write_text(
                "This incomplete export failed preparation and must not be published. Start again in a new directory after addressing the reported category.\n")
        return 1
    print(json.dumps({"status": report["status"], "changedFiles": len(report["changedFiles"]),
                      "freshVerifications": len(report["freshSavedArtifactVerifications"]),
                      "privacyFindings": report["privacyAudit"]["findings"]}, indent=2))
    return 0 if report["privacyAudit"]["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())

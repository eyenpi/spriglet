# Preparing a clean public snapshot

`prepare-public.py` exports one specified Git commit into a **new directory**. It never edits the private checkout or index, changes Git history, runs an app, creates a remote repository, or publishes anything. An in-checkout destination is allowed only under ignored `.build`; a separate sibling directory is also supported. Existing destinations are refused.

The private development repository and its history remain private. Initialize the resulting public snapshot as a new Git root with an intentional public author identity. Do not later merge or push private development refs into that repository: a clean working tree does not remove old objects from reachable history. See [GitHub's explanation of history exposure](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

## Run

Use Python 3.12+, Git, `zstd` on PATH, and the verified Blender 5.2 installation. Xcode is also needed when the snapshot contains the icon catalog verifier. The app itself gains no runtime dependency from these publication tools.

After committing the intended app, artwork, license, and documentation, run from the private repository root:

```sh
python3 tools/PublicRelease/prepare-public.py \
  --commit HEAD \
  --output ../spriglet-public-export
```

`--commit` accepts a commit or local ref and resolves it once. Uncommitted changes and untracked files are excluded. Optional `--repo`, `--blender`, and `--zstd` arguments select the source repository and installed offline tools. The exporter does not include `.git`, `.build`, raw Copilot sessions, traces, compiled products, or Python caches. It rejects archive links and traversal paths.

Exit **0** means the bounded sanitation and saved-artifact checks passed, with app release validation still required. Exit **1** means preparation failed; a newly created incomplete export is marked `PUBLICATION-BLOCKED.txt`. Exit **2** means the final privacy audit found remaining identifiers or credential candidates. Inspect only the reported file/category; matched private values and raw Blender output are not printed. Never publish an incomplete or blocked destination. A retry uses a new directory.

## What changes

- **PNG metadata:** only a `tEXt` chunk named `File` containing a local home path is removed. Every other chunk, including all `IDAT` bytes and color/profile metadata, remains byte-for-byte identical. The independent sample decoder compares before/after RGBA pixels and dimensions. A local path in an unsupported metadata field blocks publication instead of being silently deleted. This follows the [W3C PNG text-chunk and image-data specification](https://www.w3.org/TR/png-3/).
- **Text and JSON:** project-local Markdown links become relative links. Other checkout paths use `<local-checkout>`, home paths use `<local-home>`, private note references use `<private-note>`, and personal emails obtained from private commit metadata use `<private-email>`. Generation cache identifiers are replaced with a labeled local source marker. Existing numerical measurements, pass/fail outcomes, and historical artifact hashes are retained.
- **Blender models:** a fresh, noninteractive Blender process with automatic script execution disabled identifies `FileSelectParams.directory` and render-output `filepath` values. Only known local values in those nonvisual fields are eligible. The exporter replaces them with relative paths plus NUL padding, preserving the decompressed file length and **every byte outside those exact metadata ranges**. It recompresses, checks a complete decompression roundtrip, and reopens the result in Blender to verify the actual properties. An unexpected path, duplicate occurrence, unsupported encoding, or other readback change blocks publication. Geometry, materials, cameras, animation, contact data, and rendered pixels are not regenerated. The saved icon scene is inspected by the same procedure.

The narrow model transformation is verified against installed Blender 5.2 RNA. The [FileSelectParams API](https://docs.blender.org/api/5.2/bpy.types.FileSelectParams.html) defines the file-browser directory; render output paths use [RenderSettings.filepath](https://docs.blender.org/api/5.2/bpy.types.RenderSettings.html#bpy.types.RenderSettings.filepath). The tool does not resave the models, so unrelated saved data cannot change as a side effect of saving.

## Provenance and evidence

`PUBLICATION.json` records the source commit without including its history, original/exported SHA-256 for every changed file, the reason for each transformation, PNG identity proofs, model byte-identity proofs, exclusions, and the final audit. The source commit remains a reference to the private development checkpoint, not a public ancestor.

Original authoring hashes are checked **before** transformations. A pre-existing mismatch blocks export; the tool never repairs a stale chain by merely claiming its current files are original. It refreshes only the mechanical input chains used by `build_sample.py --reuse-model`, `verify_sample.py`, and the icon verifier:

- `sample-build.json`: sanitized model/source-review hashes and any transformed inputs; contact, timing, alpha measurements, and runtime manifest stay unchanged when their bytes did not change.
- `icon-render.json`: sanitized model/icon-scene and image hashes where needed.

Both records receive an explicit `publicationTransformation` field. This is a metadata transformation, **not a new render**. The saved-rig verifier and, when present, the icon verifier then run inside the exported tree. Their original success reports are preserved as `verification-before-publication.json` and `icon-verification-before-publication.json`; their normal report files contain newly executed checks. Unexpected verifier writes outside those result files and ignored scratch directories block publication.

Other historical evidence is intentionally not rewritten to claim it tested the sanitized bytes. This includes the older static model-review manifests, app/native runs, image inventory hashes, machine snapshots, and UI observations. Their original measurements remain useful historical context; the publication manifest explains the transformation boundary. An embedded icon-source hash likewise identifies the original model used for rendering; its relation to the sanitized model is recorded by the transformation chain.

Before publishing or releasing the app, run fresh asset validation, Swift tests, builds, and native checks against the exported snapshot. Record those as **new evidence** and use relative paths in public reports. The exporter itself does not certify Developer ID signing, notarization, physical desktop behavior, battery life, contest eligibility, or user approval. MIT license scope for code and artwork belongs in the repository's `LICENSE` and public documentation; the sanitizer does not invent a license grant.

## Tests

```sh
python3 -m unittest discover -s tools/PublicRelease -p 'test_*.py' -v
```

These tests use synthetic PNG/model bytes and a temporary Git repository. They cover pixel/profile preservation, refusal of unsupported metadata, fixed-width model changes, archive path/link safety, exact-commit export, private-note labeling, and retention of historical evidence hashes. They do not launch Blender or the app. A separate disposable Blender fixture was used during implementation to validate the native metadata inspection and reopen path; a real publication run repeats the readback on its actual archived models.

Run that optional native fixture explicitly with:

```sh
python3 tools/PublicRelease/check-blender-fixture.py
```

It creates a temporary default cube with private file-browser/output-path metadata, applies the exact byte patch, and reopens it in a new Blender process. It never opens or changes the existing Sprout artwork and deletes its temporary model after the check.

The final scanner covers known local identifiers, personal commit emails, and a bounded set of high-confidence credential patterns. It reports candidates without exposing values. It is not a guarantee that every possible form of private information has been detected; review the final snapshot and publication manifest before changing visibility.

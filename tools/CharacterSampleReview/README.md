# Character sample review movies

`make-review.py` composites the exact runtime PNG sequence and matching cumulative root offsets over warm light (`F3F0E7`) and dark (`202420`) backgrounds. It invokes installed FFmpeg and ffprobe using argument arrays, validates the encoded frame count, and records movie/manifest hashes and dimensions.

Run from the repository root after the runtime asset export succeeds:

```sh
python3 tools/CharacterSampleReview/make-review.py \
  --walk walkRight --output-dir art/sprout/sample-v01/review
python3 tools/CharacterSampleReview/make-review.py \
  --walk walkLeft --output-dir art/sprout/sample-v01/review
```

The default output location, if omitted, is the ignored `.build/character-sample-review` directory. The tools require `ffmpeg` and `ffprobe` on PATH; the retained run uses FFmpeg 9.0.1. Root displacement is held for each authored frame through FFmpeg's current [`sendcmd` and `overlay` commands](https://ffmpeg.org/ffmpeg-filters.html).

Each movie contains idle, the selected walk, pet, and settle. A 448-pixel source canvas represents 224 macOS points; the JSON records the full review canvas at that scale. The video viewer may resize playback. These are offline asset-compositing reviews, not screen recordings or proof of atomic compositor presentation. Use the [native fixture](../CharacterSampleValidation/README.md) for actual desktop window size and motion observations.

## Public demo media

`make-public-demo.py` packages the two existing review movies into `docs/media/spriglet-demo.mp4` and `docs/media/spriglet-demo.gif`:

```sh
python3 tools/CharacterSampleReview/make-public-demo.py
```

The silent MP4 is 1600 × 1000 at 30 fps, with a 14.87-second sequence of rightward and leftward movement plus short neutral holds. Captions follow idle, walk, petting reaction, and settling. The 800 × 500 GIF is a 15 fps README preview, capped at 5 MB; its reduced rate does not describe the app's playback rate. Both visibly identify themselves as an animation asset demo and public source preview. Neither is a desktop recording.

The exporter verifies the existing review movie hashes, compiles a temporary Swift 6/AppKit text renderer using the installed system font, and composites the titles with FFmpeg. Font files are never copied or distributed. The source character renders, animation timing within each original clip, and review movies are unchanged. Current [`NSFont.systemFont(ofSize:weight:)`](https://developer.apple.com/documentation/appkit/nsfont/systemfont(ofsize:weight:)) and bitmap drawing APIs are checked by compilation against the installed SDK. Neutral holds and the compact GIF use FFmpeg's documented [`tpad`, `palettegen`, and `paletteuse` filters](https://ffmpeg.org/ffmpeg-filters.html).

`--output-dir` changes the destination; `--work-dir` changes the default ignored `.build/public-demo` scratch folder. That folder contains representative extracted frames and `verification.json`, including ffprobe dimensions, duration, frame counts, output hashes, and metadata checks. The exporter strips inherited metadata, rejects local filesystem paths in output tags, verifies that both outputs are silent, and enforces the GIF size cap. No Copilot attribution is burned into the pixels.

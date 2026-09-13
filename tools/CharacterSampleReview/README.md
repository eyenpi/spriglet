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

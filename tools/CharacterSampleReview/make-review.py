#!/usr/bin/env python3
"""Make a light/dark comparison movie from the exact runtime frames and offsets.

The movie is an offline asset review. Native window compositing is checked by
the separate CharacterSampleValidation fixture and the running app.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def concat_quote(path: Path) -> str:
    value = str(path)
    if "\n" in value or "\r" in value:
        raise ValueError("A frame path contains a line break.")
    return "'" + value.replace("'", "'\\''") + "'"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "Sources/Spriglet/Resources/SproutSample/manifest.json")
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".build/character-sample-review")
    parser.add_argument("--walk", choices=("walkRight", "walkLeft"), default="walkRight")
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("The review exporter requires ffmpeg and ffprobe on PATH.")
    manifest_path = args.manifest.resolve()
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    fps = manifest["framesPerSecond"]
    canvas = manifest["canvasPixels"]
    display = manifest["displaySizePoints"]
    scale = canvas["width"] / display["width"]
    if not math.isclose(scale, canvas["height"] / display["height"]):
        raise ValueError("The review requires a uniform pixel-to-point scale.")
    sequence = ["idle", args.walk, "pet", "settle"]
    frames = []
    carry_x = carry_y = 0.0
    phases = []
    for clip_id in sequence:
        clip = manifest["clips"][clip_id]
        phases.append({"clip": clip_id, "firstFrame": len(frames), "frameCount": len(clip["frames"])})
        for frame in clip["frames"]:
            source = (manifest_path.parent / frame["file"]).resolve()
            if not source.is_relative_to(manifest_path.parent) or not source.is_file():
                raise ValueError(f"Missing or out-of-bundle frame: {frame['file']}")
            offset = frame["rootOffsetPoints"]
            x, y = carry_x + offset["x"], carry_y + offset["y"]
            if not math.isfinite(x) or not math.isfinite(y):
                raise ValueError("Nonfinite root motion.")
            frames.append((source, x * scale, y * scale))
        carry_x += clip["frames"][-1]["rootOffsetPoints"]["x"]
        carry_y += clip["frames"][-1]["rootOffsetPoints"]["y"]
    if not frames:
        raise ValueError("The sample contains no frames.")
    minimum_x, maximum_x = min(f[1] for f in frames), max(f[1] for f in frames)
    minimum_y, maximum_y = min(f[2] for f in frames), max(f[2] for f in frames)
    padding = round(24 * scale)
    panel_width = math.ceil((canvas["width"] + maximum_x - minimum_x + padding * 2) / 2) * 2
    height = math.ceil((canvas["height"] + maximum_y - minimum_y + padding * 2) / 2) * 2
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"sprout-{args.walk}-light-dark.mp4"

    with tempfile.TemporaryDirectory(prefix="sprout-review-") as scratch:
        scratch_path = Path(scratch)
        (scratch_path / "frames.ffconcat").write_text("ffconcat version 1.0\n" + "".join(
            f"file {concat_quote(source)}\n" for source, _, _ in frames
        ))
        commands = []
        for index, (_, offset_x, offset_y) in enumerate(frames):
            # Dispatch between source frame times, avoiding floating-point
            # equality at a 1/30-second boundary. Position remains frame-held.
            timestamp = max(0, (index - 0.25) / fps)
            x = padding - minimum_x + offset_x
            y = padding + maximum_y - offset_y
            commands.append(f"{timestamp:.9f} overlay@light x {x:.9f}, overlay@light y {y:.9f}, "
                            f"overlay@dark x {x + panel_width:.9f}, overlay@dark y {y:.9f};\n")
        (scratch_path / "placements.txt").write_text("".join(commands))
        graph = (
            "[1:v]format=rgba,split=2[petLight][petDark];"
            f"[0:v]format=rgba,drawbox=x={panel_width}:y=0:w={panel_width}:h={height}:"
            "color=0x202420:t=fill,sendcmd=f=placements.txt[background];"
            "[background][petLight]overlay@light=x=0:y=0:eval=frame:alpha=straight:format=auto[first];"
            "[first][petDark]overlay@dark=x=0:y=0:eval=frame:alpha=straight:format=auto,format=yuv420p[video]"
        )
        command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                   f"color=c=0xf3f0e7:s={panel_width * 2}x{height}:r={fps}",
                   "-f", "concat", "-safe", "0", "-r", str(fps), "-i", "frames.ffconcat",
                   "-filter_complex", graph, "-map", "[video]", "-frames:v", str(len(frames)),
                   "-r", str(fps), "-c:v", "libx264", "-crf", "16", "-preset", "medium",
                   "-movflags", "+faststart", str(output)]
        subprocess.run(command, cwd=scratch_path, check=True)

    probe = json.loads(subprocess.check_output([
        ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
        "stream=width,height,avg_frame_rate,nb_read_frames,duration", "-of", "json", str(output)
    ]))
    stream = probe["streams"][0]
    if int(stream["nb_read_frames"]) != len(frames):
        raise RuntimeError("The encoded review changed the authored frame count.")
    report = {
        "kind": "character-sample-offline-review", "movie": output.name,
        "scope": "Exact runtime PNGs and frame-held root offsets over fixed light/dark colors; not a screen recording.",
        "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        "movieSHA256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "pixelsPerPoint": scale, "characterCanvasPoints": display,
        "reviewCanvasPoints": {"width": panel_width * 2 / scale, "height": height / scale},
        "phases": phases, "encodedStream": stream,
        "ffmpeg": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
    }
    (output_dir / f"sprout-{args.walk}-review.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

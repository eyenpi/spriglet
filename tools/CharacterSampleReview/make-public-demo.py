#!/usr/bin/env python3
"""Package the existing light/dark animation reviews as public MP4/GIF media.

This is an offline animation asset demo, never a desktop recording. AppKit
rasterizes the installed system font into temporary plates; no font is copied.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
FPS = 30
WIDTH, HEIGHT = 1600, 1000
INTRO, MIDDLE, OUTRO = 45, 18, 45
CAPTIONS = {
    "intro": "Meet Sprout.",
    "idle": "Idle · A moment of calm",
    "walkRight": "Walk right · Small, grounded steps",
    "walkLeft": "Walk left · The same soft light",
    "pet": "Petting reaction · A happy little nuzzle",
    "settle": "Settle · Back to a quiet rest",
    "middle": "A little quiet company, in light or dark.",
    "outro": "Make it yours · MIT code + artwork",
}

# Current public AppKit drawing APIs, compiled with the active Swift 6 SDK.
PLATE_SOURCE = r'''
import AppKit

struct Plate: Decodable { let file: String; let caption: String }

@main
struct DrawPlates {
    @MainActor
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let plates = try JSONDecoder().decode([Plate].self,
            from: Data(contentsOf: folder.appendingPathComponent("plates.json")))
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x, y: 1000 - top - height, width: width, height: height)
        }
        func text(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat,
                  height: CGFloat, size: CGFloat, weight: NSFont.Weight,
                  ink: UInt32, alignment: NSTextAlignment = .left) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byClipping
            let string = NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color(ink), .paragraphStyle: paragraph])
            string.draw(in: rect(x, top, width, height))
        }
        for plate in plates {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw CocoaError(.fileWriteUnknown)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            color(0xF8F7F1).setFill()
            NSBezierPath(rect: rect(0, 0, 1600, 1000)).fill()
            let panel = NSBezierPath(roundedRect: rect(96, 250, 1408, 624),
                                     xRadius: 22, yRadius: 22)
            color(0xF3F0E7).setFill()
            panel.fill()
            NSGraphicsContext.saveGraphicsState()
            panel.addClip()
            color(0x202420).setFill()
            NSBezierPath(rect: rect(800, 250, 704, 624)).fill()
            NSGraphicsContext.restoreGraphicsState()
            color(0xDFE2D8).setStroke()
            panel.lineWidth = 1
            panel.stroke()
            text("Spriglet", x: 96, top: 48, width: 900, height: 115,
                 size: 88, weight: .semibold, ink: 0x2D3C2E)
            text("A little quiet company for your Mac", x: 100, top: 161,
                 width: 1320, height: 52, size: 34, weight: .regular, ink: 0x65705E)
            text("LIGHT DESKTOP", x: 126, top: 273, width: 540, height: 28,
                 size: 18, weight: .semibold, ink: 0x69725F)
            text("DARK DESKTOP", x: 828, top: 273, width: 540, height: 28,
                 size: 18, weight: .semibold, ink: 0xBCC6B6)
            text(plate.caption, x: 96, top: 901, width: 1408, height: 44,
                 size: 29, weight: .medium, ink: 0x3E5138, alignment: .center)
            text("Animation asset demo · public source preview", x: 96, top: 961,
                 width: 950, height: 28, size: 18, weight: .regular, ink: 0x798070)
            text("MIT code + artwork · macOS 26", x: 1010, top: 961,
                 width: 494, height: 28, size: 18, weight: .regular,
                 ink: 0x798070, alignment: .right)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: folder.appendingPathComponent(plate.file), options: .atomic)
        }
    }
}
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], **kwargs) -> None:
    subprocess.run(command, check=True, **kwargs)


def probe(ffprobe: str, path: Path) -> dict:
    return json.loads(subprocess.check_output([ffprobe, "-v", "error", "-count_frames",
        "-show_entries", "stream=codec_type,codec_name,width,height,avg_frame_rate,nb_read_frames,duration:stream_tags:format=duration,size:format_tags",
        "-of", "json", str(path)]))


def require_clean_metadata(info: dict) -> None:
    tags = [info.get("format", {}).get("tags", {})]
    tags += [stream.get("tags", {}) for stream in info["streams"]]
    serialized = json.dumps(tags)
    if any(value in serialized for value in ("/Users/", "/private/", "/tmp/", "file://", str(ROOT))):
        raise RuntimeError("Output metadata contains a local path")
    if any(stream["codec_type"] != "video" for stream in info["streams"]):
        raise RuntimeError("Public demo must contain only silent video")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "docs/media")
    parser.add_argument("--work-dir", type=Path, default=ROOT / ".build/public-demo")
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe or not shutil.which("xcrun"):
        raise SystemExit("Requires current FFmpeg/ffprobe and the macOS Xcode toolchain")
    work = args.work_dir.resolve()
    output = args.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    sources, source_reports = [], []
    for direction in ("walkRight", "walkLeft"):
        report_path = ROOT / f"art/sprout/sample-v01/review/sprout-{direction}-review.json"
        report = json.loads(report_path.read_text())
        path = report_path.parent / report["movie"]
        if sha256(path) != report["movieSHA256"]:
            raise RuntimeError(f"Review source hash changed: {path.name}")
        stream = probe(ffprobe, path)["streams"][0]
        if (stream["width"], stream["height"], stream["avg_frame_rate"], int(stream["nb_read_frames"])) != (1404, 544, "30/1", 169):
            raise RuntimeError("Unexpected review source dimensions, rate, or frame count")
        sources.append(path)
        source_reports.append(report)
    if source_reports[0]["manifestSHA256"] != source_reports[1]["manifestSHA256"]:
        raise RuntimeError("The two review directions use different asset manifests")

    segments = [("intro", INTRO)]
    for index, report in enumerate(source_reports):
        segments += [(phase["clip"], phase["frameCount"]) for phase in report["phases"]]
        segments.append(("middle", MIDDLE) if index == 0 else ("outro", OUTRO))
    frame_count = sum(count for _, count in segments)
    plates = [{"file": f"plate-{name}.png", "caption": caption} for name, caption in CAPTIONS.items()]
    (work / "plates.json").write_text(json.dumps(plates))
    (work / "DrawPlates.swift").write_text(PLATE_SOURCE)
    run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
         str(work / "DrawPlates.swift"), "-o", str(work / "draw-plates")])
    run([str(work / "draw-plates"), str(work)])
    # One plate entry per exact 30fps output frame avoids duration rounding.
    (work / "plates.ffconcat").write_text("ffconcat version 1.0\n" + "".join(
        f"file 'plate-{name}.png'\n" * count for name, count in segments))
    movie = output / "spriglet-demo.mp4"
    gif = output / "spriglet-demo.gif"
    graph = (
        f"[0:v]tpad=start={INTRO}:stop={MIDDLE}:start_mode=clone:stop_mode=clone,setpts=PTS-STARTPTS[right];"
        f"[1:v]tpad=stop={OUTRO}:stop_mode=clone,setpts=PTS-STARTPTS[left];"
        "[right][left]concat=n=2:v=1:a=0[motion];"
        "[2:v]setpts=PTS-STARTPTS[plate];"
        "[plate][motion]overlay=x=98:y=310:shortest=1:format=auto,format=yuv420p[video]"
    )
    run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(sources[0]),
        "-i", str(sources[1]), "-f", "concat", "-safe", "0", "-r", str(FPS), "-i", "plates.ffconcat",
        "-filter_complex", graph, "-map", "[video]", "-an", "-frames:v", str(frame_count),
        "-r", str(FPS), "-c:v", "libx264", "-crf", "18", "-preset", "medium",
        "-movflags", "+faststart", "-map_metadata", "-1",
        "-metadata", "title=Spriglet — public source preview",
        "-metadata", "comment=Animation asset demo; not a desktop recording", str(movie)], cwd=work)
    run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(movie), "-filter_complex",
        "fps=15,scale=800:500:flags=lanczos,split[video][colors];"
        "[colors]palettegen=max_colors=192:stats_mode=full[palette];"
        "[video][palette]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
        "-an", "-map_metadata", "-1", "-loop", "0", str(gif)])
    movie_info, gif_info = probe(ffprobe, movie), probe(ffprobe, gif)
    for info in (movie_info, gif_info):
        require_clean_metadata(info)
    stream = movie_info["streams"][0]
    if (stream["width"], stream["height"], stream["avg_frame_rate"], int(stream["nb_read_frames"])) != (WIDTH, HEIGHT, "30/1", frame_count):
        raise RuntimeError("Public MP4 dimensions, rate, or exact frame count changed")
    if not 12 <= float(movie_info["format"]["duration"]) <= 16:
        raise RuntimeError("Public demo duration is outside the requested 12–16 seconds")
    if (gif_info["streams"][0]["width"], gif_info["streams"][0]["height"]) != (800, 500):
        raise RuntimeError("Unexpected README GIF dimensions")
    if gif.stat().st_size > 5_000_000:
        raise RuntimeError("README GIF exceeds the 5MB cap")
    for source, report in zip(sources, source_reports):
        if sha256(source) != report["movieSHA256"]:
            raise RuntimeError("A source review movie changed during packaging")
    # Retain representative frames in ignored scratch space for visual review.
    for label, second in (("intro", 0), ("right-walk", 3.4), ("pet", 5.5), ("left-walk", 10), ("outro", 14)):
        run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", str(second),
             "-i", str(movie), "-frames:v", "1", "-update", "1", str(work / f"check-{label}.png")])
    result = {
        "kind": "public-animation-asset-demo", "sourceMoviesUnchanged": True,
        "sources": [{"movie": path.name, "sha256": report["movieSHA256"]} for path, report in zip(sources, source_reports)],
        "assetManifestSHA256": source_reports[0]["manifestSHA256"],
        "exporterSHA256": sha256(Path(__file__)),
        "mp4": {"file": movie.name, "sha256": sha256(movie), **movie_info},
        "gif": {"file": gif.name, "sha256": sha256(gif), "requestedFramesPerSecond": 15, **gif_info},
        "segments": [{"phase": name, "frames": count, "caption": CAPTIONS[name]} for name, count in segments],
        "localPathMetadataFound": False, "fontsRedistributed": False,
        "scope": "Exact existing review movie motion with neutral holds and rasterized titles; no new character render. MP4 is 30fps; GIF is a reduced-rate 15fps preview, subject to GIF timing quantization. Neither is a desktop recording.",
        "ffmpeg": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
    }
    (work / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

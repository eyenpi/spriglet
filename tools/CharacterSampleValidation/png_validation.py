"""Small read-only decoder for this sample's noninterlaced 8-bit RGBA PNGs.

This deliberately supports one export format, not every PNG variant. Chunk CRCs,
stream termination, dimensions, scanline lengths, and all five PNG filters are
checked before alpha measurements. PNG stores unassociated alpha.

Source: https://www.w3.org/TR/png-3/ (2025 W3C Recommendation), sections 6, 9, 11.
"""

from dataclasses import dataclass
import hashlib
from pathlib import Path
import struct
import zlib


class PNGError(ValueError):
    pass


@dataclass(frozen=True)
class RGBAImage:
    width: int
    height: int
    pixels: bytes
    file_sha256: str
    color_chunks: tuple[str, ...]


def _paeth(left: int, up: int, corner: int) -> int:
    estimate = left + up - corner
    distances = (abs(estimate - left), abs(estimate - up), abs(estimate - corner))
    if distances[0] <= distances[1] and distances[0] <= distances[2]:
        return left
    return up if distances[1] <= distances[2] else corner


def read_rgba_png(path: Path, expected_size: tuple[int, int] | None = None) -> RGBAImage:
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise PNGError("Missing PNG signature")
    offset = 8
    chunks: list[bytes] = []
    idat = bytearray()
    header = None
    saw_end = False
    idat_ended = False
    color_chunks: list[str] = []
    while offset < len(raw):
        if len(raw) - offset < 12:
            raise PNGError("Truncated chunk header")
        length = struct.unpack_from(">I", raw, offset)[0]
        kind = raw[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(raw):
            raise PNGError("Truncated chunk payload")
        payload = raw[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack_from(">I", raw, offset + 8 + length)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise PNGError(f"CRC mismatch in {kind!r}")
        if not chunks and kind != b"IHDR":
            raise PNGError("IHDR must be the first chunk")
        if kind == b"IHDR":
            if header is not None or length != 13:
                raise PNGError("Invalid or repeated IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            if idat_ended:
                raise PNGError("IDAT chunks must be consecutive")
            idat.extend(payload)
        elif b"IDAT" in chunks:
            idat_ended = True
        if kind in {b"acTL", b"fcTL", b"fdAT"}:
            raise PNGError("APNG is outside the static-frame contract")
        if kind in {b"sRGB", b"iCCP", b"gAMA", b"cHRM", b"cICP"}:
            color_chunks.append(kind.decode("ascii"))
        if kind == b"IEND":
            if length != 0 or not idat or end != len(raw):
                raise PNGError("Invalid IEND, absent image data, or trailing bytes")
            saw_end = True
            break
        if not kind[0] & 0x20 and kind not in {b"IHDR", b"PLTE", b"IDAT", b"IEND"}:
            raise PNGError(f"Unsupported critical chunk {kind!r}")
        chunks.append(kind)
        offset = end
    if header is None or not saw_end:
        raise PNGError("Incomplete PNG stream")
    width, height, depth, color, compression, filtering, interlace = header
    if not (0 < width <= 4096 and 0 < height <= 4096):
        raise PNGError("Dimensions are outside the bounded sample decoder")
    if expected_size is not None and (width, height) != expected_size:
        raise PNGError(f"Expected {expected_size}, got {(width, height)}")
    if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
        raise PNGError("Expected noninterlaced 8-bit RGBA PNG with standard compression/filtering")
    stride = width * 4
    expected_length = (stride + 1) * height
    decompressor = zlib.decompressobj()
    scanlines = decompressor.decompress(idat, expected_length + 1)
    if len(scanlines) != expected_length or not decompressor.eof or decompressor.unused_data or decompressor.unconsumed_tail:
        raise PNGError("Wrong decompressed scanline length or incomplete/extra zlib stream")
    result = bytearray(stride * height)
    for y in range(height):
        start = y * (stride + 1)
        filter_kind = scanlines[start]
        if filter_kind > 4:
            raise PNGError(f"Invalid scanline filter {filter_kind}")
        for x in range(stride):
            value = scanlines[start + 1 + x]
            target = y * stride + x
            left = result[target - 4] if x >= 4 else 0
            up = result[target - stride] if y else 0
            corner = result[target - stride - 4] if y and x >= 4 else 0
            if filter_kind == 1:
                value += left
            elif filter_kind == 2:
                value += up
            elif filter_kind == 3:
                value += (left + up) // 2
            elif filter_kind == 4:
                value += _paeth(left, up, corner)
            result[target] = value & 255
    return RGBAImage(width, height, bytes(result), hashlib.sha256(raw).hexdigest(), tuple(color_chunks))


def alpha_measurements(image: RGBAImage) -> dict:
    alpha = image.pixels[3::4]
    nonzero = [index for index, value in enumerate(alpha) if value]
    border = [alpha[x] for x in range(image.width)]
    border += [alpha[(image.height - 1) * image.width + x] for x in range(image.width)]
    border += [alpha[y * image.width] for y in range(image.height)]
    border += [alpha[(y + 1) * image.width - 1] for y in range(image.height)]
    opaque_count = sum(value == 255 for value in alpha)
    box = None
    if nonzero:
        box = {"minX": min(index % image.width for index in nonzero),
               "minY": min(index // image.width for index in nonzero),
               "maxX": max(index % image.width for index in nonzero),
               "maxY": max(index // image.width for index in nonzero)}
    return {"transparentPixels": len(alpha) - len(nonzero), "opaquePixels": opaque_count,
            "partialAlphaPixels": len(nonzero) - opaque_count, "maximumBorderAlpha": max(border),
            "alphaBoundsTopLeftPixels": box, "colorMetadataChunks": list(image.color_chunks)}


def endpoint_difference(first: RGBAImage, second: RGBAImage) -> dict:
    """Describe a transition; no guessed artistic acceptance threshold is applied."""
    if (first.width, first.height) != (second.width, second.height):
        raise PNGError("Endpoint dimensions differ")
    alpha_total = 0
    premultiplied_total = 0
    changed = 0
    for index in range(0, len(first.pixels), 4):
        a = first.pixels[index:index + 4]
        b = second.pixels[index:index + 4]
        alpha_total += abs(a[3] - b[3])
        changed += a != b
        for channel in range(3):
            premultiplied_total += abs(a[channel] * a[3] - b[channel] * b[3]) / 255
    count = first.width * first.height
    return {"identicalDecodedPixels": first.pixels == second.pixels,
            "changedPixelFraction": changed / count,
            "meanAbsoluteAlphaDifferenceByteScale": alpha_total / count,
            "meanAbsolutePremultipliedRGBDifferenceByteScale": premultiplied_total / (count * 3),
            "interpretation": "Encoded color-byte comparison; no visual continuity or color-management certification."}

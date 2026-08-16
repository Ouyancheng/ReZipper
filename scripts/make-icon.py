#!/usr/bin/env python3
"""Mask AppIcon onto a full-canvas macOS squircle.

Keeps the dark plate (that is the icon background, like Cursor) and only
clears the four sharp corners. Rebuilds Resources/AppIcon.icns.
"""

from __future__ import annotations

import struct
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC_CANDIDATES = [
    Path(
        "/Users/ouyancheng/.cursor/projects/Volumes-Data-workspace-rezipper/assets/AppIcon.png"
    ),
    ROOT / "Resources" / "AppIcon-source.png",
]
OUT_PNG = ROOT / "Resources" / "AppIcon.png"
OUT_ICNS = ROOT / "Resources" / "AppIcon.icns"
README_ICON = ROOT / "docs" / "screenshots" / "icon.png"

# Superellipse exponent: 5 is the usual Apple-style squircle.
SQUIRCLE_N = 5.0
SUPERSAMPLE = 4

ICNS_PNG = [
    (16, b"icp4"),
    (32, b"icp5"),
    (64, b"icp6"),
    (128, b"ic07"),
    (256, b"ic08"),
    (512, b"ic09"),
    (1024, b"ic10"),
    (32, b"ic11"),
    (64, b"ic12"),
    (256, b"ic13"),
    (512, b"ic14"),
]


def squircle_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    pix = mask.load()
    c = (big - 1) / 2.0
    # Inset half a supersampled pixel so the outer edge is not a hard clip.
    r = c - 0.5
    n = SQUIRCLE_N
    for y in range(big):
        ny = abs((y - c) / r)
        ny_n = ny ** n
        for x in range(big):
            nx = abs((x - c) / r)
            if nx ** n + ny_n <= 1.0:
                pix[x, y] = 255
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    return mask.filter(ImageFilter.GaussianBlur(radius=0.4))


def apply_mask(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.Resampling.LANCZOS)
    mask = squircle_mask(1024)
    r, g, b, a = im.split()
    a = Image.frombytes(
        "L",
        a.size,
        bytes(min(src, m) for src, m in zip(a.tobytes(), mask.tobytes())),
    )
    im.putalpha(a)
    return im


def png_bytes(im: Image.Image, size: int) -> bytes:
    buf = BytesIO()
    im.resize((size, size), Image.Resampling.LANCZOS).save(buf, "PNG")
    return buf.getvalue()


def write_icns(path: Path, im: Image.Image) -> None:
    chunks: list[bytes] = []
    cache: dict[int, bytes] = {}
    for size, ostype in ICNS_PNG:
        if size not in cache:
            cache[size] = png_bytes(im, size)
        data = cache[size]
        chunks.append(ostype + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    path.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def main() -> int:
    src = next((p for p in SRC_CANDIDATES if p.is_file()), None)
    if src is None:
        print("error: no AppIcon source PNG found", file=sys.stderr)
        return 1

    im = apply_mask(Image.open(src))
    OUT_PNG.parent.mkdir(parents=True, exist_ok=True)
    im.save(OUT_PNG, "PNG")
    write_icns(OUT_ICNS, im)
    if README_ICON.parent.is_dir():
        im.resize((256, 256), Image.Resampling.LANCZOS).save(README_ICON, "PNG")

    print(f"source {src}")
    print(f"wrote {OUT_PNG}")
    print(f"wrote {OUT_ICNS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env -S uv run --with pillow --script
"""Build Packaging/AppIcon.icns from design/AppIcon-source.png.

The source is 1024x1024 RGBA with the 824 pt tile already placed on Apple's
icon grid and transparency around it. All this does is lay a shadow underneath
— the source carries the tile only — and slice the result into an iconset.

Run from anywhere: ./design/make-icon.py
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design/AppIcon-source.png"
CANVAS = 1024
ICONSET_SIZES = [16, 32, 128, 256, 512]


def main() -> int:
    if not SOURCE.exists():
        print(f"missing {SOURCE.relative_to(ROOT)}", file=sys.stderr)
        return 1

    tile = Image.open(SOURCE).convert("RGBA")
    if tile.size != (CANVAS, CANVAS):
        print(f"expected a {CANVAS}x{CANVAS} export, got {tile.size[0]}x{tile.size[1]}", file=sys.stderr)
        return 1

    # Shadow: the tile's own silhouette, blurred and nudged down.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (0, 10), tile.getchannel("A"))
    icon = Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)), tile)

    master = ROOT / "design/AppIcon-1024.png"
    icon.save(master)
    print(f"wrote {master.relative_to(ROOT)}")

    iconset = ROOT / "design/AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for stale in iconset.glob("*.png"):
        stale.unlink()
    for size in ICONSET_SIZES:
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")

    out = ROOT / "Packaging/AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

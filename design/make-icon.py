#!/usr/bin/env -S uv run --with pillow --script
"""Turn the chosen generated artwork into Resources/AppIcon.icns.

The generator draws the icon tile on an opaque background with its own drop
shadow. macOS wants the opposite: the squircle cut out with transparency
around it, sized to Apple's grid (824 pt of tile inside a 1024 pt canvas) with
the shadow rendered underneath.

Run from the repo root: ./design/make-icon.py
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design/icons/round4/o2-3.png"
# Bounds of the cream tile inside the generated image, measured by selecting
# the warm (R > B) pixels — the background and its shadow are neutral grey.
TILE_BOX = (136, 114, 136 + 751, 114 + 751)

CANVAS = 1024
TILE = 824  # Apple's macOS icon grid leaves 100 pt of margin on each side.
CORNER_RATIO = 0.225  # Continuous-corner squircle, matches the source artwork.
SUPERSAMPLE = 4
ICONSET_SIZES = [16, 32, 128, 256, 512]


def squircle_mask(size: int, radius: float) -> Image.Image:
    """Antialiased superellipse, the shape macOS uses for app icons."""
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, big - 1, big - 1), radius=radius * SUPERSAMPLE, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SOURCE.exists():
        print(f"missing source artwork: {SOURCE}", file=sys.stderr)
        return 1

    tile = Image.open(SOURCE).convert("RGB").crop(TILE_BOX)
    side = tile.size[0]

    # Inset by a couple of pixels so the source's own antialiased edge — which
    # was blended against grey — is cut away rather than left as a fringe.
    inset = 3
    tile = tile.crop((inset, inset, side - inset, side - inset))
    side = tile.size[0]

    tile.putalpha(squircle_mask(side, side * CORNER_RATIO))
    tile = tile.resize((TILE, TILE), Image.LANCZOS)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    origin = (CANVAS - TILE) // 2

    # Shadow: the tile's own silhouette, blurred and pushed down slightly.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (origin, origin + 10), tile.getchannel("A"))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(14)))
    icon.alpha_composite(tile, (origin, origin))

    master = ROOT / "design/AppIcon-1024.png"
    icon.save(master)
    print(f"wrote {master.relative_to(ROOT)}")

    iconset = ROOT / "design/AppIcon.iconset"
    for stale in iconset.glob("*.png"):
        stale.unlink()
    iconset.mkdir(exist_ok=True)
    for size in ICONSET_SIZES:
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(
            iconset / f"icon_{size}x{size}@2x.png"
        )

    out = ROOT / "Packaging/AppIcon.icns"
    out.parent.mkdir(exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Turn a full-bleed tile into a macOS (Big Sur+) app icon master and render previews.

Usage: python3 make_icon.py <concept_dir>
Reads <dir>/tile.png and <dir>/menubar.svg; writes <dir>/icon_1024.png and <dir>/preview/*.png.
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
TILE = 824  # Apple macOS icon grid: 824x824 body centred on a 1024 canvas
EXPONENT = 5.0  # superellipse approximating Apple's continuous-corner squircle
SUPERSAMPLE = 4


def squircle_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    half = big / 2
    points = []
    steps = 2048
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = half + half * math.copysign(abs(c) ** (2 / EXPONENT), c)
        y = half + half * math.copysign(abs(s) ** (2 / EXPONENT), s)
        points.append((x, y))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def make_master(tile_path: Path) -> Image.Image:
    tile = Image.open(tile_path).convert("RGBA")
    side = min(tile.size)
    left = (tile.width - side) // 2
    top = (tile.height - side) // 2
    tile = tile.crop((left, top, left + side, top + side)).resize((TILE, TILE), Image.LANCZOS)
    mask = squircle_mask(TILE)
    tile.putalpha(ImageChops.multiply(tile.getchannel("A"), mask))

    offset = (CANVAS - TILE) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_alpha.paste(mask.point(lambda v: v * 0.30), (offset, offset + 10))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(14)))

    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(tile, (offset, offset))
    return out


def render_svg(svg: Path, px: int, dest: Path) -> Image.Image:
    subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), str(svg), "-o", str(dest)], check=True)
    return Image.open(dest).convert("RGBA")


def tint(template: Image.Image, rgb: tuple[int, int, int]) -> Image.Image:
    solid = Image.new("RGBA", template.size, rgb + (255,))
    solid.putalpha(template.getchannel("A"))
    return solid


def menubar_strip(svg: Path, preview: Path, scale: int, dark: bool) -> Image.Image:
    """A slice of menu bar (24pt tall) with the template icon tinted like the system does."""
    bg = (40, 40, 42) if dark else (236, 236, 238)
    fg = (255, 255, 255) if dark else (0, 0, 0)
    w, h = 96 * scale, 24 * scale
    strip = Image.new("RGBA", (w, h), bg + (255,))
    icon = render_svg(svg, 18 * scale, preview / f"menubar_{18 * scale}.png")
    x = (w - icon.width) // 2
    y = (h - icon.height) // 2
    strip.alpha_composite(tint(icon, fg), (x, y))
    # neighbouring system-ish glyphs for scale reference
    d = ImageDraw.Draw(strip)
    r = 6 * scale
    for cx in (14 * scale, w - 14 * scale):
        d.rounded_rectangle((cx - r, h // 2 - r, cx + r, h // 2 + r), radius=2 * scale, outline=fg + (255,), width=max(1, int(1.3 * scale)))
    return strip


def main() -> None:
    d = Path(sys.argv[1])
    preview = d / "preview"
    preview.mkdir(exist_ok=True)
    master = make_master(d / "tile.png")
    master.save(d / "icon_1024.png")
    for px in (512, 128, 32):
        master.resize((px, px), Image.LANCZOS).save(preview / f"icon_{px}.png")
    for scale in (1, 2):
        for dark in (False, True):
            strip = menubar_strip(d / "menubar.svg", preview, scale, dark)
            name = f"bar_{'dark' if dark else 'light'}_{scale}x.png"
            if scale == 1:  # show 1x pixels enlarged without smoothing
                strip = strip.resize((strip.width * 2, strip.height * 2), Image.NEAREST)
            strip.save(preview / name)


if __name__ == "__main__":
    main()

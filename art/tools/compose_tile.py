"""Put the extracted mark on a new full-bleed background.

Usage: python3 compose_tile.py <mark.png> <out tile.png> <centre hex> <edge hex> <shadow opacity 0-1> [scale]
The background is a soft radial gradient (centre colour in the middle, edge colour at the corners);
the mark gets a soft drop shadow so it separates from light backgrounds. `scale` enlarges the mark
about its own centre and re-centres it on the canvas (default 1).
"""
import sys

import numpy as np
from PIL import Image, ImageFilter


def hex_rgb(value: str) -> np.ndarray:
    value = value.lstrip("#")
    return np.array([int(value[i : i + 2], 16) for i in (0, 2, 4)], np.float32)


def fit_mark(mark: Image.Image, scale: float) -> Image.Image:
    """Scale the mark's visible bounding box by `scale` and centre it on a canvas of the same size."""
    box = mark.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if box is None:
        raise SystemExit("mark has no visible pixels")
    cropped = mark.crop(box)
    w, h = round(cropped.width * scale), round(cropped.height * scale)
    cropped = cropped.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    canvas.alpha_composite(cropped, ((mark.width - w) // 2, (mark.height - h) // 2))
    return canvas


def main() -> None:
    mark_path, out_path, centre, edge, shadow_opacity = sys.argv[1:6]
    scale = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
    mark = fit_mark(Image.open(mark_path).convert("RGBA"), scale)
    size = mark.width
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    r = np.hypot(xx - size / 2, yy - size * 0.45) / (size * 0.72)
    t = np.clip(r, 0, 1)[..., None] ** 1.6
    bg = hex_rgb(centre) * (1 - t) + hex_rgb(edge) * t
    tile = Image.fromarray(np.dstack([bg, np.full((size, size), 255, np.float32)]).astype(np.uint8))

    alpha = mark.getchannel("A")
    shadow_alpha = alpha.point(lambda v: int(v * float(shadow_opacity))).filter(ImageFilter.GaussianBlur(size / 60))
    shadow = Image.new("RGBA", mark.size, (0, 0, 0, 255))
    shadow.putalpha(shadow_alpha)
    tile.alpha_composite(shadow, (0, int(size / 70)))
    tile.alpha_composite(mark)
    tile.convert("RGB").save(out_path)


if __name__ == "__main__":
    main()

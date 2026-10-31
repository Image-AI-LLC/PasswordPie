"""Lift the neutral metal mark off a saturated-background tile, keeping its pixels unchanged.

Usage: python3 extract_mark.py <tile.png> <mark.png>
The background is any strongly blue/purple-tinted area; alpha comes from how much of that tint a pixel
carries (blue minus green), and edge colours are un-mixed from a smooth background estimate.
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

BG_MIN = 110  # blue-minus-green above this is pure background
FG_MAX = 40  # blue-minus-green below this is pure mark
PAD = 24  # px of anti-aliased edge kept around the solid mark
INSET = 60  # px inside the mark's bounding box where cut-outs are searched
HOLE_EDGE = 21  # px (odd) around a cut-out treated as its inner-shadow band
SHADOW_RGB = (38, 40, 46)


def smooth_background(rgb: np.ndarray, known: np.ndarray) -> np.ndarray:
    """Fill the mark's footprint with a blur of the surrounding background (normalised convolution)."""
    weight = known.astype(np.float32)
    acc = rgb * weight[..., None]
    out = np.empty_like(rgb)
    for radius in (8, 32, 96, 256):
        w = np.asarray(Image.fromarray((weight * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255
        chans = []
        for c in range(3):
            ch = Image.fromarray(np.clip(acc[..., c], 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))
            chans.append(np.asarray(ch, np.float32))
        est = np.stack(chans, -1) / np.maximum(w[..., None], 1e-4)
        fill = (w > 0.02) & ~known
        out[fill] = est[fill]
        known = known | fill
    out[weight > 0] = rgb[weight > 0]
    return out


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    rgb = np.asarray(Image.open(src).convert("RGB"), np.float32)
    metric = rgb[..., 2] - rgb[..., 1]
    bg = smooth_background(rgb, metric > BG_MIN)
    bg_metric = np.maximum(bg[..., 2] - bg[..., 1], FG_MAX + 1)
    alpha = np.clip((bg_metric - metric) / (bg_metric - FG_MAX), 0, 1)
    # Keep only the mark: drop stray dark background patches outside the solid mark's bounding box.
    ys, xs = np.nonzero(metric < FG_MAX)
    keep = np.zeros_like(alpha)
    keep[max(ys.min() - PAD, 0) : ys.max() + PAD, max(xs.min() - PAD, 0) : xs.max() + PAD] = 1
    alpha *= keep
    safe = np.maximum(alpha, 1e-3)[..., None]
    fg = np.clip((rgb - (1 - alpha[..., None]) * bg) / safe, 0, 255)

    # Inside the cut-out (keyhole) the half-transparent pixels are the cut's inner shadow; un-mixing the
    # textured background leaves them speckled, so render them as a smooth neutral shadow instead.
    y0, y1, x0, x1 = ys.min() + INSET, ys.max() - INSET, xs.min() + INSET, xs.max() - INSET
    hole = np.zeros(alpha.shape, bool)
    hole[y0:y1, x0:x1] = metric[y0:y1, x0:x1] > BG_MIN
    near_hole = np.asarray(Image.fromarray(hole.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(HOLE_EDGE)), bool)
    soft = near_hole & (alpha < 0.85)
    smooth_alpha = np.asarray(Image.fromarray((alpha * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2)), np.float32) / 255
    alpha = np.where(soft, smooth_alpha, alpha)
    fg[soft] = SHADOW_RGB
    rgba = np.dstack([fg, alpha * 255]).astype(np.uint8)
    Image.fromarray(rgba).save(dst)


if __name__ == "__main__":
    main()

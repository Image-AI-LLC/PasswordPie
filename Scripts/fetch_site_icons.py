#!/usr/bin/env python3
"""Fetch the icons of the top sites and write the PNGs bundled into PasswordPie.app.

Run on a development Mac, never in the app:

    python3 -I Scripts/fetch_site_icons.py            # top 100 from DomainRanksData.swift
    python3 -I Scripts/fetch_site_icons.py --top 120  # more

Needs Pillow (`pip install pillow`), and `rsvg-convert` (librsvg) and `pngquant` from Homebrew.

For each domain, in this order:
  1. the site's own icons: `<link rel=icon>` and `apple-touch-icon` from its home page, then `/favicon.ico`.
     An SVG wins; otherwise the largest bitmap, preferring `icon` over `apple-touch-icon` when both are at least 64 px.
  2. if the site has nothing usable, Google's favicon service at 128 px (fetched here, on the developer's machine).
A domain whose best icon is smaller than 32 px, or that has none, is skipped and keeps the letter tile in the app.

Writes `Assets/SiteIcons/<host>.png` (64 x 64) and `<host>@2x.png` (128 x 128), and `Assets/SiteIcons/SOURCES.md`, which
lists where each icon came from. Fails if the folder ends up larger than 1 MB.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import html.parser
import io
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
RANKS = ROOT / "Sources/PasswordPieCore/DomainRanksData.swift"
OUT = ROOT / "Assets/SiteIcons"
SIZES = {"": 64, "@2x": 128}
MAX_TOTAL = 1_000_000
MAX_DOWNLOAD = 2_000_000
MIN_SOURCE = 32
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/141.0.0.0 Safari/537.36"
)


def top_domains(count: int) -> list[str]:
    text = RANKS.read_text()
    body = text.split('"""', 2)[1]
    return [line.strip() for line in body.splitlines() if line.strip()][:count]


def get(url: str, limit: int = MAX_DOWNLOAD) -> tuple[str, bytes, str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=12) as response:
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError("too large")
        return response.geturl(), data, response.headers.get("Content-Type", "")


class LinkParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str, str]] = []
        self.base: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {k.lower(): (v or "") for k, v in attrs}
        if tag == "base" and values.get("href"):
            self.base = values["href"]
        if tag != "link":
            return
        rel = values.get("rel", "").lower().split()
        href = values.get("href", "")
        if not href:
            return
        if "icon" in rel or "apple-touch-icon" in rel or "apple-touch-icon-precomposed" in rel:
            kind = "icon" if "icon" in rel else "apple-touch-icon"
            self.links.append((kind, href, values.get("sizes", "")))


def render(data: bytes, content_type: str, url: str) -> Image.Image | None:
    """The largest frame as RGBA, or None when the bytes are not an image Pillow or librsvg can read."""
    head = data[:512].lstrip().lower()
    if "svg" in content_type or url.lower().split("?")[0].endswith(".svg") or head.startswith(b"<svg") or b"<svg" in head:
        with tempfile.TemporaryDirectory() as folder:
            source = pathlib.Path(folder) / "icon.svg"
            target = pathlib.Path(folder) / "icon.png"
            source.write_bytes(data)
            result = subprocess.run(
                ["rsvg-convert", "-w", "256", "-h", "256", "--keep-aspect-ratio", str(source), "-o", str(target)],
                capture_output=True,
                timeout=20,
            )
            if result.returncode != 0 or not target.exists():
                return None
            return Image.open(io.BytesIO(target.read_bytes())).convert("RGBA")
    try:
        image = Image.open(io.BytesIO(data))
        if image.format == "ICO":
            sizes = sorted(image.info.get("sizes", [image.size]), key=lambda s: s[0] * s[1])
            image.size = sizes[-1]
        image.load()
        return image.convert("RGBA")
    except Exception:
        return None


def candidates(domain: str) -> list[tuple[str, str, int]]:
    """(kind, url, declared size) for the site's own icons."""
    found: list[tuple[str, str, int]] = []
    page = f"https://{domain}/"
    try:
        final, body, _ = get(page, 3_000_000)
        parser = LinkParser()
        parser.feed(body.decode("utf-8", "replace"))
        base = urllib.parse.urljoin(final, parser.base) if parser.base else final
        for kind, href, sizes in parser.links:
            url = urllib.parse.urljoin(base, href.strip())
            if not url.startswith(("https://", "http://")):
                continue
            declared = 0
            if sizes.lower() == "any":
                declared = 512
            else:
                for match in re.finditer(r"(\d+)x(\d+)", sizes.lower()):
                    declared = max(declared, min(int(match.group(1)), int(match.group(2))))
            found.append((kind, url, declared))
        page = final
    except Exception:
        pass
    origin = urllib.parse.urlsplit(page)
    root = f"{origin.scheme}://{origin.netloc}"
    found.append(("icon", root + "/favicon.ico", 0))
    found.append(("apple-touch-icon", root + "/apple-touch-icon.png", 180))
    return found


def best_icon(domain: str) -> tuple[Image.Image, str] | None:
    scored: list[tuple[tuple[int, int, int], Image.Image, str]] = []
    seen: set[str] = set()
    for kind, url, _ in candidates(domain):
        if url in seen:
            continue
        seen.add(url)
        try:
            final, data, content_type = get(url)
        except Exception:
            continue
        image = render(data, content_type, final)
        if image is None:
            continue
        side = min(image.size)
        if side < MIN_SOURCE:
            continue
        is_svg = image.size == (256, 256) and ("svg" in content_type or final.lower().split("?")[0].endswith(".svg"))
        big_enough = 1 if side >= 64 else 0
        prefer_icon = 1 if kind == "icon" else 0
        scored.append(((1 if is_svg else 0, big_enough, prefer_icon * big_enough * 1000 + min(side, 256)), image, url))
    if scored:
        scored.sort(key=lambda item: item[0], reverse=True)
        _, image, url = scored[0]
        return image, url
    google = "https://www.google.com/s2/favicons?" + urllib.parse.urlencode({"domain": domain, "sz": "128"})
    try:
        final, data, content_type = get(google)
    except urllib.error.HTTPError:
        return None  # 404 is Google's generic globe: no icon.
    except Exception:
        return None
    image = render(data, content_type, final)
    if image is None or min(image.size) < MIN_SOURCE:
        return None
    return image, google


def square(image: Image.Image, side: int) -> Image.Image:
    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)
    width, height = image.size
    scale = side / max(width, height)
    resized = image.resize((max(1, round(width * scale)), max(1, round(height * scale))), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(resized, ((side - resized.width) // 2, (side - resized.height) // 2), resized)
    return canvas


def write_png(image: Image.Image, path: pathlib.Path) -> None:
    image.save(path, "PNG", optimize=True)
    # pngquant leaves the file alone when it cannot beat it at this quality (exit 98 or 99).
    result = subprocess.run(
        ["pngquant", "--force", "--skip-if-larger", "--strip", "--quality", "70-95", "--output", str(path), str(path)],
        capture_output=True,
    )
    if result.returncode not in (0, 98, 99):
        raise RuntimeError(f"pngquant failed on {path.name}: {result.stderr.decode(errors='replace')}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--top", type=int, default=100)
    args = parser.parse_args()
    for tool in ("rsvg-convert", "pngquant"):
        if shutil.which(tool) is None:
            print(f"error: {tool} not found (brew install librsvg pngquant)", file=sys.stderr)
            return 1

    domains = top_domains(args.top)
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = dict(zip(domains, pool.map(best_icon, domains)))

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    rows: list[str] = []
    skipped: list[str] = []
    for rank, domain in enumerate(domains, start=1):
        found = results[domain]
        if found is None:
            skipped.append(f"{rank}. {domain}")
            continue
        image, source = found
        for suffix, side in SIZES.items():
            write_png(square(image, side), OUT / f"{domain}{suffix}.png")
        shown = "Google favicon service" if source.startswith("https://www.google.com/s2/") else source
        rows.append(f"| {rank} | {domain} | {shown} |")

    total = sum(path.stat().st_size for path in OUT.glob("*.png"))
    today = datetime.date.today().isoformat()
    notes = [
        "# Bundled site icons",
        "",
        f"Generated by `Scripts/fetch_site_icons.py` on {today}. Do not edit by hand.",
        "",
        f"The top {args.top} domains of the [Majestic Million](https://majestic.com/reports/majestic-million) "
        "(CC BY 3.0), as bundled in `Sources/PasswordPieCore/DomainRanksData.swift`. Each icon was taken from the site "
        "itself (`<link rel=icon>`, `apple-touch-icon` or `/favicon.ico`), or, where the site offered none, from "
        "Google's favicon service when this script ran. The app itself never fetches an icon.",
        "",
        "Each icon is the trademark or logo of its site's owner and is included only to show which site a saved "
        "account belongs to. It is not covered by this repository's license, and no endorsement is implied.",
        "",
        f"{len(rows)} icons, {total:,} bytes in all.",
        "",
        "| Rank | Domain | Source |",
        "|---|---|---|",
        *rows,
        "",
        "## Skipped",
        "",
        "No icon of at least 32 px was found; these keep the letter tile.",
        "",
        *(f"- {line}" for line in skipped),
        "",
    ]
    (OUT / "SOURCES.md").write_text("\n".join(notes))
    print(f"{len(rows)} icons, {len(skipped)} skipped, {total:,} bytes")
    if total > MAX_TOTAL:
        print(f"error: {total:,} bytes is over the {MAX_TOTAL:,} byte budget", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

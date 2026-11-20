"""Small SVG kit for the browser question board: palette, measured text, wrapping, controls.

Needs Pillow and the SF Pro fonts in /Library/Fonts (text is measured to wrap it), and rsvg-convert for the PNGs.
"""
import pathlib
import re
from PIL import ImageFont

HERE = pathlib.Path(__file__).parent
FONT_DIR = pathlib.Path("/Library/Fonts")
WEIGHT_FILE = {400: "Regular", 500: "Medium", 600: "Semibold", 700: "Bold"}

LIGHT = dict(
    surface="#FFF6E7", card="#FFFFFF", text="#302A24", secondary="#70604F", tertiary="#8F7F6E",
    border="#C8BBAA", ink="#302A24", accent="#EE8C32", on_accent="#302315", accent_text="#A65312",
    backdrop="#D8D3CB", button="#302A24", button_alpha=0.10, ok="#4C9F5B",
)
DARK = dict(
    surface="#28231F", card="#37302A", text="#FFF6E7", secondary="#D4C4B2", tertiary="#A39585",
    border="#776858", ink="#FFF6E7", accent="#EE8C32", on_accent="#302315", accent_text="#F6B469",
    backdrop="#141210", button="#FFF6E7", button_alpha=0.12, ok="#7CC08A",
)

# The pie is the brand mark's own geometry.
PIE_PATH = re.search(r' d="([^"]+)"', (HERE.parent.parent / "source" / "mark.svg").read_text()).group(1)

_fonts = {}


def font(size, weight):
    key = (size, weight)
    if key not in _fonts:
        # Measured at 20x for sub-pixel accuracy.
        _fonts[key] = ImageFont.truetype(str(FONT_DIR / f"SF-Pro-Text-{WEIGHT_FILE[weight]}.otf"), int(size * 20))
    return _fonts[key]


def width(s, size, weight=400):
    return font(size, weight).getlength(s) / 20


def wrap(s, size, weight, max_width):
    lines, line = [], ""
    for word in s.split(" "):
        trial = word if not line else line + " " + word
        if width(trial, size, weight) <= max_width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    # As AppKit's push-out line breaking: a last line of one word takes the word before it along.
    if len(lines) > 1 and " " not in lines[-1] and " " in lines[-2]:
        head, _, tail = lines[-2].rpartition(" ")
        lines[-2:] = [head, tail + " " + lines[-1]]
    return lines


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, weight=400, fill="#000", anchor="start", opacity=None, spacing=None):
    extra = ""
    if opacity is not None:
        extra += f' fill-opacity="{opacity}"'
    if spacing is not None:
        extra += f' letter-spacing="{spacing}"'
    return (f'<text x="{x:.2f}" y="{y:.2f}" font-family="SF Pro Text" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}"{extra}>{esc(s)}</text>')


def rich_line(x, y, runs, size):
    """runs: [(string, weight, fill)] drawn on one baseline."""
    spans = "".join(
        f'<tspan font-weight="{w}" fill="{f}">{esc(s)}</tspan>' for s, w, f in runs
    )
    return f'<text x="{x:.2f}" y="{y:.2f}" font-family="SF Pro Text" font-size="{size}" xml:space="preserve">{spans}</text>'


def para(x, y, s, size, weight, fill, max_width, leading, anchor="start"):
    """Returns (svg, next_y). y is the first baseline."""
    out = []
    for i, line in enumerate(wrap(s, size, weight, max_width)):
        out.append(text(x, y + i * leading, line, size, weight, fill, anchor))
    return "\n".join(out), y + len(out) * leading


def pie(x, y, size, fill):
    s = size / 24
    return f'<path transform="translate({x:.2f} {y:.2f}) scale({s:.4f})" fill="{fill}" fill-rule="evenodd" d="{PIE_PATH}"/>'


def ego(x, y, size):
    """A stand-in for the browser's own icon, so the board carries no other company's artwork."""
    r = size * 0.225
    c = size / 2
    return (f'<rect x="{x + 1:.2f}" y="{y + 1:.2f}" width="{size - 2}" height="{size - 2}" rx="{r:.2f}" fill="#FFFFFF" stroke="#302A24" stroke-opacity="0.18" stroke-width="0.5"/>'
            f'<circle cx="{x + c:.2f}" cy="{y + c:.2f}" r="{size * 0.24:.2f}" fill="none" stroke="#3A3A3C" stroke-width="{size * 0.07:.2f}"/>'
            f'<circle cx="{x + c:.2f}" cy="{y + c:.2f}" r="{size * 0.07:.2f}" fill="#3A3A3C"/>')


def button(x, y, w, h, label, p, primary=False, radius=7, size=13):
    if primary:
        box = f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h}" rx="{radius}" fill="{p["accent"]}"/>'
        fill = p["on_accent"]
    else:
        box = (f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h}" rx="{radius}" fill="{p["button"]}" '
               f'fill-opacity="{p["button_alpha"]}"/>')
        fill = p["text"]
    return box + text(x + w / 2, y + h / 2 + size * 0.36, label, size, 500, fill, "middle")


def seal(x, y, size, fill, tick):
    """A filled circle with a check: the signature was verified. x, y is the top-left corner."""
    r = size / 2
    cx, cy = x + r, y + r
    k = size / 14
    return (f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:.2f}" fill="{fill}"/>'
            f'<path d="M{cx - 3.1 * k:.2f} {cy + 0.2 * k:.2f} L{cx - 0.9 * k:.2f} {cy + 2.4 * k:.2f} L{cx + 3.3 * k:.2f} {cy - 2.4 * k:.2f}" '
            f'fill="none" stroke="{tick}" stroke-width="{1.6 * k:.2f}" stroke-linecap="round" stroke-linejoin="round"/>')


def window(x, y, w, h, p, body, radius=16, uid="w"):
    """The panel: system window shape and shadow, the app's flat surface."""
    return f'''<g>
<defs>
<filter id="sh{uid}" x="-30%" y="-30%" width="160%" height="170%">
<feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.22"/>
<feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#000" flood-opacity="0.14"/>
</filter>
<clipPath id="cl{uid}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}"/></clipPath>
</defs>
<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{p["surface"]}" filter="url(#sh{uid})"/>
<rect x="{x + 0.25}" y="{y + 0.25}" width="{w - 0.5}" height="{h - 0.5}" rx="{radius}" fill="none" stroke="{p["ink"]}" stroke-opacity="0.16" stroke-width="0.5"/>
<g clip-path="url(#cl{uid})"><g transform="translate({x} {y})">
{body}
</g></g>
</g>'''


def document(w, h, backdrop, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
            f'<rect width="{w}" height="{h}" fill="{backdrop}"/>\n{body}\n</svg>\n')

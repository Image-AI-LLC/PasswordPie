"""The browser question window, light and dark. Usage: python3 panel.py  (writes ../browser-approval-*.svg and .png)"""
import pathlib
import subprocess
from kit import DARK, LIGHT, button, document, ego, para, pie, rich_line, text, window, wrap

NAME = "ego\u00a0lite"  # a browser's name never breaks across lines
SIGNER = "CITRO LABS PTE. LIMITED"
TITLE = f"Allow “{NAME}” to fill passwords?"
EFFECT = "It gets the username and password of each account you pick."
PREF = "You can change this in Preferences\u00a0>\u00a0Browsers."
CONDITION = f"Only allow it if you added the PasswordPie extension to {NAME} yourself."

W, PAD = 480, 20


def two_tone(x, y, first, second, size, p, max_width, leading):
    """One paragraph, its second sentence in the secondary colour. Returns (svg, next baseline)."""
    lines = wrap(first + " " + second, size, 400, max_width)
    out, left = [], len(first)
    for i, line in enumerate(lines):
        head, tail = line[:max(0, min(len(line), left))], line[max(0, min(len(line), left)):]
        left -= len(line) + 1
        out.append(rich_line(x, y + i * leading, [(head, 400, p["text"]), (tail, 400, p["secondary"])], size))
    return "\n".join(out), y + len(lines) * leading


AXIS = PAD + 44  # the title and the browser's name start here, each beside its icon


def panel(p):
    inner = W - 2 * PAD
    # Who asks: PasswordPie's mark and name, over the question.
    out = [pie(PAD + 1, 19, 30, p["accent"]),
           text(AXIS, 29.5, "PasswordPie", 11, 500, p["secondary"]),
           text(AXIS, 48, TITLE, 16, 600, p["text"])]
    # Who is asked about: the browser's own icon, its name and who signed it.
    out.append(ego(PAD, 70, 32))
    out.append(text(AXIS, 83.5, NAME, 14, 500, p["text"]))
    out.append(text(AXIS, 99.5, f"Signed by {SIGNER}", 11, 400, p["secondary"]))
    # What allowing does, then when to allow: the full width, from the buttons' left edge.
    svg, y = para(PAD, 132, EFFECT, 13, 400, p["text"], inner, 18)
    out.append(svg)
    svg, y = para(PAD, y + 2, CONDITION, 13, 500, p["text"], inner, 18)
    out.append(svg)
    # Where to undo it: a note of its own, one step smaller.
    out.append(text(PAD, y + 8, PREF, 11, 400, p["secondary"]))
    y = y + 8 + 4 + 18
    half = (inner - 10) / 2
    out.append(button(PAD, y, half, 28, "Don’t Allow", p, radius=7))
    out.append(button(PAD + half + 10, y, half, 28, "Allow", p, radius=7))
    return "\n".join(out), W, y + 28 + PAD


def main():
    out = pathlib.Path(__file__).parent.parent
    margin = 48
    for name, p in (("light", LIGHT), ("dark", DARK)):
        body, w, h = panel(p)
        svg = out / f"browser-approval-{name}.svg"
        svg.write_text(document(w + 2 * margin, h + 2 * margin, p["backdrop"], window(margin, margin, w, h, p, body, uid=name)))
        subprocess.run(["rsvg-convert", "-z", "2", str(svg), "-o", str(svg.with_suffix(".png"))], check=True)
        print(svg.with_suffix(".png"), w, h)


main()

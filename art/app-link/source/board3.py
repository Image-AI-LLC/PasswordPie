"""Round 3 board: everything at 1:1, the two copies drawn, one account header for the way back."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from board1 import (defs, tile, app, pencil, star, row, app_window, menu, text, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT,
                    BORDER, DESK, LABEL, LABEL_STRONG, ROUND, ACCENT_TEXT, FIELD, INK)

NAMES = {'harbor': ('Harbor', 36), 'ledger': ('Ledger', 35)}
RELATION = 'Appears first in'
RELATION_W = 84


def token(x, y, name, hot=False):
    """One linked app: icon, name, and a close mark at the end that is always there and darkens under the pointer."""
    label, lw = NAMES[name]
    w, h = 6 + 12 + 5 + lw + 5 + 8 + 6, 17
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' fill='{FIELD if hot else 'none'}' "
           f"stroke='{INK}' stroke-opacity='{0.5 if hot else 0.25}'/>",
           app(x + 6, y + 2.5, 12, name),
           text(x + 23, y + 12.3, label, 11, TEXT, anchor='start')]
    cx, cy = x + w - 10, y + 8.5
    out.append(f"<path d='M{cx - 2.6} {cy - 2.6} l5.2 5.2 M{cx + 2.6} {cy - 2.6} l-5.2 5.2' stroke='{TEXT}' "
               f"stroke-opacity='{1 if hot else 0.45}' stroke-width='1.3' stroke-linecap='round'/>")
    return '\n'.join(out), w


def relation(x, y, apps, hover=None):
    out = [text(x, y + 12.3, RELATION, 11, SECOND, anchor='start')]
    cx = x + RELATION_W
    ends = {}
    for name in apps:
        t, tw = token(cx, y, name, name == hover)
        out.append(t)
        ends[name] = cx + tw
        cx += tw + 5
    return '\n'.join(out), ends


def header(x, y, w, apps, hover=None):
    out = [tile(x + 14, y + 10, 32)]
    tx = x + 56
    ends = {}
    if not apps:
        out.append(text(tx, y + 31.5, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    else:
        out.append(text(tx, y + 23, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
        r, ends = relation(tx, y + 29.5, apps, hover)
        out.append(r)
    out.append(pencil(x + w - 60, y + 19))
    out.append(star(x + w - 24, y + 26))
    return '\n'.join(out), ends


def mark(cx, cy, n):
    """A board annotation, not part of the app: which copy this is."""
    return (f"<circle cx='{cx}' cy='{cy}' r='10' fill='{ACCENT}' stroke='{DESK}' stroke-width='2'/>"
            + text(cx, cy + 4.2, n, 12, ON_ACCENT, weight=700))


def pinned(x, y, clip_id, apps=(), marks=True):
    w, bar = 400, 28
    rows = [('username', 'ada@northwind.example', False), ('password', '••••••••••••••••', False),
            ('website', 'https://sso.northwind.example', True)]
    h = bar + 52 + 38 * len(rows)
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10'/></clipPath>",
           f"<g filter='url(#shadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>"]
    for i in range(3):
        out.append(f"<circle cx='{x + 14 + i * 20}' cy='{y + 14}' r='6' fill='#D9D4CC' stroke='#C4BEB5' stroke-width='0.5'/>")
    out.append(text(x + w / 2, y + 18.5, 'Northwind SSO', 13, '#A39A8E', weight=600))
    hd, _ = header(x, y + bar, w, apps)
    out.append(hd)
    ry = y + bar + 52
    for label, value, accent in rows:
        out.append(row(x, ry, w, label, value, tint=(label == 'password'), accent=accent))
        ry += 38
    out.append('</g>')
    if marks:
        out.append(mark(x + w, y + bar + 52 + 19, '1'))
        out.append(mark(x + w, y + bar + 52 + 38 + 19, '2'))
    return '\n'.join(out), h


def button(x, y, w, label):
    """The product's quiet compact button."""
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='21' rx='5' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>"
            + text(x + w / 2, y + 15, label, 11.5, TEXT, weight=500))


def bubble(x, y, message, action, width):
    """Opaque card, hairline, the account's icon carrying the app's as its mark, one line, one button."""
    h = 44
    bw = 50
    out = [f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
           f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
           tile(x + 12, y + 8, 24),
           f"<rect x='{x + 27.5}' y='{y + 23.5}' width='15' height='15' rx='4' fill='{SURFACE}'/>",
           app(x + 29, y + 25, 12),
           text(x + 52, y + 26.5, message, 13, TEXT, weight=500, anchor='start'),
           button(x + width - bw - 12, y + 11, bw, action)]
    return '\n'.join(out)


def strip(x, y, clip_id, apps, hover=None):
    w, h = 400, 52
    hd, ends = header(x, y, w, apps, hover)
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>", hd, '</g>']
    if hover:
        px, py = ends[hover] - 6, y + 29.5 + 13
        out.append(f"<path d='M{px} {py} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111' stroke='#FFF' stroke-width='1'/>")
    return '\n'.join(out)


def after(x, y, clip_id, apps):
    """Only the line that changed."""
    w, h = 400, 30
    r, _ = relation(x + 56, y + 6.5, apps)
    return (f"<rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/>" + r)


def step(x, y, number, title, size=16):
    return (f"<circle cx='{x + 9}' cy='{y - 5}' r='10' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 9, y - 0.8, number, 12, ACCENT, weight=700)
            + text(x + 28, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def note(x, y, s, strong=False):
    return text(x, y, s, 12, LABEL_STRONG if strong else LABEL, weight=500 if strong else 400, anchor='start')


def board():
    W, H = 1560, 716
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, 'Accounts remember where you use them', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]
    top = 152

    # 1. The two copies, then the bubble.
    x1 = 56
    out.append(step(x1, 118, '1', 'Copy both fields while Harbor is active'))
    out.append(app_window(x1, top, 300, 250, 'w1'))
    p, ph = pinned(x1 + 44, top + 150, 'p1')
    out.append(p)
    out.append(text(x1 + 44, top + 150 + ph + 26, 'In either order, from any PasswordPie window or shortcut.', 12, LABEL, anchor='start'))
    by = top + 150 + ph + 58
    out.append(bubble(x1 + 22, by, 'Northwind SSO now appears first in Harbor', 'Undo', 400))
    out.append(f"<rect x='{x1}' y='{by + 62}' width='444' height='1.5' fill='#5B6068'/>")
    out.append(text(x1 + 222, by + 82, 'bottom of the screen  ·  6 seconds  ·  never takes the keyboard', 11.5, LABEL))

    # 2. The result.
    x2 = 572
    out.append(step(x2, 118, '2', 'Next time, this account appears first', size=19))
    out.append(app_window(x2, top, 420, 400, 'w2'))
    m, mh = menu(x2 + 60, top + 150, 'm2')
    out.append(m)
    ny = top + 400 + 36
    out.append(note(x2, ny, 'Only while Harbor is in front.', strong=True))
    out.append(note(x2, ny + 20, 'Return copies the username. The shortcuts copy the rest.'))

    # 3. The way back.
    x3 = 1076
    out.append(step(x3, 118, '3', 'Remove an app from the account'))
    out.append(strip(x3, top, 'h1', ('harbor', 'ledger'), hover='harbor'))
    out.append(f"<path d='M{x3 + 200} {top + 66} v22 m-5 -6 l5 6 l5 -6' fill='none' stroke='#5B6068' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/>")
    out.append(after(x3, top + 102, 'h2', ('ledger',)))
    out.append(note(x3, top + 186, 'After Undo or removal, copying both fields', strong=True))
    out.append(note(x3, top + 206, 'asks before linking again.', strong=True))
    out.append(bubble(x3, top + 226, 'Show Northwind SSO first in Harbor again?', 'Link', 400))
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    with open(os.path.join(target, 'app-link.svg'), 'w') as f:
        f.write(board())

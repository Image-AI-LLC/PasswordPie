"""Round 4 board: the story as two scenes, the way back as one compact line of full headers."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from board1 import (defs, tile, app, pencil, star, row, app_window, text, pie, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT,
                    BORDER, DESK, LABEL, LABEL_STRONG, ROUND, ACCENT_TEXT, FIELD, INK)
from board3 import button, mark

NAMES = {'harbor': ('Harbor', 36), 'ledger': ('Ledger', 35)}
RELATION = 'Shown first in'
RELATION_W = 78
HEADER_H = 60


def token(x, y, name, hot=False):
    label, lw = NAMES[name]
    w, h = 6 + 12 + 5 + lw + 6 + 7 + 6, 18
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' fill='{FIELD if hot else 'none'}' "
           f"stroke='{INK}' stroke-opacity='{0.45 if hot else 0.25}'/>",
           app(x + 6, y + 3, 12, name),
           text(x + 23, y + 12.8, label, 11, TEXT, anchor='start')]
    cx, cy = x + w - 9.5, y + 9
    out.append(f"<path d='M{cx - 2.5} {cy - 2.5} l5 5 M{cx + 2.5} {cy - 2.5} l-5 5' stroke='{TEXT}' "
               f"stroke-opacity='0.6' stroke-width='1.2' stroke-linecap='round'/>")
    return '\n'.join(out), w


def header(x, y, w, apps, hover=None):
    """52 pt without a link; 60 pt with the line, so it has air above the first field."""
    out = [tile(x + 14, y + (14 if apps else 10), 32)]
    tx = x + 56
    ends = {}
    if not apps:
        out.append(text(tx, y + 31.5, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    else:
        out.append(text(tx, y + 24, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
        out.append(text(tx, y + 45.8, RELATION, 11, SECOND, anchor='start'))
        cx = tx + RELATION_W
        for name in apps:
            t, tw = token(cx, y + 33, name, name == hover)
            out.append(t)
            ends[name] = cx + tw
            cx += tw + 6
    cy = y + (HEADER_H if apps else 52) / 2
    out.append(pencil(x + w - 60, cy - 7))
    out.append(star(x + w - 24, cy))
    return '\n'.join(out), ends


def pinned(x, y, clip_id):
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
    hd, _ = header(x, y + bar, w, ())
    out.append(hd)
    ry = y + bar + 52
    for label, value, accent in rows:
        out.append(row(x, ry, w, label, value, tint=(label == 'password'), accent=accent))
        ry += 38
    out.append('</g>')
    out.append(mark(x + w - 22, y + bar + 52 + 19, '1'))
    out.append(mark(x + w - 22, y + bar + 52 + 38 + 19, '2'))
    return '\n'.join(out), h


def bubble(x, y, message, action, width, bw=50):
    h = 44
    out = [f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
           f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
           tile(x + 12, y + 8, 24),
           f"<rect x='{x + 27.5}' y='{y + 23.5}' width='15' height='15' rx='4' fill='{SURFACE}'/>",
           app(x + 29, y + 25, 12),
           text(x + 52, y + 26.5, message, 13, TEXT, weight=500, anchor='start'),
           button(x + width - bw - 12, y + 11, bw, action)]
    return '\n'.join(out)


def menu(x, y, clip_id):
    """The menu over Harbor: the group's header carries the app's icon and name."""
    w = 300
    rows = [('group', 'HARBOR'), ('entry', 'Northwind SSO'), ('sep',), ('sub', 'Password Generator', 'key'), ('sep',),
            ('sub', 'Logins', 'lock'), ('sep',), ('sub', 'Folders', 'folder'), ('sep',), ('sub', 'Tags', 'tag')]
    heights = {'group': 16, 'entry': 21, 'sep': 11, 'sub': 21}
    h = 45 + sum(heights[r[0]] for r in rows) + 5
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='5'/></clipPath>",
           f"<g filter='url(#shadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='5' fill='{SURFACE}'/></g>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           pie(x + 20, y + 20, 32),
           f"<rect x='{x + 40}' y='{y + 9}' width='1.5' height='22' fill='{ACCENT_TEXT}'/>",
           text(x + 44, y + 26.5, 'Search PasswordPie', 18, SECOND, anchor='start'),
           f"<circle cx='{x + w - 19}' cy='{y + 20}' r='6.5' fill='none' stroke='{SECOND}' stroke-width='3' stroke-dasharray='3.2 1.9'/>",
           f"<circle cx='{x + w - 19}' cy='{y + 20}' r='5' fill='{SECOND}'/>",
           f"<circle cx='{x + w - 19}' cy='{y + 20}' r='2' fill='{SURFACE}'/>"]
    cy = y + 45
    tints = {'key': '#8B7A69', 'lock': '#8B7A69', 'folder': '#D18A32', 'tag': '#6F9A58'}
    for r in rows:
        kind = r[0]
        if kind == 'group':
            out.append(f"<rect x='{x}' y='{cy}' width='{w}' height='16' fill='{INK}' fill-opacity='0.03'/>")
            out.append(f"<rect x='{x}' y='{cy}' width='{w}' height='1' fill='{INK}' fill-opacity='0.2'/>")
            out.append(f"<rect x='{x}' y='{cy + 15}' width='{w}' height='1' fill='{INK}' fill-opacity='0.2'/>")
            out.append(app(x + 6, cy + 2.5, 11))
            out.append(text(x + 22, cy + 12, r[1], 11, SECOND, anchor='start'))
        elif kind == 'entry':
            out.append(f"<rect x='{x}' y='{cy}' width='{w}' height='21' fill='{ACCENT}'/>")
            out.append(tile(x + 16, cy + 2.5, 16))
            out.append(text(x + 38, cy + 15.5, r[1], 14, ON_ACCENT, anchor='start'))
            out.append(f"<path d='M{x + w - 26} {cy + 5.5} l8.5 5 l-8.5 5 z' fill='{ON_ACCENT}'/>")
        elif kind == 'sep':
            out.append(f"<rect x='{x}' y='{cy + 5}' width='{w}' height='1' fill='{INK}' fill-opacity='0.25'/>")
        else:
            out.append(f"<rect x='{x + 17}' y='{cy + 4}' width='14' height='13' rx='3' fill='{tints[r[2]]}'/>")
            out.append(text(x + 38, cy + 15.5, r[1], 14, TEXT, anchor='start'))
            out.append(f"<path d='M{x + w - 26} {cy + 5.5} l8.5 5 l-8.5 5 z' fill='#A89A8A'/>")
        cy += heights[kind]
    out.append('</g>')
    return '\n'.join(out), h


def strip(x, y, clip_id, apps, hover=None):
    w, h = 400, HEADER_H
    hd, ends = header(x, y, w, apps, hover)
    out = [f"<rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/>", hd]
    if hover:
        px, py = ends[hover] - 11, y + 33 + 11
        out.append(f"<path d='M{px} {py} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111' stroke='#FFF' stroke-width='1'/>")
    return '\n'.join(out)


def step(x, y, number, title, size):
    return (f"<circle cx='{x + 10}' cy='{y - size * 0.34}' r='10.5' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 10, y - size * 0.34 + 4.3, number, 12, ACCENT, weight=700)
            + text(x + 30, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def board():
    W, H = 1560, 756
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, 'Accounts remember where you use them', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]
    top = 156

    # Scene 1: Harbor is the active window; the pinned account floats beside it.
    x1 = 56
    out.append(step(x1, 122, '1', 'Copy both fields while Harbor is active', 17))
    out.append(app_window(x1, top, 380, 330, 'w1'))
    p, ph = pinned(x1 + 322, top + 70, 'p1')
    out.append(p)
    out.append(bubble(x1 + 151, top + 330 + 34, 'Northwind SSO is now shown first in Harbor', 'Undo', 420))

    # Scene 2: the result.
    x2 = 860
    out.append(step(x2, 122, '2', 'Next time, this account is first', 21))
    out.append(app_window(x2, top, 380, 330, 'w2'))
    m, mh = menu(x2 + 300, top + 70, 'm2')
    out.append(m)
    out.append(text(x2, top + 330 + 62, 'Only while Harbor is in front.', 13, LABEL_STRONG, weight=500, anchor='start'))

    # The way back, compact.
    y3 = 640
    out.append(f"<rect x='56' y='{y3 - 54}' width='{W - 112}' height='1' fill='#34363C'/>")
    out.append(text(56, y3 - 18, 'Take it back any time', 14, LABEL_STRONG, weight=600, anchor='start'))
    out.append(strip(56, y3, 'h1', ('harbor', 'ledger'), hover='harbor'))
    ax = 56 + 400 + 14
    out.append(f"<path d='M{ax} {y3 + 30} h22 m-6 -5 l6 5 l-6 5' fill='none' stroke='#6B7079' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/>")
    out.append(strip(56 + 450, y3, 'h2', ('ledger',)))
    bx = 56 + 450 + 400 + 62
    out.append(text(bx, y3 - 18, 'After Undo or removal, the same two copies ask first', 12, LABEL, anchor='start'))
    out.append(bubble(bx, y3 + 8, 'Show Northwind SSO first in Harbor?', 'Show first', 420, bw=76))
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    with open(os.path.join(target, 'app-link.svg'), 'w') as f:
        f.write(board())

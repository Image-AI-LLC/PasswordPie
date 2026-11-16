"""Round 6 board: one vocabulary ("shown first"), the front app proved by the menu bar, fewer notes."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from board1 import (defs, tile, app, pencil, star, row, text, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT,
                    BORDER, DESK, LABEL, LABEL_STRONG, ROUND, FIELD, INK, WINDOW, WINDOW_LINE)
from board1 import pie
from board4 import bubble, menu, RELATION, RELATION_W, HEADER_H

NAMES = {'harbor': ('Harbor', 36), 'ledger': ('Ledger', 35)}
LINE = '#6B7079'


def token(x, y, name, hot=False):
    """Icon and name, then the close mark with room of its own."""
    label, lw = NAMES[name]
    w, h = 6 + 12 + 5 + lw + 9 + 7 + 7, 18
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' fill='{FIELD if hot else 'none'}' "
           f"stroke='{INK}' stroke-opacity='{0.45 if hot else 0.25}'/>",
           app(x + 6, y + 3, 12, name),
           text(x + 23, y + 12.8, label, 11, TEXT, anchor='start')]
    cx, cy = x + w - 10.5, y + 9
    out.append(f"<path d='M{cx - 2.5} {cy - 2.5} l5 5 M{cx + 2.5} {cy - 2.5} l-5 5' stroke='{TEXT}' "
               f"stroke-opacity='0.6' stroke-width='1.2' stroke-linecap='round'/>")
    return '\n'.join(out), w


def header(x, y, w, apps, hover=None):
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
    rows = [('username', 'ada@northwind.example', False), ('password', '••••••••••••••••', False)]
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
    return '\n'.join(out), h


def harbor(x, y, w, h, clip_id):
    """Just enough of the other app to know it: title bar, icon, and what it is asking for."""
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{WINDOW}'/>",
           f"<rect x='{x}' y='{y}' width='{w}' height='28' fill='#E2E2E2'/>",
           f"<line x1='{x}' y1='{y + 28.5}' x2='{x + w}' y2='{y + 28.5}' stroke='{WINDOW_LINE}'/>"]
    for i, c in enumerate(['#FF5F57', '#FEBC2E', '#28C840']):
        out.append(f"<circle cx='{x + 14 + i * 20}' cy='{y + 14}' r='6' fill='{c}'/>")
    out.append(text(cx, y + 18.5, 'Harbor', 13, '#4A4A4A', weight=600))
    out.append(app(x + 22, y + 46, 30))
    out.append(text(x + 62, y + 66.5, 'Sign in to Harbor', 15, '#1F1F1F', weight=600, anchor='start'))
    out.append('</g>')
    return '\n'.join(out)


def strip(x, y, apps, hover=None):
    w, h = 400, HEADER_H
    hd, ends = header(x, y, w, apps, hover)
    out = [f"<rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/>", hd]
    if hover:
        px, py = ends[hover] - 6, y + 33 + 17
        out.append(f"<path d='M{px} {py} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111' stroke='#FFF' stroke-width='1'/>")
    return '\n'.join(out)


def arrow(x, y, length=26):
    return (f"<path d='M{x} {y} h{length} m-6 -5 l6 5 l-6 5' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def step(x, y, number, title, size=16):
    return (f"<circle cx='{x + 10}' cy='{y - 5.5}' r='10.5' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 10, y - 1.2, number, 12, ACCENT, weight=700)
            + text(x + 30, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def menubar(x, y, w):
    """The system's own word for which app is in front."""
    return (f"<rect x='{x}' y='{y}' width='{w}' height='22' rx='5' fill='#2B2D33'/>"
            + f"<path d='M{x + 12} {y + 7} a4 4 0 1 0 0.1 0 M{x + 13.5} {y + 4.5} q1.5 0 1.8 -1.8' fill='none' stroke='#E8E4DD' stroke-width='1.2'/>"
            + text(x + 28, y + 15.5, 'Harbor', 12.5, '#F4F1EC', weight=700, anchor='start')
            + text(x + 82, y + 15.5, 'File   Edit   View', 12.5, '#B9B5AE', anchor='start')
            + pie(x + w - 16, y + 11, 14, fill='#E8E4DD', hole='#2B2D33'))


def note(x, y, s, anchor='start'):
    return text(x, y, s, 12, LABEL, anchor=anchor)


def board():
    W, H = 1560, 760
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, 'Accounts remember where you use them', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]
    top = 176
    mid = top + 150

    # 1. Cause: the password copied while the menu bar says Harbor.
    x1 = 56
    out.append(step(x1, 122, '1', 'Copy the password while Harbor is in front'))
    out.append(menubar(x1, top - 30, 480))
    out.append(harbor(x1, top, 320, 190, 'w1'))
    p, ph = pinned(x1 + 80, top + 96, 'p1')
    out.append(p)
    out.append(note(x1 + 80, top + 96 + ph + 28, 'The pinned account floats over Harbor and never takes the keyboard.'))

    # 2. Effect now.
    x2 = x1 + 480 + 56
    out.append(arrow(x2 - 42, mid))
    out.append(step(x2, 122, '2', 'It is now shown first in Harbor'))
    out.append(bubble(x2, top + 70, 'Northwind SSO is now shown first in Harbor', 'Undo', 420))
    s, _ = header(x2, top + 170, 400, ('harbor',))
    out.append(f"<rect x='{x2}' y='{top + 170}' width='400' height='{HEADER_H}' rx='8' fill='{SURFACE}'/>" + s)

    # 3. Effect later.
    x3 = x2 + 420 + 56
    out.append(arrow(x3 - 42, mid))
    out.append(step(x3, 122, '3', 'Next time you open PasswordPie in Harbor', size=16))
    out.append(menubar(x3, top - 30, 376))
    out.append(harbor(x3, top, 320, 190, 'w3'))
    m, mh = menu(x3 + 76, top + 96, 'm3')
    out.append(m)
    out.append(text(x3 + 76, top + 96 + mh + 28, 'Only while Harbor is in front.', 12.5, LABEL_STRONG, weight=500, anchor='start'))

    # The way back.
    y3 = 640
    out.append(f"<rect x='56' y='{y3 - 62}' width='{W - 112}' height='1' fill='#34363C'/>")
    out.append(text(56, y3 - 22, 'After you remove it, PasswordPie asks before showing it first again', 14, LABEL_STRONG, weight=600, anchor='start'))
    out.append(strip(56, y3, ('harbor', 'ledger'), hover='harbor'))
    ax = 56 + 400 + 16
    out.append(arrow(ax, y3 + 30, 150))
    out.append(text(ax + 75, y3 + 20, 'copy it again in Harbor', 11.5, LABEL, anchor='middle'))
    out.append(bubble(ax + 168, y3 + 8, 'Show Northwind SSO first in Harbor again?', 'Show first', 430, bw=76))
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    with open(os.path.join(target, 'app-link.svg'), 'w') as f:
        f.write(board())

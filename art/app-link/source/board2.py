"""Round 2 board: one rule, the result as the main picture, and the way back as close-ups."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from board1 import (defs, tile, app, pencil, star, row, app_window, menu, text, pie, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT,
                 BORDER, DESK, LABEL, LABEL_STRONG, ROUND, SANS, ACCENT_TEXT, FIELD, INK)

NAMES = {'harbor': ('Harbor', 36), 'ledger': ('Ledger', 35)}
RELATION = 'Shown first in'
RELATION_W = 76


def token(x, y, name, state='rest'):
    """One linked app: icon and name in a hairline well. Under the pointer the icon turns into a close mark."""
    label, lw = NAMES[name]
    w, h = 6 + 12 + 5 + lw + 7, 17
    hot = state == 'hover'
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' fill='{FIELD if hot else 'none'}' "
           f"stroke='{INK}' stroke-opacity='{0.55 if hot else 0.25}'/>"]
    if hot:
        cx, cy = x + 12, y + 8.5
        out.append(f"<path d='M{cx - 3} {cy - 3} l6 6 M{cx + 3} {cy - 3} l-6 6' stroke='{TEXT}' stroke-width='1.4' stroke-linecap='round'/>")
    else:
        out.append(app(x + 6, y + 2.5, 12, name))
    out.append(text(x + 23, y + 12.3, label, 11, TEXT, anchor='start'))
    return '\n'.join(out), w


def header(x, y, w, apps, hover=None):
    """The account's header, 52 pt, with the relation line under the title."""
    out = [tile(x + 14, y + 10, 32)]
    tx = x + 56
    if not apps:
        out.append(text(tx, y + 31.5, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    else:
        out.append(text(tx, y + 23, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
        out.append(text(tx, y + 41.8, RELATION, 11, SECOND, anchor='start'))
        cx = tx + RELATION_W
        for name in apps:
            t, tw = token(cx, y + 29.5, name, 'hover' if name == hover else 'rest')
            out.append(t)
            cx += tw + 5
    out.append(pencil(x + w - 60, y + 19))
    out.append(star(x + w - 24, y + 26))
    return '\n'.join(out)


def pinned(x, y, clip_id, apps=('harbor',), copied='password', hover=None):
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
    out.append(header(x, y + bar, w, apps, hover))
    ry = y + bar + 52
    for label, value, accent in rows:
        out.append(row(x, ry, w, label, value, tint=(label == copied), accent=accent))
        ry += 38
    out.append('</g>')
    return '\n'.join(out), h


def strip(x, y, clip_id, apps, hover=None, pointer=None):
    """A close-up of the header alone: the top of the details, cut under the first field's label."""
    w, h = 400, 78
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           header(x, y, w, apps, hover),
           f"<rect x='{x}' y='{y + 52}' width='{w}' height='0.5' fill='{INK}' fill-opacity='0.1'/>",
           text(x + 14, y + 67, 'username', 10, SECOND, anchor='start'),
           f"<rect x='{x}' y='{y + 70}' width='{w}' height='8' fill='url(#fade)'/>",
           '</g>']
    if pointer:
        px, py = pointer
        out.append(f"<path d='M{px} {py} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111' stroke='#FFF' stroke-width='1'/>")
    return '\n'.join(out)


def bubble(x, y, message, action, width):
    h = 44
    out = [f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
           f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
           tile(x + 14, y + 12, 20),
           f"<path d='M{x + 40} {y + 18} l4 4 l-4 4' fill='none' stroke='{SECOND}' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/>",
           app(x + 50, y + 12, 20),
           text(x + 82, y + 26.5, message, 13, TEXT, weight=500, anchor='start'),
           f"<rect x='{x + width - 66}' y='{y + 10.5}' width='52' height='23' rx='11.5' fill='{ACCENT}' fill-opacity='0.2' stroke='{ACCENT}'/>",
           text(x + width - 40, y + 26, action, 11, ACCENT_TEXT, weight=500, spacing=0.3)]
    return '\n'.join(out)


def screen(x, y, scale, clip_id):
    """The whole display, small: Harbor, the pinned account, and where the bubble lands."""
    w, h = 900, 580
    inner = [f"<clipPath id='{clip_id}'><rect x='0' y='0' width='{w}' height='{h}' rx='14'/></clipPath>",
             f"<g clip-path='url(#{clip_id})'>",
             f"<rect width='{w}' height='{h}' fill='#3A4658'/>",
             f"<rect width='{w}' height='24' fill='#000' fill-opacity='0.28'/>",
             text(16, 16.5, 'Harbor', 12, '#FFFFFF', weight=600, anchor='start'),
             pie(w - 120, 12, 15, fill='#FFFFFF', hole='#3A4658'),
             app_window(110, 70, 380, 330, clip_id + 'w')]
    p, ph = pinned(470, 110, clip_id + 'p')
    inner.append(p)
    bw = 430
    inner.append(bubble((w - bw) / 2, h - 44 - 36, 'Northwind SSO is shown first in Harbor', 'Undo', bw))
    inner.append('</g>')
    inner.append(f"<rect x='0.75' y='0.75' width='{w - 1.5}' height='{h - 1.5}' rx='14' fill='none' stroke='#5B6068' stroke-width='1.5'/>")
    return f"<g transform='translate({x} {y}) scale({scale})'>" + '\n'.join(inner) + '</g>', w * scale, h * scale


def step(x, y, number, title):
    return (text(x, y, number, 12, ACCENT, weight=700, anchor='start')
            + text(x + 18, y, title, 15, LABEL_STRONG, weight=600, anchor='start'))


def note(x, y, s, strong=False):
    return text(x, y, s, 12, LABEL_STRONG if strong else LABEL, weight=500 if strong else 400, anchor='start')


def state(x, y, s):
    return text(x, y, s, 11, LABEL, weight=600, anchor='start', spacing=0.5)


def board():
    W, H = 1560, 690
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>",
           defs().replace('</defs>', f"<linearGradient id='fade' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='{SURFACE}' "
                          f"stop-opacity='0'/><stop offset='1' stop-color='{DESK}'/></linearGradient></defs>"),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, 'An account remembers its app', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]

    top = 150
    # 1. The rule.
    x1 = 56
    out.append(step(x1, 116, '1', 'Copy the username and the password over one app'))
    s, sw, sh = screen(x1, top, 0.56, 's1')
    out.append(s)
    by = top + sh + 46
    bw = 430
    bx = x1 + (sw - bw) / 2
    mini_y = top + (580 - 44 - 36 + 44) * 0.56
    out.append(f"<path d='M{x1 + sw / 2} {mini_y + 4} V{by - 6}' stroke='#5B6068' stroke-dasharray='2 3'/>")
    out.append(bubble(bx, by, 'Northwind SSO is shown first in Harbor', 'Undo', bw))
    out.append(note(x1, by + 78, 'PasswordPie watches its own copies, not the sign-in. Any window or shortcut, either order.'))
    out.append(note(x1, by + 98, 'The bubble stays 6 seconds at the bottom of the screen and never takes the keyboard.'))

    # 2. The result, large.
    x2 = 640
    out.append(step(x2, 116, '2', 'Next time over Harbor, that account is first'))
    out.append(app_window(x2, top, 400, 390, 'w2'))
    m, mh = menu(x2 + 50, top + 150, 'm2')
    out.append(m)
    ny = top + 390 + 34
    out.append(note(x2, ny, 'Only while Harbor is in front.', strong=True))
    out.append(note(x2, ny + 20, 'Return copies the username; the shortcuts copy the rest.'))

    # 3. The way back.
    x3 = 1104
    out.append(step(x3, 116, '3', 'The link is on the account, and comes off there'))
    out.append(state(x3, top + 12, 'LINKED TO TWO APPS'))
    out.append(strip(x3, top + 24, 'h1', ('harbor', 'ledger')))
    out.append(state(x3, top + 144, 'POINTER ON HARBOR: CLICK TO UNLINK'))
    out.append(strip(x3, top + 156, 'h2', ('harbor', 'ledger'), hover='harbor', pointer=(x3 + 56 + RELATION_W + 34, top + 156 + 41)))
    out.append(state(x3, top + 276, 'UNLINKED'))
    out.append(strip(x3, top + 288, 'h3', ('ledger',)))
    out.append(state(x3, top + 408, 'AFTER AN UNDO OR AN UNLINK, THE SAME COPIES ASK FIRST'))
    out.append(bubble(x3, top + 422, 'Show Northwind SSO first in Harbor?', 'Link', 400))
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    with open(os.path.join(target, 'app-link.svg'), 'w') as f:
        f.write(board())

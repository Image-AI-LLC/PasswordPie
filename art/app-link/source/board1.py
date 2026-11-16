"""Round 1 board: an account that remembers which app it signs in to."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'lock-motion', 'source'))
from gen import pie, text, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT, BORDER, DESK, LABEL, LABEL_STRONG, ROUND, SANS
from paths import RIM, KEY

ACCENT_TEXT = '#A65312'
FIELD = '#FFFFFF'
WINDOW = '#ECECEC'
WINDOW_LINE = '#D2D2D2'
INK = TEXT


def defs():
    return f"""<defs>
  <symbol id='rim' viewBox='0 0 24 24'><path d='{RIM}'/></symbol>
  <symbol id='key' viewBox='0 0 24 24'><path d='{KEY}'/></symbol>
  <symbol id='harbor' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#2457D6'/>
    <path d='M16 6 L16 21 L8 21 Z' fill='#FFFFFF'/>
    <path d='M18 10 L18 21 L24 21 Z' fill='#BFD2FF'/>
    <path d='M6 24 H26' stroke='#FFFFFF' stroke-width='2.2' stroke-linecap='round'/>
  </symbol>
  <symbol id='ledger' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#1F8A5B'/>
    <path d='M9 10 H23 M9 16 H23 M9 22 H18' stroke='#FFFFFF' stroke-width='2.4' stroke-linecap='round'/>
  </symbol>
  <linearGradient id='tileN' x1='0' y1='0' x2='0' y2='1'>
    <stop offset='0' stop-color='#85F2DD'/><stop offset='1' stop-color='#3CC7AB'/>
  </linearGradient>
  <filter id='shadow' x='-20%' y='-20%' width='140%' height='150%'>
    <feDropShadow dx='0' dy='10' stdDeviation='14' flood-color='#000' flood-opacity='0.45'/>
  </filter>
  <filter id='soft' x='-20%' y='-40%' width='140%' height='200%'>
    <feDropShadow dx='0' dy='6' stdDeviation='9' flood-color='#000' flood-opacity='0.35'/>
  </filter>
</defs>"""


def tile(x, y, side, letter='N'):
    r = side * 0.22
    return (f"<rect x='{x}' y='{y}' width='{side}' height='{side}' rx='{r}' fill='url(#tileN)' "
            f"stroke='#000' stroke-opacity='0.25' stroke-width='0.5'/>"
            + text(x + side / 2, y + side * 0.72, letter, side * 0.6, '#FFFFFF', weight=600))


def app(x, y, side, name='harbor', opacity=1):
    return f"<use href='#{name}' x='{x}' y='{y}' width='{side}' height='{side}' opacity='{opacity}'/>"


def pair(x, y, side, ring=SURFACE):
    """The account's tile with the app's icon lapped over its right edge."""
    lap = side * 0.2
    ax = x + side - lap
    return (tile(x, y, side)
            + f"<rect x='{ax - 1.5}' y='{y - 1.5}' width='{side + 3}' height='{side + 3}' rx='{side * 0.26}' fill='{ring}'/>"
            + app(ax, y, side))


def pencil(x, y):
    return (f"<path d='M{x} {y + 11} l1 -3.2 l7.6 -7.6 l2.2 2.2 l-7.6 7.6 z' fill='none' stroke='{SECOND}' "
            f"stroke-width='1.2' stroke-linejoin='round'/>")


def star(cx, cy, r=7.5):
    import math
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * 0.42
        pts.append(f"{cx + rr * math.cos(a):.2f},{cy + rr * math.sin(a):.2f}")
    return f"<polygon points='{' '.join(pts)}' fill='none' stroke='{SECOND}' stroke-width='1.2' stroke-linejoin='round'/>"


def row(x, y, w, label, value, mono=False, tint=None, accent=False, h=38):
    out = []
    if tint:
        out.append(f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{ACCENT}' fill-opacity='0.2'/>")
    out.append(f"<rect x='{x}' y='{y}' width='{w}' height='0.5' fill='{INK}' fill-opacity='0.1'/>")
    out.append(text(x + 14, y + 15, label, 10, SECOND, anchor='start'))
    font = "font-family='SF Mono'" if mono else SANS
    out.append(text(x + 14, y + 31, value, 13, ACCENT_TEXT if accent else TEXT, anchor='start', font=font))
    return '\n'.join(out)


def pinned(x, y, clip_id, link='linked', copied='password', apps=('harbor',)):
    """The pinned window of one account. link: none, offer, linked, hover."""
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
    top = y + bar
    out.append(tile(x + 14, top + 10, 32))
    tx = x + 56
    if link == 'none':
        out.append(text(tx, top + 31.5, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    else:
        out.append(text(tx, top + 24, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
        ly = top + 31
        if link == 'offer':
            out.append(f"<rect x='{tx - 0.5}' y='{ly - 0.5}' width='14' height='14' rx='3.4' fill='none' stroke='{SECOND}' "
                       f"stroke-width='1' stroke-dasharray='2.2 1.8'/>")
            out.append(app(tx + 1.5, ly + 1.5, 10, apps[0], opacity=0.45))
            out.append(text(tx + 19, ly + 10.5, 'Show first in Harbor', 11, ACCENT_TEXT, anchor='start', weight=500))
        else:
            cx = tx
            names = {'harbor': 'Harbor', 'ledger': 'Ledger'}
            widths = {'harbor': 36, 'ledger': 35}
            for i, name in enumerate(apps):
                out.append(app(cx, ly, 13, name))
                out.append(text(cx + 18, ly + 10.5, names[name], 11, TEXT if link == 'hover' and i == 0 else SECOND, anchor='start'))
                cx += 18 + widths[name] + 12
                if link == 'hover' and i == 0:
                    out.append(f"<rect x='{cx - 4}' y='{ly - 2.5}' width='48' height='18' rx='5' fill='{FIELD}' stroke='{BORDER}' stroke-width='0.75'/>")
                    out.append(text(cx + 20, ly + 10.5, 'Unlink', 11, TEXT))
                    cx += 48 + 10
    out.append(pencil(x + w - 60, top + 19))
    out.append(star(x + w - 24, top + 26))
    ry = top + 52
    for label, value, accent in rows:
        out.append(row(x, ry, w, label, value, tint=(label == copied), accent=accent))
        ry += 38
    out.append('</g>')
    return '\n'.join(out), h


def toast(x, y, clip_id):
    w, h = 408, 44
    out = [f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
           f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
           pair(x + 14, y + 12, 20),
           text(x + 62, y + 26.5, 'Northwind SSO now comes first in Harbor', 13, TEXT, weight=500, anchor='start'),
           f"<rect x='{x + w - 66}' y='{y + 10.5}' width='52' height='23' rx='11.5' fill='{ACCENT}' fill-opacity='0.2' stroke='{ACCENT}'/>",
           text(x + w - 40, y + 26, 'Undo', 11, ACCENT_TEXT, weight=500, spacing=0.3)]
    return '\n'.join(out), w, h


def app_window(x, y, w, h, clip_id):
    """Harbor's sign-in window: the other app, drawn quiet."""
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{WINDOW}'/>",
           f"<rect x='{x}' y='{y}' width='{w}' height='28' fill='#E2E2E2'/>",
           f"<line x1='{x}' y1='{y + 28.5}' x2='{x + w}' y2='{y + 28.5}' stroke='{WINDOW_LINE}'/>"]
    for i, c in enumerate(['#FF5F57', '#FEBC2E', '#28C840']):
        out.append(f"<circle cx='{x + 14 + i * 20}' cy='{y + 14}' r='6' fill='{c}'/>")
    out.append(text(cx, y + 18.5, 'Harbor', 13, '#4A4A4A', weight=600))
    out.append(app(cx - 22, y + 58, 44))
    out.append(text(cx, y + 128, 'Sign in to Harbor', 17, '#1F1F1F', weight=600))
    for i, (label, value) in enumerate([('Email', 'ada@northwind.example'), ('Password', '')]):
        fy = y + 150 + i * 44
        focus = i == 1
        out.append(f"<rect x='{cx - 120}' y='{fy}' width='240' height='32' rx='6' fill='#FFFFFF' "
                   f"stroke='{'#2457D6' if focus else '#C9C9C9'}' stroke-width='{2 if focus else 1}'/>")
        if value:
            out.append(text(cx - 110, fy + 21, value, 13, '#1F1F1F', anchor='start'))
        else:
            out.append(f"<rect x='{cx - 110}' y='{fy + 8}' width='1.5' height='16' fill='#1F1F1F'/>")
            out.append(text(cx - 104, fy + 21, label, 13, '#A0A0A0', anchor='start'))
    out.append(f"<rect x='{cx - 120}' y='{y + 244}' width='240' height='32' rx='6' fill='#2457D6'/>")
    out.append(text(cx, y + 265, 'Sign In', 13, '#FFFFFF', weight=600))
    out.append('</g>')
    return '\n'.join(out)


def menu(x, y, clip_id):
    """The menu opened over Harbor: the app's group first."""
    w = 300
    rows = [('group', 'HARBOR'), ('entry', 'Northwind SSO', True), ('sep',),
            ('sub', 'Password Generator', 'key'), ('sep',), ('sub', 'Logins', 'lock'), ('sep',),
            ('sub', 'Folders', 'folder'), ('sep',), ('sub', 'Tags', 'tag')]
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
            out.append(text(x + 6, cy + 12, r[1], 11, SECOND, anchor='start'))
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


def caption(x, y, step, title, note=''):
    out = [text(x, y, step, 10.5, ACCENT, weight=600, anchor='start', spacing=0.6),
           text(x, y + 19, title, 14, LABEL_STRONG, weight=600, anchor='start')]
    if note:
        out.append(text(x, y + 37, note, 11.5, LABEL, anchor='start'))
    return '\n'.join(out)


def board():
    W, H = 1560, 1010
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 62, 'An account remembers its app', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           text(56, 86, 'Copy a username and its password over the same app once. Next time, that account is first.',
                12.5, LABEL, anchor='start')]

    # 1. Learning: pinned window beside Harbor, then the bubble.
    x1, y1 = 56, 170
    out.append(caption(x1, 128, '1  SIGN IN ONCE', 'Username, then password, copied over Harbor'))
    out.append(app_window(x1, y1, 380, 330, 'w1'))
    win, wh = pinned(x1 + 330, y1 + 46, 'p1', link='linked', copied='password')
    out.append(win)
    t, tw, th = toast(x1 + (730 - 408) / 2, y1 + 330 + 34, 't1')
    out.append(t)
    out.append(text(x1, y1 + 330 + 104, 'The bubble sits at the bottom of the screen for 6 seconds and never takes the keyboard.',
                    11.5, LABEL, anchor='start'))

    # 2. Next time.
    x2 = 880
    out.append(caption(x2, 128, '2  NEXT TIME', 'Open PasswordPie over Harbor: its account is first'))
    out.append(app_window(x2, y1, 380, 330, 'w2'))
    m, mh = menu(x2 + 330, y1 + 60, 'm2')
    out.append(m)
    out.append(text(x2, y1 + 330 + 104, 'Return copies the username. The group is there only while Harbor is in front.',
                    11.5, LABEL, anchor='start'))

    # 3. The link line in the account's header.
    y3 = 700
    out.append(f"<line x1='56' y1='{y3 - 60}' x2='{W - 56}' y2='{y3 - 60}' stroke='#34363C'/>")
    out.append(caption(56, y3 - 26, '3  THE LINK IS ON THE ACCOUNT', 'Under the title, where it can be seen and taken back'))
    states = [('offer', ('harbor',), 'After one copy over Harbor: offer', 'username'),
              ('linked', ('harbor',), 'Linked', None),
              ('hover', ('harbor', 'ledger'), 'Pointer on an app: Unlink', None)]
    for i, (link, apps, label, copied) in enumerate(states):
        px = 56 + i * 490
        win, wh = pinned(px, y3 + 30, f'p3{i}', link=link, copied=copied, apps=apps)
        out.append(win)
        out.append(text(px, y3 + 30 + wh + 30, label, 12, LABEL_STRONG, weight=600, anchor='start'))
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    with open(os.path.join(target, 'app-link.svg'), 'w') as f:
        f.write(board())

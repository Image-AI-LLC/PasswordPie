"""Final board (Round 5): approved '+ Add app' unified copy, locked bubble text origin, clean native +/- Preferences bar."""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'lock-motion', 'source'))
from gen import pie, text, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT, BORDER, DESK, LABEL, LABEL_STRONG, ROUND, SANS
from paths import RIM, KEY

ACCENT_TEXT = '#A65312'
FIELD = '#FFFFFF'
INK = TEXT
HEADER_H = 60
LINE = '#6B7079'
DIVIDER = '#34363C'

NAMES = {
    'harbor': ('Harbor', 36),
    'ledger': ('Ledger', 36),
    'relay': ('Relay', 29),
    'teams': ('Microsoft Teams', 88),
}


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
  <symbol id='relay' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#5E4AE3'/>
    <circle cx='16' cy='16' r='7.5' fill='none' stroke='#FFFFFF' stroke-width='2.2'/>
    <circle cx='16' cy='16' r='2.6' fill='#D9D2FF'/>
    <path d='M16 5.5 V8.5 M16 23.5 V26.5 M5.5 16 H8.5 M23.5 16 H26.5' stroke='#D9D2FF' stroke-width='2' stroke-linecap='round'/>
  </symbol>
  <symbol id='teams' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#4B53BC'/>
    <rect x='7' y='9' width='13' height='14' rx='2.4' fill='#FFFFFF' fill-opacity='0.95'/>
    <path d='M10.5 13.5 H16.5 M13.5 13.5 V19.5' stroke='#4B53BC' stroke-width='2.2' stroke-linecap='round'/>
    <circle cx='23.5' cy='12.5' r='2.6' fill='#C6CBFF'/>
    <path d='M21 17 H26 V21.5 A2.5 2.5 0 0 1 21 21.5 Z' fill='#C6CBFF'/>
  </symbol>
  <symbol id='terminal' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#26282E'/>
    <rect x='1' y='1' width='30' height='30' rx='6.4' fill='none' stroke='#505460' stroke-width='1.2'/>
    <path d='M8.5 11.5 L14 16 L8.5 20.5 M16.5 21 H23.5' fill='none' stroke='#E8E4DD' stroke-width='2.3' stroke-linecap='round' stroke-linejoin='round'/>
  </symbol>
  <linearGradient id='tileN' x1='0' y1='0' x2='0' y2='1'>
    <stop offset='0' stop-color='#85F2DD'/><stop offset='1' stop-color='#3CC7AB'/>
  </linearGradient>
  <linearGradient id='tileA' x1='0' y1='0' x2='0' y2='1'>
    <stop offset='0' stop-color='#A7B8F8'/><stop offset='1' stop-color='#5E73D8'/>
  </linearGradient>
  <filter id='shadow' x='-20%' y='-20%' width='140%' height='160%'>
    <feDropShadow dx='0' dy='10' stdDeviation='14' flood-color='#000' flood-opacity='0.45'/>
  </filter>
  <filter id='menuShadow' x='-20%' y='-20%' width='150%' height='160%'>
    <feDropShadow dx='0' dy='8' stdDeviation='12' flood-color='#000' flood-opacity='0.34'/>
  </filter>
  <filter id='soft' x='-20%' y='-40%' width='140%' height='200%'>
    <feDropShadow dx='0' dy='6' stdDeviation='9' flood-color='#000' flood-opacity='0.35'/>
  </filter>
</defs>"""


def tile(x, y, side, letter='N', grad='tileN'):
    r = side * 0.22
    return (f"<rect x='{x}' y='{y}' width='{side}' height='{side}' rx='{r}' fill='url(#{grad})' "
            f"stroke='#000' stroke-opacity='0.22' stroke-width='0.5'/>"
            + text(x + side / 2, y + side * 0.72, letter, side * 0.58, '#FFFFFF', weight=600))


def app(x, y, side, name='harbor', opacity=1):
    return f"<use href='#{name}' x='{x}' y='{y}' width='{side}' height='{side}' opacity='{opacity}'/>"


def pencil(x, y):
    return (f"<path d='M{x} {y + 11} l1 -3.2 l7.6 -7.6 l2.2 2.2 l-7.6 7.6 z' fill='none' stroke='{SECOND}' "
            f"stroke-width='1.2' stroke-linejoin='round'/>")


def pin_icon(x, y):
    return (f"<g transform='translate({x + 6},{y + 6}) rotate(45)' fill='none' stroke='{SECOND}' stroke-width='1.15' stroke-linecap='round' stroke-linejoin='round'>"
            f"<path d='M-2.6 -5.2 H2.6 M-1.9 -5.2 L-1.6 -0.8 L-3.6 1.2 H3.6 L1.6 -0.8 L1.9 -5.2 M0 1.2 V5.4'/>"
            f"</g>")


def star(cx, cy, r=7.2):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * 0.42
        pts.append(f"{cx + rr * math.cos(a):.2f},{cy + rr * math.sin(a):.2f}")
    return f"<polygon points='{' '.join(pts)}' fill='none' stroke='{SECOND}' stroke-width='1.2' stroke-linejoin='round'/>"


def chevron_down(cx, cy, color, opacity=0.75):
    return (f"<path d='M{cx - 2.6} {cy - 1.2} l2.6 2.6 l2.6 -2.6' fill='none' stroke='{color}' "
            f"stroke-opacity='{opacity}' stroke-width='1.25' stroke-linecap='round' stroke-linejoin='round'/>")


def pointer(x, y):
    return f"<path d='M{x} {y} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111111' stroke='#FFFFFF' stroke-width='1.1'/>"


def token(x, y, name, hot=False):
    label, lw = NAMES[name]
    w, h = 6 + 12 + 5 + lw + 7 + 7 + 6, 18
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
           f"fill='{FIELD if hot else 'none'}' stroke='{INK}' stroke-opacity='{0.45 if hot else 0.25}'/>",
           app(x + 6, y + 3, 12, name),
           text(x + 23, y + 12.8, label, 11, TEXT, anchor='start')]
    cx, cy = x + w - 9.5, y + 9
    out.append(f"<path d='M{cx - 2.4} {cy - 2.4} l4.8 4.8 M{cx + 2.4} {cy - 2.4} l-4.8 4.8' stroke='{TEXT}' "
               f"stroke-opacity='{1 if hot else 0.55}' stroke-width='1.2' stroke-linecap='round'/>")
    return '\n'.join(out), w


def empty_cta(x, y, hot=False, active=False):
    """Quiet, compact empty-state trigger: '+ Add app' (8pt symmetric horizontal padding)."""
    w, h = 72, 18
    if active:
        fill, stroke, s_op, fg = FIELD, ACCENT_TEXT, 0.85, TEXT
    elif hot:
        fill, stroke, s_op, fg = FIELD, INK, 0.45, TEXT
    else:
        fill, stroke, s_op, fg = 'none', INK, 0.25, SECOND
    cy = y + h / 2
    px = x + 11.5
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}' stroke-width='{1.2 if active else 1}'/>",
        f"<path d='M{px - 3.2} {cy} H{px + 3.2} M{px} {cy - 3.2} V{cy + 3.2}' "
        f"stroke='{fg}' stroke-width='1.3' stroke-linecap='round'/>",
        text(x + 20, y + 12.8, 'Add app', 11, fg, weight=500 if active else 400, anchor='start'),
    ]
    return '\n'.join(out), w


def overflow_pill(x, y, count, active=False):
    w, h = 64, 18
    cy = y + h / 2
    fill = FIELD if active else 'none'
    stroke = ACCENT_TEXT if active else INK
    s_op = 0.85 if active else 0.25
    fg = TEXT if active else SECOND
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}' stroke-width='{1.2 if active else 1}'/>",
        text(x + 8, y + 12.8, f'{count} more', 11, fg, weight=500 if active else 400, anchor='start'),
        chevron_down(x + w - 10.5, cy + 0.3, fg, opacity=0.85 if active else 0.75),
    ]
    return '\n'.join(out), w


def plus_button(x, y, hot=False, active=False):
    w, h = 24, 18
    if active:
        fill, stroke, s_op, fg = FIELD, ACCENT_TEXT, 0.85, TEXT
    elif hot:
        fill, stroke, s_op, fg = FIELD, INK, 0.45, TEXT
    else:
        fill, stroke, s_op, fg = 'none', INK, 0.25, SECOND
    cx, cy = x + w / 2, y + h / 2
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}' stroke-width='{1.2 if active else 1}'/>",
        f"<path d='M{cx - 3.6} {cy} H{cx + 3.6} M{cx} {cy - 3.6} V{cy + 3.6}' "
        f"stroke='{fg}' stroke-width='1.35' stroke-linecap='round'/>",
    ]
    return '\n'.join(out), w


def header(x, y, w, apps=(), hover_app=None, plus_hot=False, plus_active=False, overflow=0, overflow_active=False):
    out = [tile(x + 14, y + 14, 32)]
    tx = x + 56
    out.append(text(tx, y + 24, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    cy1 = y + 19
    out.append(pencil(x + w - 76, cy1 - 6))
    out.append(pin_icon(x + w - 51, cy1 - 6))
    out.append(star(x + w - 22, cy1))

    ends = {}
    if not apps:
        cta, cw = empty_cta(tx, y + 33, hot=plus_hot, active=plus_active)
        out.append(cta)
        ends['+'] = (tx, tx + cw)
    else:
        out.append(text(tx, y + 45.8, 'Shown first in', 11, SECOND, anchor='start'))
        cx = tx + 78
        for name in apps:
            t, tw = token(cx, y + 33, name, hot=(name == hover_app))
            out.append(t)
            ends[name] = (cx, cx + tw)
            cx += tw + 6
        if overflow > 0:
            op, ow = overflow_pill(cx, y + 33, overflow, active=overflow_active)
            out.append(op)
            ends['overflow'] = (cx, cx + ow)
            cx += ow + 6
        pb, pw = plus_button(cx, y + 33, hot=plus_hot, active=plus_active)
        out.append(pb)
        ends['+'] = (cx, cx + pw)
    return '\n'.join(out), ends


def details_card(x, y, clip_id, apps=(), hover_app=None, plus_hot=False, plus_active=False, dim_rows=False):
    w = 400
    rows = [
        ('username', 'ada@northwind.example', False),
        ('password', '••••••••••••••••', False),
        ('website', 'https://sso.northwind.example', True),
        ('tags', 'work, sso', False),
    ]
    h = HEADER_H + 38 * len(rows)
    out = [
        f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10'/></clipPath>",
        f"<g filter='url(#shadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<g clip-path='url(#{clip_id})'>",
        f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
    ]
    hd, ends = header(x, y, w, apps=apps, hover_app=hover_app, plus_hot=plus_hot, plus_active=plus_active)
    out.append(hd)
    ry = y + HEADER_H
    if dim_rows:
        out.append("<g opacity='0.52'>")
    for label, value, accent in rows:
        out.append(f"<rect x='{x}' y='{ry}' width='{w}' height='0.5' fill='{INK}' fill-opacity='0.1'/>")
        out.append(text(x + 14, ry + 14.5, label, 10, SECOND, anchor='start'))
        out.append(text(x + 14, ry + 30.5, value, 13, ACCENT_TEXT if accent else TEXT, anchor='start'))
        ry += 38
    if dim_rows:
        out.append("</g>")
    out.append('</g>')
    out.append(f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='10' fill='none' stroke='{BORDER}' stroke-opacity='0.55'/>")
    return '\n'.join(out), h, ends


def header_strip(x, y, apps=(), hover_app=None, plus_hot=False, overflow=0, overflow_active=False):
    w, h = 400, HEADER_H
    hd, ends = header(x, y, w, apps=apps, hover_app=hover_app, plus_hot=plus_hot, overflow=overflow, overflow_active=overflow_active)
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        hd,
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='none' stroke='{BORDER}' stroke-opacity='0.55'/>",
    ]
    if hover_app and hover_app in ends:
        _, ex = ends[hover_app]
        out.append(pointer(ex - 9, y + 33 + 13))
    return '\n'.join(out), ends


def picker_popover(x, y, w=256):
    h = 6 + 26 + 9 + 20 + 26 + 26 + 9 + 26 + 22 + 6
    out = [
        f"<g filter='url(#menuShadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='{SURFACE}' stroke='{BORDER}'/>",
    ]
    cy = y + 6

    out.append(f"<rect x='{x + 5}' y='{cy}' width='{w - 10}' height='26' rx='5' fill='{ACCENT}'/>")
    out.append(app(x + 12, cy + 5, 16, 'teams'))
    out.append(text(x + 35, cy + 17.2, 'Microsoft Teams', 13, ON_ACCENT, weight=500, anchor='start'))
    out.append(text(x + w - 13, cy + 16.8, 'Active app', 11, ON_ACCENT, opacity=0.88, anchor='end'))
    hover_y = cy
    cy += 26

    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    out.append(text(x + 12, cy + 13.5, 'Running apps', 11, SECOND, weight=500, anchor='start'))
    cy += 20

    out.append(app(x + 12, cy + 5, 16, 'harbor'))
    out.append(text(x + 35, cy + 17.2, 'Harbor', 13, TEXT, anchor='start'))
    cy += 26

    out.append(app(x + 12, cy + 5, 16, 'relay'))
    out.append(text(x + 35, cy + 17.2, 'Relay', 13, TEXT, anchor='start'))
    out.append(text(x + w - 13, cy + 16.8, 'Removed earlier', 10.5, SECOND, opacity=0.82, anchor='end'))
    cy += 26

    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    out.append(text(x + 35, cy + 17.2, 'Choose App…', 13, TEXT, anchor='start'))
    cy += 26

    out.append(text(x + 12, cy + 14.5, 'Browsers aren’t listed — they match by site', 10.5, SECOND, opacity=0.78, anchor='start'))
    out.append(pointer(x + 150, hover_y + 16))
    return '\n'.join(out), h


def overflow_popover(x, y, w=206):
    items = [('teams', 'Microsoft Teams'), ('harbor', 'Harbor'), ('ledger', 'Ledger')]
    h = 6 + 18 + len(items) * 26 + 6
    out = [
        f"<g filter='url(#menuShadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='{SURFACE}' stroke='{BORDER}'/>",
        text(x + 12, y + 18, 'Shown first in', 10.5, SECOND, weight=600, anchor='start'),
    ]
    cy = y + 24
    for i, (key, name) in enumerate(items):
        hot = (i == 1)
        out.append(app(x + 12, cy + 5, 16, key))
        out.append(text(x + 35, cy + 17, name, 12.5, TEXT, anchor='start'))
        rx, ry = x + w - 18, cy + 13
        if hot:
            out.append(f"<rect x='{rx - 9}' y='{ry - 9}' width='18' height='18' rx='4' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>")
        out.append(f"<path d='M{rx - 3} {ry - 3} l6 6 M{rx + 3} {ry - 3} l-6 6' stroke='{TEXT}' stroke-opacity='{1.0 if hot else 0.45}' stroke-width='1.3' stroke-linecap='round'/>")
        cy += 26
    return '\n'.join(out), h


def quiet_button(x, y, w, label):
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='21' rx='5' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>"
            + text(x + w / 2, y + 15, label, 11.5, TEXT, weight=500))


def auto_add_bubble(x, y, title='Admin API', app_name='relay', label='Relay', width=400):
    h = 44
    bw = 48
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
        tile(x + 12, y + 9, 24, letter='A', grad='tileA'),
        f"<rect x='{x + 27.5}' y='{y + 24.5}' width='14' height='14' rx='3.8' fill='{SURFACE}'/>",
        app(x + 29, y + 26, 11, app_name),
        # Locked leading text origin at x + 50 across both bubbles
        text(x + 50, y + 26.5, f'{title} is now shown first in {label}', 12.5, TEXT, weight=500, anchor='start'),
        quiet_button(x + width - bw - 11, y + 11.5, bw, 'Undo'),
        pointer(x + width - 19, y + 27),
    ]
    return '\n'.join(out)


def stopped_bubble(x, y, app_name='relay', label='Relay', width=400):
    h = 44
    bw = 94
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
        app(x + 12, y + 9, 24, app_name),
        f"<circle cx='{x + 34.5}' cy='{y + 31.5}' r='7.2' fill='{SURFACE}'/>",
        f"<circle cx='{x + 34.5}' cy='{y + 31.5}' r='5.4' fill='none' stroke='{SECOND}' stroke-width='1.5'/>",
        f"<path d='M{x + 30.8} {y + 27.8} l7.4 7.4' stroke='{SECOND}' stroke-width='1.5' stroke-linecap='round'/>",
        # Same leading text origin x + 50 — zero jump on swap!
        text(x + 50, y + 26.5, f'Stopped adding {label} automatically', 12.5, TEXT, weight=500, anchor='start'),
        quiet_button(x + width - bw - 11, y + 11.5, bw, 'Turn Back On'),
    ]
    return '\n'.join(out)


def preferences_card(x, y, w=400, h=172):
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}' stroke-opacity='0.65'/>",
        text(x + 16, y + 21, 'Preferences › General', 10.5, SECOND, opacity=0.8, anchor='start'),
        text(x + 16, y + 40, "Don't add automatically", 12, TEXT, weight=600, anchor='start'),
    ]
    lx, ly, lw, lh = x + 16, y + 50, w - 32, 86
    out.append(f"<rect x='{lx + 0.5}' y='{ly + 0.5}' width='{lw - 1}' height='{lh - 1}' rx='6' fill='{FIELD}' stroke='{BORDER}'/>")
    r1 = ly
    out.append(f"<rect x='{lx + 1}' y='{r1 + 1}' width='{lw - 2}' height='30' rx='5' fill='{ACCENT}' fill-opacity='0.14'/>")
    out.append(app(lx + 10, r1 + 6, 18, 'relay'))
    out.append(text(lx + 36, r1 + 20, 'Relay', 12.5, TEXT, weight=500, anchor='start'))
    out.append(text(lx + lw - 10, r1 + 19.5, 'After 3 undos', 10.5, SECOND, anchor='end'))
    out.append(f"<rect x='{lx + 1}' y='{r1 + 31}' width='{lw - 2}' height='0.75' fill='{INK}' fill-opacity='0.09'/>")
    r2 = ly + 31
    out.append(app(lx + 10, r2 + 6, 18, 'terminal'))
    out.append(text(lx + 36, r2 + 20, 'Terminal', 12.5, TEXT, anchor='start'))
    out.append(text(lx + lw - 10, r2 + 19.5, 'Excluded manually', 10.5, SECOND, anchor='end'))
    bar_y = ly + 62
    out.append(f"<rect x='{lx + 1}' y='{bar_y}' width='{lw - 2}' height='0.75' fill='{INK}' fill-opacity='0.12'/>")
    out.append(f"<path d='M{lx + 10} {bar_y + 12} h8 M{lx + 14} {bar_y + 8} v8' stroke='{TEXT}' stroke-width='1.3' stroke-linecap='round'/>")
    out.append(f"<rect x='{lx + 28}' y='{bar_y + 4}' width='0.75' height='16' fill='{INK}' fill-opacity='0.15'/>")
    out.append(f"<path d='M{lx + 38} {bar_y + 12} h8' stroke='{TEXT}' stroke-width='1.3' stroke-linecap='round'/>")
    out.append(text(x + 16, y + 156, 'You can still add these apps manually from any account.', 11, SECOND, anchor='start'))
    return '\n'.join(out)


def arrow_right(x, y, length=46):
    return (f"<path d='M{x} {y} h{length} m-6 -5 l6 5 l-6 5' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def arrow_down(x, y, length=24):
    return (f"<path d='M{x} {y} v{length} m-5 -6 l5 6 l5 -6' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def step(x, y, number, title, size=15.5):
    return (f"<circle cx='{x + 10}' cy='{y - 5.2}' r='10.5' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 10, y - 1, number, 12, ACCENT, weight=700)
            + text(x + 29, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def note(x, y, s, strong=False):
    return text(x, y, s, 12, LABEL_STRONG if strong else LABEL, weight=500 if strong else 400, anchor='start')


def board():
    W, H = 1480, 820
    out = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>",
        defs(),
        f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
        text(56, 56, 'Add apps manually, and keep removed apps quiet', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
        text(56, 82, 'Every account keeps + Add app in its header. Removed apps stay silent — and undoing 3 automatic adds in one app stops adding it automatically.',
             13, LABEL, anchor='start'),
    ]

    x1, x2, x3 = 56, 540, 1024
    top = 148
    cap_top = 434

    out.append(step(x1, 124, '1', 'Open any account'))
    c1, c1h, e1 = details_card(x1, top, 'c1', apps=(), plus_hot=True)
    out.append(c1)
    px1, px2 = e1['+']
    out.append(pointer(px2 - 9, top + 46))
    out.append(note(x1, cap_top, 'Fixed 60 pt header — compact + Add app never shifts fields.'))

    out.append(arrow_right(x1 + 400 + 19, top + 104, 46))

    out.append(step(x2, 124, '2', 'Pick an app from the popover'))
    c2, c2h, e2 = details_card(x2, top, 'c2', apps=(), plus_active=True, dim_rows=True)
    out.append(c2)
    mx = e2['+'][0]
    my = top + 33 + 22
    pm, pmh = picker_popover(mx, my, w=256)
    out.append(pm)
    out.append(note(x2, cap_top, 'Details stay open. Already-added apps are omitted.'))

    out.append(arrow_right(x2 + 400 + 19, top + 104, 46))

    out.append(step(x3, 124, '3', 'Shown first — manage overflow inline'))
    s3a, _ = header_strip(x3, top, apps=('teams',))
    out.append(s3a)
    out.append(note(x3, top + HEADER_H + 17, 'Becomes "Shown first in" once added; + sits beside the chips.'))

    s3b, e3b = header_strip(x3, top + 96, apps=('teams',), overflow=2, overflow_active=True)
    out.append(s3b)
    ox = x3 + 400 - 206
    oy = top + 96 + 33 + 22
    op, oph = overflow_popover(ox, oy, w=206)
    out.append(op)
    out.append(note(x3, cap_top, 'Clicking "2 more ⌄" lists every app with a direct × remove button.'))

    div_y = 468
    out.append(f"<rect x='56' y='{div_y}' width='{W - 112}' height='1' fill='{DIVIDER}'/>")

    eyebrow_y = 506
    head_y = 530
    ui_y = 552
    cap_bot = 768

    out.append(text(x1, eyebrow_y, 'PER-ACCOUNT REMOVAL', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x1, head_y, 'Remove once — quiet from then on', 16, LABEL_STRONG, weight=600, anchor='start'))

    sa1, _ = header_strip(x1, ui_y, apps=('relay',), hover_app='relay')
    out.append(sa1)

    out.append(arrow_down(x1 + 20, ui_y + HEADER_H + 10, 26))
    out.append(text(x1 + 36, ui_y + HEADER_H + 27, 'copy password while Relay is active again', 12, LABEL, anchor='start'))

    sa2, _ = header_strip(x1, ui_y + HEADER_H + 52, apps=())
    out.append(sa2)
    out.append(note(x1, cap_bot, 'Copies silently — not re-added, no nag. Marked "Removed earlier" in menu.'))

    out.append(text(x2, eyebrow_y, 'APP-LEVEL EXCLUSION  ·  AGENTS, TERMINALS, CHAT', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x2, head_y, 'Undo 3 automatic adds in one app', 16, LABEL_STRONG, weight=600, anchor='start'))

    out.append(auto_add_bubble(x2, ui_y + 8, title='Admin API', app_name='relay', label='Relay', width=400))

    out.append(arrow_down(x2 + 20, ui_y + HEADER_H + 10, 26))
    out.append(text(x2 + 36, ui_y + HEADER_H + 27, '3rd distinct account undone (manual removals don’t count)', 11.5, LABEL, anchor='start'))

    out.append(stopped_bubble(x2, ui_y + HEADER_H + 60, app_name='relay', label='Relay', width=400))
    out.append(note(x2, cap_bot, 'Double-click guard on swap. Turn Back On resets the count.'))

    out.append(text(x3, eyebrow_y, 'MANAGE IN PREFERENCES', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x3, head_y, 'Exclude or restore apps anytime', 16, LABEL_STRONG, weight=600, anchor='start'))
    out.append(preferences_card(x3, ui_y, w=400, h=172))
    out.append(note(x3, cap_bot, 'Exclude terminals or agents with +, or restore with −.'))

    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, 'app-link-manual.svg'), 'w') as f:
        f.write(board())

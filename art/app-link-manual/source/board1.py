"""Round 1 design board: manual app linking (+) and quiet/app-level refusals."""
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
QUIET_CARD = '#26282E'
QUIET_STROKE = '#41444D'

# Approximate widths of app names at 11pt SF Pro Text
NAMES = {
    'harbor': ('Harbor', 36),
    'ledger': ('Ledger', 36),
    'relay': ('Relay', 29),
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
  <linearGradient id='tileN' x1='0' y1='0' x2='0' y2='1'>
    <stop offset='0' stop-color='#85F2DD'/><stop offset='1' stop-color='#3CC7AB'/>
  </linearGradient>
  <linearGradient id='tileS' x1='0' y1='0' x2='0' y2='1'>
    <stop offset='0' stop-color='#F7B277'/><stop offset='1' stop-color='#DE7B35'/>
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
    # Diagonal macOS SF Symbol "pin" tilted 45 deg, matching pencil's angle and stroke weight
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


def pointer(x, y):
    return f"<path d='M{x} {y} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111111' stroke='#FFFFFF' stroke-width='1.1'/>"


def token(x, y, name, hot=False):
    """Linked app chip: 18pt tall, rx 5, icon + name + always-visible xmark."""
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


def plus_button(x, y, hot=False, active=False):
    """Manual-link + button: 22x18pt pill, same family as LinkedAppToken."""
    w, h = 22, 18
    if active:
        fill = ACCENT
        stroke = ACCENT
        s_op = 1.0
        ink = ON_ACCENT
        ink_op = 1.0
    elif hot:
        fill = FIELD
        stroke = INK
        s_op = 0.45
        ink = TEXT
        ink_op = 1.0
    else:
        fill = 'none'
        stroke = INK
        s_op = 0.28
        ink = SECOND
        ink_op = 0.9
    cx, cy = x + w / 2, y + h / 2
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}'/>",
        f"<path d='M{cx - 3.6} {cy} H{cx + 3.6} M{cx} {cy - 3.6} V{cy + 3.6}' "
        f"stroke='{ink}' stroke-opacity='{ink_op}' stroke-width='1.35' stroke-linecap='round'/>",
    ]
    return '\n'.join(out), w


def header(x, y, w, apps=(), hover_app=None, plus_hot=False, plus_active=False, show_pin=True):
    """Consistent 60pt details header: Row 1 has title + toolbar; Row 2 has Shown first in + tokens + [+]."""
    out = [tile(x + 14, y + 14, 32)]
    tx = x + 56
    # Row 1: title and right toolbar aligned on title's row so Row 2 gets full width
    out.append(text(tx, y + 24, 'Northwind SSO', 16, TEXT, weight=600, anchor='start'))
    cy1 = y + 19
    if show_pin:
        out.append(pencil(x + w - 76, cy1 - 6))
        out.append(pin_icon(x + w - 51, cy1 - 6))
        out.append(star(x + w - 22, cy1))
    else:
        out.append(pencil(x + w - 54, cy1 - 6))
        out.append(star(x + w - 22, cy1))

    # Row 2: Shown first in + linked app tokens + [+]
    out.append(text(tx, y + 45.8, 'Shown first in', 11, SECOND, anchor='start'))
    cx = tx + 76
    ends = {}
    for name in apps:
        t, tw = token(cx, y + 33, name, hot=(name == hover_app))
        out.append(t)
        ends[name] = (cx, cx + tw)
        cx += tw + 6
    pb, pw = plus_button(cx, y + 33, hot=plus_hot, active=plus_active)
    out.append(pb)
    ends['+'] = (cx, cx + pw)
    return '\n'.join(out), ends


def detail_row(x, y, w, label, value, tint=False, h=38):
    out = []
    if tint:
        out.append(f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{ACCENT}' fill-opacity='0.2'/>")
    out.append(f"<rect x='{x}' y='{y}' width='{w}' height='0.5' fill='{INK}' fill-opacity='0.1'/>")
    out.append(text(x + 14, y + 14.5, label, 10, SECOND, anchor='start'))
    out.append(text(x + 14, y + 30.5, value, 13, TEXT, anchor='start'))
    return '\n'.join(out)


def details_card(x, y, clip_id, apps=(), hover_app=None, plus_hot=False, plus_active=False, dim_rows=False):
    """1:1 Details popover (400pt wide): header + username + password + website."""
    w = 400
    rows = [
        ('username', 'ada@northwind.example', False),
        ('password', '••••••••••••••••', False),
        ('website', 'https://sso.northwind.example', True),
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
        out.append("<g opacity='0.55'>")
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


def header_strip(x, y, apps=(), hover_app=None, plus_hot=False):
    w, h = 400, HEADER_H
    hd, ends = header(x, y, w, apps=apps, hover_app=hover_app, plus_hot=plus_hot)
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        hd,
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='none' stroke='{BORDER}' stroke-opacity='0.55'/>",
    ]
    if hover_app and hover_app in ends:
        _, ex = ends[hover_app]
        out.append(pointer(ex - 9, y + 33 + 13))
    return '\n'.join(out), ends


def picker_menu(x, y, w=228):
    """Native-feel popover menu anchored under [+]: front app, running apps, Choose App…"""
    # Layout rows
    # Top padding 6, item 26, div 9, section header 18, item 26, item 26, div 9, item 26, bottom padding 6 = 152
    h = 6 + 26 + 9 + 18 + 26 + 26 + 9 + 26 + 6
    out = [
        f"<g filter='url(#menuShadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='{SURFACE}' stroke='{BORDER}'/>",
    ]
    cy = y + 6

    # Selected item 1: Harbor (In front)
    out.append(f"<rect x='{x + 5}' y='{cy}' width='{w - 10}' height='26' rx='5' fill='{ACCENT}'/>")
    out.append(app(x + 12, cy + 5, 16, 'harbor'))
    out.append(text(x + 35, cy + 17.2, 'Harbor', 13, ON_ACCENT, weight=500, anchor='start'))
    out.append(text(x + w - 13, cy + 16.5, 'In front', 11, ON_ACCENT, opacity=0.72, anchor='end'))
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Section label
    out.append(text(x + 12, cy + 12.5, 'RUNNING APPS', 9.5, SECOND, weight=600, anchor='start', spacing=0.5))
    cy += 18

    # Item 2: Ledger
    out.append(app(x + 12, cy + 5, 16, 'ledger'))
    out.append(text(x + 35, cy + 17.2, 'Ledger', 13, TEXT, anchor='start'))
    cy += 26

    # Item 3: Relay (manual-only note subtly shown? No — keep menu clean; any app is linkable by hand)
    out.append(app(x + 12, cy + 5, 16, 'relay'))
    out.append(text(x + 35, cy + 17.2, 'Relay', 13, TEXT, anchor='start'))
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Item 4: Choose App…
    # Small folder/app-grid outline glyph
    gx, gy = x + 13, cy + 6
    out.append(f"<rect x='{gx}' y='{gy}' width='14' height='14' rx='3' fill='none' stroke='{SECOND}' stroke-width='1.2'/>")
    out.append(f"<path d='M{gx + 3.5} {gy + 7} h7 M{gx + 7} {gy + 3.5} v7' stroke='{SECOND}' stroke-width='1.2' stroke-linecap='round'/>")
    out.append(text(x + 35, cy + 17.2, 'Choose App…', 13, TEXT, anchor='start'))
    return '\n'.join(out), h


def quiet_button(x, y, w, label):
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='21' rx='5' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>"
            + text(x + w / 2, y + 15, label, 11.5, TEXT, weight=500))


def stopped_bubble(x, y, app_name='relay', label='Relay', width=430):
    """44pt PasswordPie bubble for app-level auto-link stop."""
    h = 44
    bw = 114
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
        app(x + 12, y + 10, 24, app_name),
        # Subtle pause/stop badge on bottom-right of app icon
        f"<circle cx='{x + 34}' cy='{y + 32}' r='7.2' fill='{SURFACE}'/>",
        f"<circle cx='{x + 34}' cy='{y + 32}' r='5.6' fill='{SECOND}'/>",
        f"<path d='M{x + 31.6} {y + 29.6} l4.8 4.8' stroke='{SURFACE}' stroke-width='1.5' stroke-linecap='round'/>",
        text(x + 48, y + 26.5, f'Stopped auto-linking in {label}', 13, TEXT, weight=500, anchor='start'),
        quiet_button(x + width - bw - 12, y + 11.5, bw, 'Keep auto-linking'),
    ]
    return '\n'.join(out)


def arrow_right(x, y, length=44):
    return (f"<path d='M{x} {y} h{length} m-6 -5 l6 5 l-6 5' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def arrow_down(x, y, length=28):
    return (f"<path d='M{x} {y} v{length} m-5 -6 l5 6 l5 -6' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def step(x, y, number, title, size=15.5):
    return (f"<circle cx='{x + 10}' cy='{y - 5.2}' r='10.5' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 10, y - 1, number, 12, ACCENT, weight=700)
            + text(x + 29, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def note(x, y, s, strong=False):
    return text(x, y, s, 12, LABEL_STRONG if strong else LABEL, weight=500 if strong else 400, anchor='start')


def mini_undone_chip(x, y, letter, grad, title):
    w, h = 132, 32
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='7' fill='{QUIET_CARD}' stroke='{QUIET_STROKE}'/>",
        tile(x + 8, y + 7, 18, letter=letter, grad=grad),
        text(x + 33, y + 20, title, 11.5, LABEL_STRONG, weight=500, anchor='start'),
        # tiny red/muted xmark indicating undone
        f"<path d='M{x + w - 15} {y + 13} l6 6 M{x + w - 9} {y + 13} l-6 6' stroke='{LABEL}' stroke-width='1.3' stroke-linecap='round'/>",
    ]
    return '\n'.join(out), w


def board():
    W, H = 1480, 796
    out = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>",
        defs(),
        f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
        text(56, 58, 'Link apps by hand, and keep refusals quiet', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
        text(56, 84, 'Every account keeps + under its title. Removing an app stays silent — and three undos in one app stop auto-linking there.',
             13, LABEL, anchor='start'),
    ]

    # ── UPPER HALF: Manual linking flow (3 columns, 400pt each, 84pt gaps) ──
    x1, x2, x3 = 56, 540, 1024
    top = 152

    # Column 1: Empty account details with [+]
    out.append(step(x1, 128, '1', 'Open any account — + is always there'))
    c1, c1h, e1 = details_card(x1, top, 'c1', apps=(), plus_hot=True)
    out.append(c1)
    # Cursor hovering on [+]
    px1, px2 = e1['+']
    out.append(pointer((px1 + px2) / 2 + 1, top + 46))
    out.append(note(x1, top + c1h + 26, 'Same 60 pt header empty or linked, so fields never jump.'))

    # Arrow 1 -> 2
    out.append(arrow_right(x1 + 400 + 18, top + 86, 48))

    # Column 2: Clicking [+] opens the inline picker menu
    out.append(step(x2, 128, '2', 'Pick the front app, a running app, or any app'))
    c2, c2h, e2 = details_card(x2, top, 'c2', apps=(), plus_active=True, dim_rows=True)
    out.append(c2)
    mx = e2['+'][0]
    my = top + 33 + 22
    pm, pmh = picker_menu(mx, my, w=228)
    out.append(pm)
    out.append(note(x2, max(top + c2h, my + pmh) + 26, 'Browsers and linked apps are left out. Popover stays open.'))

    # Arrow 2 -> 3
    out.append(arrow_right(x2 + 400 + 18, top + 86, 48))

    # Column 3: Linked states (1 app, then 2 apps + [+]), top-aligned with Columns 1 & 2
    out.append(step(x3, 128, '3', 'Linked at once — add more or remove with ×'))
    s3a, _ = header_strip(x3, top, apps=('harbor',))
    out.append(s3a)
    out.append(note(x3, top + HEADER_H + 18, 'One app linked — + stays right beside it.'))

    s3b, _ = header_strip(x3, top + 104, apps=('harbor', 'ledger'))
    out.append(s3b)
    out.append(note(x3, top + 104 + HEADER_H + 18, 'Multiple apps share the full line; overflow counts "+2 more".'))

    # ── HORIZONTAL DIVIDER ──
    div_y = 448
    out.append(f"<rect x='56' y='{div_y}' width='{W - 112}' height='1' fill='{DIVIDER}'/>")

    # ── LOWER HALF: Quiet refusal rules (A: per-account, B: 3-undo app-level) ──
    sec_y = div_y + 42

    # Section A (Left: x = 56)
    ax = 56
    out.append(text(ax, sec_y, 'PER-ACCOUNT REFUSAL', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(ax, sec_y + 23, 'Remove an app once — copying there stays silent', 16, LABEL_STRONG, weight=600, anchor='start'))

    sa, _ = header_strip(ax, sec_y + 44, apps=('relay',), hover_app='relay')
    out.append(sa)

    # Downward arrow + label
    out.append(arrow_down(ax + 200, sec_y + 44 + HEADER_H + 10, 34))
    out.append(text(ax + 216, sec_y + 44 + HEADER_H + 31, 'copy password over Relay again', 12, LABEL, anchor='start'))

    # Quiet outcome card (400pt wide, matching header width)
    qy = sec_y + 44 + HEADER_H + 54
    out.append(f"<rect x='{ax + 0.5}' y='{qy + 0.5}' width='399' height='44' rx='10' fill='{QUIET_CARD}' "
               f"stroke='{QUIET_STROKE}' stroke-dasharray='4 3'/>")
    # Checkmark circle
    out.append(f"<circle cx='{ax + 24}' cy='{qy + 22}' r='8.5' fill='#3B5E4A'/>")
    out.append(f"<path d='M{ax + 20.5} {qy + 22.3} l2.4 2.4 l4.8 -5.2' fill='none' stroke='#B8F0CE' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/>")
    out.append(text(ax + 42, qy + 26.5, 'Copied to clipboard — no auto-link, no prompt', 13, LABEL_STRONG, weight=500, anchor='start'))
    out.append(note(ax, qy + 68, 'No repeat "Show first again?" bubble. Re-link anytime with +.'))

    # Subtle vertical separator between A and B (optically balanced)
    out.append(f"<rect x='580' y='{sec_y - 6}' width='1' height='262' fill='{DIVIDER}'/>")

    # Section B (Right: x = 636)
    bx = 636
    out.append(text(bx, sec_y, 'APP-LEVEL PROTECTION  ·  AI AGENTS, TERMINALS, CHAT', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(bx, sec_y + 23, 'Undo 3 accounts in one app — auto-linking stops for that app', 16, LABEL_STRONG, weight=600, anchor='start'))

    # Visual counter bar: Relay icon + 3 undone account chips (equal 14px left/right padding)
    ry = sec_y + 44
    bar_w = 590
    out.append(f"<rect x='{bx + 0.5}' y='{ry + 0.5}' width='{bar_w - 1}' height='60' rx='8' fill='{QUIET_CARD}' stroke='{QUIET_STROKE}'/>")
    out.append(app(bx + 14, ry + 14, 32, 'relay'))
    out.append(text(bx + 56, ry + 26, 'Relay', 13, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(bx + 56, ry + 43, '3 accounts undone', 11, LABEL, anchor='start'))

    chips = [('N', 'tileN', 'Northwind'), ('S', 'tileS', 'Staging DB'), ('A', 'tileA', 'Admin API')]
    cx = bx + 164
    for letter, grad, title in chips:
        ch, cw = mini_undone_chip(cx, ry + 14, letter, grad, title)
        out.append(ch)
        cx += cw + 8

    # Downward arrow + label
    out.append(arrow_down(bx + 215, ry + 60 + 10, 34))
    out.append(text(bx + 231, ry + 60 + 31, 'on the 3rd undo in Relay', 12, LABEL, anchor='start'))

    # 1:1 Bubble for app-level stop
    by = ry + 60 + 54
    out.append(stopped_bubble(bx, by, app_name='relay', label='Relay', width=430))
    out.append(note(bx, by + 68, 'New accounts copied over Relay stay quiet. Manual + linking still works.'))

    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, 'app-link-manual.svg'), 'w') as f:
        f.write(board())

"""Round 3 design board: unified 'show first' vocabulary, symmetric pull-down CTA, interactive '2 more ⌄', auto-only 3-strike rule, native Preferences exclusion list."""
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
  <symbol id='terminal' viewBox='0 0 32 32'>
    <rect width='32' height='32' rx='7.2' fill='#26282E'/>
    <rect x='1' y='1' width='30' height='30' rx='6.4' fill='none' stroke='#505460' stroke-width='1.2'/>
    <path d='M8.5 11.5 L14 16 L8.5 20.5 M16.5 21 H23.5' fill='none' stroke='#E8E4DD' stroke-width='2.3' stroke-linecap='round' stroke-linejoin='round'/>
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
    return (f"<path d='M{cx - 2.8} {cy - 1.3} l2.8 2.8 l2.8 -2.8' fill='none' stroke='{color}' "
            f"stroke-opacity='{opacity}' stroke-width='1.25' stroke-linecap='round' stroke-linejoin='round'/>")


def pointer(x, y):
    return f"<path d='M{x} {y} l0 15 l4 -3.6 l2.6 6 l2.6 -1.1 l-2.6 -5.9 l5.4 0 z' fill='#111111' stroke='#FFFFFF' stroke-width='1.1'/>"


def token(x, y, name, hot=False):
    """Shipped LinkedAppToken: 18pt tall, rx 5, icon + name + always-visible xmark."""
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
    """Self-contained pull-down trigger: '+ Show first in an app ⌄' with symmetric 8pt side padding."""
    # 8 (left pad) + 7 (+) + 5 (gap) + 109 (text 'Show first in an app') + 6 (gap) + 6 (chevron) + 8 (right pad) = 149
    w, h = 149, 18
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
        text(x + 20, y + 12.8, 'Show first in an app', 11, fg, weight=500 if active else 400, anchor='start'),
        chevron_down(x + w - 11, cy + 0.3, fg, opacity=0.85 if (hot or active) else 0.7),
    ]
    return '\n'.join(out), w


def overflow_pill(x, y, count):
    """Interactive overflow control: '2 more ⌄' (opens full list of linked apps)."""
    w, h = 58, 18
    cy = y + h / 2
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='none' stroke='{INK}' stroke-opacity='0.22'/>",
        text(x + 7, y + 12.8, f'{count} more', 11, SECOND, anchor='start'),
        chevron_down(x + w - 9.5, cy + 0.3, SECOND, opacity=0.75),
    ]
    return '\n'.join(out), w


def plus_button(x, y, hot=False, active=False):
    """Compact + button at fixed trailing edge of Row 2: 24x18pt."""
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


def header(x, y, w, apps=(), hover_app=None, plus_hot=False, plus_active=False, overflow=0):
    """Consistent 60pt header across empty, linked, and overflow states."""
    out = [tile(x + 14, y + 14, 32)]
    tx = x + 56
    # Row 1: title + right toolbar aligned on title's row
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
        cx = tx + 72
        for name in apps:
            t, tw = token(cx, y + 33, name, hot=(name == hover_app))
            out.append(t)
            ends[name] = (cx, cx + tw)
            cx += tw + 5
        if overflow > 0:
            op, ow = overflow_pill(cx, y + 33, overflow)
            out.append(op)
            cx += ow + 5
        # Pin [+] right at the row's trailing edge (aligned with star's right edge at x + w - 14)
        px = x + w - 14 - 24
        pb, pw = plus_button(px, y + 33, hot=plus_hot, active=plus_active)
        out.append(pb)
        ends['+'] = (px, px + pw)
    return '\n'.join(out), ends


def details_card(x, y, clip_id, apps=(), hover_app=None, plus_hot=False, plus_active=False, dim_rows=False):
    """1:1 Details popover (400pt wide): 60pt header + 4 field rows (212pt total)."""
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


def header_strip(x, y, apps=(), hover_app=None, plus_hot=False, overflow=0):
    w, h = 400, HEADER_H
    hd, ends = header(x, y, w, apps=apps, hover_app=hover_app, plus_hot=plus_hot, overflow=overflow)
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        hd,
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='none' stroke='{BORDER}' stroke-opacity='0.55'/>",
    ]
    if hover_app and hover_app in ends:
        _, ex = ends[hover_app]
        out.append(pointer(ex - 9, y + 33 + 13))
    return '\n'.join(out), ends


def picker_menu(x, y, w=248):
    """Native NSMenu anchored beneath trigger: current app, running apps, Choose App…, browser note."""
    h = 6 + 26 + 9 + 20 + 26 + 26 + 9 + 26 + 22 + 6
    out = [
        f"<g filter='url(#menuShadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='{SURFACE}' stroke='{BORDER}'/>",
    ]
    cy = y + 6

    # Row 1: Harbor (currently behind PasswordPie, hovered with pointer)
    out.append(f"<rect x='{x + 5}' y='{cy}' width='{w - 10}' height='26' rx='5' fill='{ACCENT}'/>")
    out.append(app(x + 12, cy + 5, 16, 'harbor'))
    out.append(text(x + 35, cy + 17.2, 'Harbor', 13, ON_ACCENT, weight=500, anchor='start'))
    out.append(text(x + w - 13, cy + 16.8, 'Active app', 11, ON_ACCENT, opacity=0.88, anchor='end'))
    hover_y = cy
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Sentence-case section header
    out.append(text(x + 12, cy + 13.5, 'Running apps', 11, SECOND, weight=500, anchor='start'))
    cy += 20

    # Row 2: Ledger
    out.append(app(x + 12, cy + 5, 16, 'ledger'))
    out.append(text(x + 35, cy + 17.2, 'Ledger', 13, TEXT, anchor='start'))
    cy += 26

    # Row 3: Relay (every app is cleanly pickable by hand — no confusing disabled-looking tag)
    out.append(app(x + 12, cy + 5, 16, 'relay'))
    out.append(text(x + 35, cy + 17.2, 'Relay', 13, TEXT, anchor='start'))
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Row 4: Choose App…
    out.append(text(x + 35, cy + 17.2, 'Choose App…', 13, TEXT, anchor='start'))
    cy += 26

    # Plain, clear disabled footer explaining browser omission
    out.append(text(x + 12, cy + 14.5, 'Websites match automatically in browsers', 10.5, SECOND, opacity=0.78, anchor='start'))

    # Pointer hovering on Harbor
    out.append(pointer(x + 132, hover_y + 16))
    return '\n'.join(out), h


def quiet_button(x, y, w, label):
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='21' rx='5' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>"
            + text(x + w / 2, y + 15, label, 11.5, TEXT, weight=500))


def stopped_bubble(x, y, app_name='relay', label='Relay', width=400):
    """44pt PasswordPie bubble matching unified 'show first' vocabulary."""
    h = 44
    bw = 94
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
        app(x + 12, y + 10, 24, app_name),
        f"<circle cx='{x + 34}' cy='{y + 32}' r='7.5' fill='{SURFACE}'/>",
        f"<circle cx='{x + 34}' cy='{y + 32}' r='5.8' fill='none' stroke='{TEXT}' stroke-width='1.5'/>",
        f"<path d='M{x + 30.2} {y + 28.2} l7.6 7.6' stroke='{TEXT}' stroke-width='1.5' stroke-linecap='round'/>",
        text(x + 46, y + 26.5, f"Won't show first in {label} automatically", 12.5, TEXT, weight=500, anchor='start'),
        quiet_button(x + width - bw - 11, y + 11.5, bw, 'Turn Back On'),
    ]
    return '\n'.join(out)


def preferences_card(x, y, w=400, h=172):
    """Native exclusion list in Preferences › General: proactive + add, Remove to re-enable, one clear footer."""
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}' stroke-opacity='0.65'/>",
        text(x + 16, y + 21, 'Preferences › General', 10.5, SECOND, opacity=0.8, anchor='start'),
        text(x + 16, y + 40, "Don't show first automatically in", 12, TEXT, weight=600, anchor='start'),
        # Proactive Add App button at top-right of section header
        quiet_button(x + w - 82 - 16, y + 25, 82, '+ Add App…'),
        f"<rect x='{x + 16}' y='{y + 52}' width='{w - 32}' height='1' fill='{INK}' fill-opacity='0.09'/>",
    ]
    # Row 1: Relay
    r1 = y + 58
    out.append(app(x + 16, r1 + 6, 22, 'relay'))
    out.append(text(x + 46, r1 + 21, 'Relay', 13, TEXT, weight=500, anchor='start'))
    out.append(quiet_button(x + w - 64 - 16, r1 + 6.5, 64, 'Remove'))

    out.append(f"<rect x='{x + 46}' y='{r1 + 36}' width='{w - 62}' height='1' fill='{INK}' fill-opacity='0.09'/>")

    # Row 2: Terminal
    r2 = r1 + 41
    out.append(app(x + 16, r2 + 6, 22, 'terminal'))
    out.append(text(x + 46, r2 + 21, 'Terminal', 13, TEXT, weight=500, anchor='start'))
    out.append(quiet_button(x + w - 64 - 16, r2 + 6.5, 64, 'Remove'))

    # Single quiet footer line explaining manual behavior
    out.append(f"<rect x='{x + 16}' y='{y + 138}' width='{w - 32}' height='1' fill='{INK}' fill-opacity='0.09'/>")
    out.append(text(x + 16, y + 157, 'You can still add any of these apps by hand from an account.', 11, SECOND, anchor='start'))
    return '\n'.join(out)


def arrow_right(x, y, length=46):
    return (f"<path d='M{x} {y} h{length} m-6 -5 l6 5 l-6 5' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def arrow_down(x, y, length=26):
    return (f"<path d='M{x} {y} v{length} m-5 -6 l5 6 l5 -6' fill='none' stroke='{LINE}' stroke-width='1.5' "
            f"stroke-linecap='round' stroke-linejoin='round'/>")


def step(x, y, number, title, size=15.5):
    return (f"<circle cx='{x + 10}' cy='{y - 5.2}' r='10.5' fill='none' stroke='{ACCENT}' stroke-width='1.5'/>"
            + text(x + 10, y - 1, number, 12, ACCENT, weight=700)
            + text(x + 29, y, title, size, LABEL_STRONG, weight=600, anchor='start'))


def note(x, y, s, strong=False):
    return text(x, y, s, 12, LABEL_STRONG if strong else LABEL, weight=500 if strong else 400, anchor='start')


def strike_badge(x, y, num, letter, grad, name):
    """Diagrammatic sequence pill (clearly annotation, not live UI)."""
    w, h = 124, 34
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='6' fill='none' stroke='#3A3D45' stroke-dasharray='3 2'/>",
        text(x + 10, y + 21, num, 11, ACCENT, weight=700, anchor='start'),
        tile(x + 24, y + 8, 18, letter=letter, grad=grad),
        text(x + 48, y + 21, name, 11.5, LABEL_STRONG, weight=500, anchor='start'),
    ]
    return '\n'.join(out), w


def board():
    W, H = 1480, 790
    out = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>",
        defs(),
        f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
        text(56, 56, 'Show accounts first in apps — by hand, or quietly off', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
        text(56, 82, 'Add any app from an account header. Unlinking stays silent — and undoing 3 auto-added links in one app turns automatic adding off there.',
             13, LABEL, anchor='start'),
    ]

    x1, x2, x3 = 56, 540, 1024
    top = 148
    cap_top = 408

    # ── TOP ROW: Manual linking flow (3 x 400pt columns) ──
    # Col 1: Empty state with symmetric pull-down CTA
    out.append(step(x1, 124, '1', 'Open any account'))
    c1, c1h, e1 = details_card(x1, top, 'c1', apps=(), plus_hot=True)
    out.append(c1)
    px1, px2 = e1['+']
    # Place pointer neatly at trailing edge of CTA without covering text
    out.append(pointer(px2 - 9, top + 46))
    out.append(note(x1, cap_top, 'Fixed 60 pt header — fields never shift when apps are added.'))

    out.append(arrow_right(x1 + 400 + 19, top + 104, 46))

    # Col 2: Native picker menu open beneath trigger
    out.append(step(x2, 124, '2', 'Pick an app from the menu'))
    c2, c2h, e2 = details_card(x2, top, 'c2', apps=(), plus_active=True, dim_rows=True)
    out.append(c2)
    mx = e2['+'][0]
    my = top + 33 + 22
    pm, pmh = picker_menu(mx, my, w=248)
    out.append(pm)
    out.append(note(x2, cap_top, 'Details stay open (native NSMenu). Already-added apps are omitted.'))

    out.append(arrow_right(x2 + 400 + 19, top + 104, 46))

    # Col 3: Linked + Overflow states, with [+] pinned at fixed trailing edge
    out.append(step(x3, 124, '3', 'Shown first right away'))
    s3a, _ = header_strip(x3, top, apps=('harbor',))
    out.append(s3a)
    out.append(note(x3, top + HEADER_H + 18, 'One app added — + pins cleanly at the trailing edge.'))

    s3b, _ = header_strip(x3, top + 114, apps=('harbor', 'ledger'), overflow=2)
    out.append(s3b)
    out.append(note(x3, top + 114 + HEADER_H + 18, '"2 more ⌄" opens the full list to view or remove hidden apps.'))
    out.append(note(x3, top + 114 + HEADER_H + 36, 'Long names truncate cleanly (e.g. Microsoft Te…).'))
    out.append(note(x3, cap_top, 'Click × on an app to remove it (Undo bubble appears once).'))

    # ── HORIZONTAL DIVIDER ──
    div_y = 442
    out.append(f"<rect x='56' y='{div_y}' width='{W - 112}' height='1' fill='{DIVIDER}'/>")

    # ── BOTTOM ROW: Same 3-column grid (UI band y=528..700; shared captions y=738) ──
    eyebrow_y = 480
    head_y = 504
    ui_y = 528
    cap_bot = 740

    # Bottom Col 1: Per-account quiet refusal — BOTH states drawn as real 1:1 UI!
    out.append(text(x1, eyebrow_y, 'PER-ACCOUNT REMOVAL', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x1, head_y, 'Remove once — quiet from then on', 16, LABEL_STRONG, weight=600, anchor='start'))

    sa1, _ = header_strip(x1, ui_y, apps=('relay',), hover_app='relay')
    out.append(sa1)

    out.append(arrow_down(x1 + 20, ui_y + HEADER_H + 11, 28))
    out.append(text(x1 + 36, ui_y + HEADER_H + 29, 'copy password while Relay is active again', 12, LABEL, anchor='start'))

    # Real 1:1 empty header showing Relay was NOT re-added (and no prompt appears)
    sa2, _ = header_strip(x1, ui_y + HEADER_H + 52, apps=())
    out.append(sa2)
    out.append(note(x1, cap_bot, 'Copies as usual — not re-added, no repeat prompt. Re-add via +.'))

    # Bottom Col 2: App-level stop after 3 distinct auto-added links undone
    out.append(text(x2, eyebrow_y, 'APP-LEVEL PROTECTION  ·  AGENTS, TERMINALS, CHAT', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x2, head_y, 'Undo 3 auto-added links in one app', 16, LABEL_STRONG, weight=600, anchor='start'))

    # Clean diagrammatic sequence (dashed outline, clearly annotation)
    strikes = [('1', 'N', 'tileN', 'Northwind'), ('2', 'S', 'tileS', 'Staging'), ('3', 'A', 'tileA', 'Admin API')]
    sx = x2
    for num, letter, grad, name in strikes:
        sb, sw = strike_badge(sx, ui_y + 2, num, letter, grad, name)
        out.append(sb)
        sx += sw + 14
    out.append(text(x2, ui_y + 54, 'Counts only Undo / × on auto-added links (not links added by hand).', 11.5, LABEL, anchor='start'))

    out.append(arrow_down(x2 + 20, ui_y + HEADER_H + 11, 28))
    out.append(text(x2 + 36, ui_y + HEADER_H + 29, 'on the 3rd distinct account undone in Relay', 12, LABEL, anchor='start'))

    # Real 1:1 400pt Bubble (vertically centered with Col 1's bottom strip and Col 3's card bottom)
    out.append(stopped_bubble(x2, ui_y + HEADER_H + 60, app_name='relay', label='Relay', width=400))
    out.append(note(x2, cap_bot, 'Turn Back On restores automatic adding and resets the count.'))

    # Bottom Col 3: Native exclusion list in Preferences › General
    out.append(text(x3, eyebrow_y, 'MANAGE IN PREFERENCES', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x3, head_y, 'Add or remove apps anytime', 16, LABEL_STRONG, weight=600, anchor='start'))
    out.append(preferences_card(x3, ui_y, w=400, h=172))
    out.append(note(x3, cap_bot, 'Empty state hides the rows and keeps + Add App… available.'))

    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, 'app-link-manual.svg'), 'w') as f:
        f.write(board())

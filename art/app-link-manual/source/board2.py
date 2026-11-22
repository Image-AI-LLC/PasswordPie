"""Round 2 design board: strict 3x2 grid, self-contained empty CTA, overflow '2 more', Preferences recovery, Turn Back On."""
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
MUTED_RULE = '#4A4D57'

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


def tile(x, y, side, letter='N'):
    r = side * 0.22
    return (f"<rect x='{x}' y='{y}' width='{side}' height='{side}' rx='{r}' fill='url(#tileN)' "
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
    """Self-contained empty-state control: '+ Show first in an app…' (18pt tall pill)."""
    w, h = 148, 18
    if active:
        fill, stroke, s_op, fg = FIELD, ACCENT_TEXT, 0.85, TEXT
    elif hot:
        fill, stroke, s_op, fg = FIELD, INK, 0.45, TEXT
    else:
        fill, stroke, s_op, fg = 'none', INK, 0.25, SECOND
    cy = y + h / 2
    px = x + 10
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}' stroke-width='{1.2 if active else 1}'/>",
        f"<path d='M{px - 3.2} {cy} H{px + 3.2} M{px} {cy - 3.2} V{cy + 3.2}' "
        f"stroke='{fg}' stroke-width='1.3' stroke-linecap='round'/>",
        text(x + 19, y + 12.8, 'Show first in an app…', 11, fg, weight=500 if active else 400, anchor='start'),
    ]
    return '\n'.join(out), w


def plus_button(x, y, hot=False, active=False):
    """Compact + pill beside linked app tokens: 24x18pt."""
    w, h = 24, 18
    if active:
        fill, stroke, s_op, fg = ACCENT, ACCENT, 1.0, ON_ACCENT
    elif hot:
        fill, stroke, s_op, fg = FIELD, INK, 0.45, TEXT
    else:
        fill, stroke, s_op, fg = 'none', INK, 0.25, SECOND
    cx, cy = x + w / 2, y + h / 2
    out = [
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' "
        f"fill='{fill}' stroke='{stroke}' stroke-opacity='{s_op}'/>",
        f"<path d='M{cx - 3.6} {cy} H{cx + 3.6} M{cx} {cy - 3.6} V{cy + 3.6}' "
        f"stroke='{fg}' stroke-width='1.35' stroke-linecap='round'/>",
    ]
    return '\n'.join(out), w


def header(x, y, w, apps=(), hover_app=None, plus_hot=False, plus_active=False, overflow=0):
    """Consistent 60pt details header across empty, linked, and overflow states."""
    out = [tile(x + 14, y + 14, 32)]
    tx = x + 56
    # Row 1: title + right toolbar aligned to title so Row 2 gets full 330pt width
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
        cx = tx + 76
        for name in apps:
            t, tw = token(cx, y + 33, name, hot=(name == hover_app))
            out.append(t)
            ends[name] = (cx, cx + tw)
            cx += tw + 6
        if overflow > 0:
            label = f'{overflow} more'
            out.append(text(cx + 1, y + 45.8, label, 11, SECOND, anchor='start'))
            cx += 39 + 6
        pb, pw = plus_button(cx, y + 33, hot=plus_hot, active=plus_active)
        out.append(pb)
        ends['+'] = (cx, cx + pw)
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


def picker_menu(x, y, w=244):
    """Native-style popover menu anchored under the trigger: front app, running apps (incl. suppressed), Choose App…, browser note."""
    h = 6 + 26 + 9 + 20 + 26 + 26 + 9 + 26 + 22 + 6
    out = [
        f"<g filter='url(#menuShadow)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='8' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='8' fill='{SURFACE}' stroke='{BORDER}'/>",
    ]
    cy = y + 6

    # Row 1: Harbor (In front, hovered with pointer)
    out.append(f"<rect x='{x + 5}' y='{cy}' width='{w - 10}' height='26' rx='5' fill='{ACCENT}'/>")
    out.append(app(x + 12, cy + 5, 16, 'harbor'))
    out.append(text(x + 35, cy + 17.2, 'Harbor', 13, ON_ACCENT, weight=500, anchor='start'))
    out.append(text(x + w - 13, cy + 16.8, 'In front', 11, ON_ACCENT, opacity=0.72, anchor='end'))
    hover_y = cy
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Sentence-case section header (native macOS style)
    out.append(text(x + 12, cy + 13.5, 'Running apps', 11, SECOND, weight=500, anchor='start'))
    cy += 20

    # Row 2: Ledger
    out.append(app(x + 12, cy + 5, 16, 'ledger'))
    out.append(text(x + 35, cy + 17.2, 'Ledger', 13, TEXT, anchor='start'))
    cy += 26

    # Row 3: Relay (suppressed app still linkable by hand, marked quietly)
    out.append(app(x + 12, cy + 5, 16, 'relay'))
    out.append(text(x + 35, cy + 17.2, 'Relay', 13, TEXT, anchor='start'))
    out.append(text(x + w - 13, cy + 16.8, 'Auto-link off', 10.5, SECOND, opacity=0.85, anchor='end'))
    cy += 26

    # Divider
    out.append(f"<rect x='{x + 10}' y='{cy + 4}' width='{w - 20}' height='0.75' fill='{INK}' fill-opacity='0.14'/>")
    cy += 9

    # Row 4: Choose App… (clean aligned native menu item, no redundant icon)
    out.append(text(x + 35, cy + 17.2, 'Choose App…', 13, TEXT, anchor='start'))
    cy += 26

    # Disabled footer explaining why browsers are absent
    out.append(text(x + 12, cy + 14.5, 'Browsers match by website', 10.5, SECOND, opacity=0.75, anchor='start'))

    # Pointer hovering on Harbor to show why it is highlighted
    out.append(pointer(x + 148, hover_y + 15))
    return '\n'.join(out), h


def quiet_button(x, y, w, label):
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='21' rx='5' fill='{FIELD}' stroke='{INK}' stroke-opacity='0.25'/>"
            + text(x + w / 2, y + 15, label, 11.5, TEXT, weight=500))


def stopped_bubble(x, y, app_name='relay', label='Relay', width=400):
    """44pt PasswordPie bubble matching exact 400pt column width."""
    h = 44
    bw = 98
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{width}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{width - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}'/>",
        app(x + 12, y + 10, 24, app_name),
        # Crisp high-contrast suppression badge (bottom-right of 24pt app icon)
        f"<circle cx='{x + 34}' cy='{y + 32}' r='7.5' fill='{SURFACE}'/>",
        f"<circle cx='{x + 34}' cy='{y + 32}' r='5.8' fill='none' stroke='{TEXT}' stroke-width='1.5'/>",
        f"<path d='M{x + 30.2} {y + 28.2} l7.6 7.6' stroke='{TEXT}' stroke-width='1.5' stroke-linecap='round'/>",
        text(x + 48, y + 26.5, f'Stopped auto-linking in {label}', 13, TEXT, weight=500, anchor='start'),
        quiet_button(x + width - bw - 12, y + 11.5, bw, 'Turn Back On'),
    ]
    return '\n'.join(out)


def preferences_card(x, y, w=400, h=158):
    """Real 1:1 Preferences › General section: 'Apps that don't auto-link'."""
    out = [
        f"<g filter='url(#soft)'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='10' fill='{SURFACE}'/></g>",
        f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='10' fill='{SURFACE}' stroke='{BORDER}' stroke-opacity='0.65'/>",
        # Pane breadcrumb & group label (matches PaneGroupLabel + PaneRule in PreferencesView.swift)
        text(x + 16, y + 22, 'Preferences › General', 10.5, SECOND, opacity=0.8, anchor='start'),
        text(x + 16, y + 42, "Apps that don't auto-link", 12, TEXT, weight=600, anchor='start'),
        f"<rect x='{x + 16}' y='{y + 50}' width='{w - 32}' height='1' fill='{INK}' fill-opacity='0.09'/>",
    ]
    # Row 1: Relay
    r1 = y + 58
    out.append(app(x + 16, r1 + 8, 24, 'relay'))
    out.append(text(x + 50, r1 + 17, 'Relay', 13, TEXT, weight=500, anchor='start'))
    out.append(text(x + 50, r1 + 32, 'Manual + linking only', 11, SECOND, anchor='start'))
    out.append(quiet_button(x + w - 68 - 16, r1 + 9.5, 68, 'Turn On'))

    # Divider
    out.append(f"<rect x='{x + 50}' y='{r1 + 44}' width='{w - 66}' height='1' fill='{INK}' fill-opacity='0.09'/>")

    # Row 2: Terminal
    r2 = r1 + 50
    out.append(app(x + 16, r2 + 8, 24, 'terminal'))
    out.append(text(x + 50, r2 + 17, 'Terminal', 13, TEXT, weight=500, anchor='start'))
    out.append(text(x + 50, r2 + 32, 'Manual + linking only', 11, SECOND, anchor='start'))
    out.append(quiet_button(x + w - 68 - 16, r2 + 9.5, 68, 'Turn On'))
    return '\n'.join(out)


def arrow_right(x, y, length=46):
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


def board():
    W, H = 1480, 774
    out = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>",
        defs(),
        f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
        text(56, 56, 'Link apps by hand, and keep refusals quiet', 28, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
        text(56, 82, 'Every account can be linked by hand from its header. Unlinking stays silent — and 3 unlinks in one app stop auto-linking there.',
             13, LABEL, anchor='start'),
    ]

    # Strict 3-column grid across BOTH rows: x = 56, 540, 1024 (each 400pt wide, 84pt gaps)
    x1, x2, x3 = 56, 540, 1024
    top = 148
    cap_top = 408

    # ── TOP ROW: Manual linking flow ──
    # Col 1: Empty account details with self-contained CTA
    out.append(step(x1, 124, '1', 'Open any account'))
    c1, c1h, e1 = details_card(x1, top, 'c1', apps=(), plus_hot=True)
    out.append(c1)
    px1, px2 = e1['+']
    out.append(pointer(px1 + 102, top + 45))
    out.append(note(x1, cap_top, 'Fixed 60 pt header — fields never shift when apps are added.'))

    # Arrow 1 -> 2
    out.append(arrow_right(x1 + 400 + 19, top + 104, 46))

    # Col 2: Picker menu open beneath trigger
    out.append(step(x2, 124, '2', 'Pick an app from the menu'))
    c2, c2h, e2 = details_card(x2, top, 'c2', apps=(), plus_active=True, dim_rows=True)
    out.append(c2)
    mx = e2['+'][0]
    my = top + 33 + 22
    pm, pmh = picker_menu(mx, my, w=244)
    out.append(pm)
    out.append(note(x2, cap_top, 'Details stay open. Already-linked apps are omitted.'))

    # Arrow 2 -> 3
    out.append(arrow_right(x2 + 400 + 19, top + 104, 46))

    # Col 3: Linked state + Overflow state (both drawn at 1:1)
    out.append(step(x3, 124, '3', 'Shown first at once — add or remove'))
    s3a, _ = header_strip(x3, top, apps=('harbor',))
    out.append(s3a)
    out.append(note(x3, top + HEADER_H + 18, 'One app linked — collapses to "Shown first in" + compact +.'))

    s3b, _ = header_strip(x3, top + 114, apps=('harbor', 'ledger'), overflow=2)
    out.append(s3b)
    out.append(note(x3, top + 114 + HEADER_H + 18, 'Overflow shows "2 more" (no +) so the + button stays distinct.'))
    out.append(note(x3, cap_top, 'Click any app chip to unlink it.'))

    # ── HORIZONTAL DIVIDER ──
    div_y = 442
    out.append(f"<rect x='56' y='{div_y}' width='{W - 112}' height='1' fill='{DIVIDER}'/>")

    # ── BOTTOM ROW: Same 3-column grid (x1=56, x2=540, x3=1024; UI band y=528..686; captions y=724) ──
    eyebrow_y = 480
    head_y = 504
    ui_y = 528
    cap_bot = 724

    # Bottom Col 1: Per-account quiet refusal
    out.append(text(x1, eyebrow_y, 'PER-ACCOUNT REFUSAL', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x1, head_y, 'Unlink once — quiet from then on', 16, LABEL_STRONG, weight=600, anchor='start'))
    sa, _ = header_strip(x1, ui_y, apps=('relay',), hover_app='relay')
    out.append(sa)

    out.append(arrow_down(x1 + 20, ui_y + HEADER_H + 10, 32))
    out.append(text(x1 + 36, ui_y + HEADER_H + 30, 'copy password while Relay is in front again', 12, LABEL, anchor='start'))

    # Pure typographic outcome note (distinct from product UI)
    ny = ui_y + HEADER_H + 54
    out.append(f"<rect x='{x1 + 19}' y='{ny}' width='2' height='42' rx='1' fill='{MUTED_RULE}'/>")
    out.append(text(x1 + 34, ny + 16, 'Copied silently to clipboard', 13, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(x1 + 34, ny + 35, 'No auto-link and no "Show first again?" bubble.', 12, LABEL, anchor='start'))
    out.append(note(x1, cap_bot, 'Re-link anytime by hand with +.'))

    # Bottom Col 2: App-level stop after 3 distinct accounts unlinked
    out.append(text(x2, eyebrow_y, 'APP-LEVEL PROTECTION  ·  AGENTS, TERMINALS, CHAT', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x2, head_y, 'Unlink 3 accounts in one app', 16, LABEL_STRONG, weight=600, anchor='start'))

    # Pure typographic rule & timeline (clearly diagram/spec, NOT a UI card)
    out.append(f"<rect x='{x2 + 19}' y='{ui_y + 4}' width='2' height='52' rx='1' fill='{ACCENT}' fill-opacity='0.65'/>")
    out.append(text(x2 + 34, ui_y + 18, '1. Northwind SSO  →  2. Staging DB  →  3. Admin API', 12, LABEL_STRONG, weight=500, anchor='start'))
    out.append(text(x2 + 34, ui_y + 38, 'Counted across Undo or × removals for distinct accounts', 12, LABEL, anchor='start'))
    out.append(text(x2 + 34, ui_y + 54, 'in Relay. On the 3rd, auto-linking stops for Relay:', 12, LABEL, anchor='start'))

    out.append(arrow_down(x2 + 20, ui_y + HEADER_H + 10, 32))
    out.append(text(x2 + 36, ui_y + HEADER_H + 30, 'appears once at bottom of screen (6 s)', 12, LABEL, anchor='start'))

    # Real 1:1 400pt Bubble
    out.append(stopped_bubble(x2, ny, app_name='relay', label='Relay', width=400))
    out.append(note(x2, cap_bot, 'Turn Back On restores future auto-links and resets count.'))

    # Bottom Col 3: Persistent, reversible surface in Preferences
    out.append(text(x3, eyebrow_y, 'REVERSIBLE IN PREFERENCES', 10.5, ACCENT, weight=600, anchor='start', spacing=0.7))
    out.append(text(x3, head_y, 'Manage suppressed apps anytime', 16, LABEL_STRONG, weight=600, anchor='start'))
    out.append(preferences_card(x3, ui_y, w=400, h=158))
    out.append(note(x3, cap_bot, 'Manual + linking still works while auto-link is off.'))

    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..')
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, 'app-link-manual.svg'), 'w') as f:
        f.write(board())

"""Generates the two lock-motion design boards as SVG."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from paths import RIM, KEY

SURFACE = '#FFF6E7'
TEXT = '#302A24'
SECOND = '#70604F'
ACCENT = '#EE8C32'
ON_ACCENT = '#302315'
FIELD = '#FFFFFF'
BORDER = '#C8BBAA'
FOCUS = '#A65312'
DESK = '#1E1F23'
LABEL = '#A9A39B'
LABEL_STRONG = '#ECE6DE'
MENU = '#F1EFEC'
MENU_LINE = '#DAD6D0'
SANS = "font-family='SF Pro Text'"
ROUND = "font-family='SF Pro Rounded'"


def defs():
    return f"""<defs>
  <symbol id='rim' viewBox='0 0 24 24'><path d='{RIM}'/></symbol>
  <symbol id='key' viewBox='0 0 24 24'><path d='{KEY}'/></symbol>
  <filter id='shadow' x='-20%' y='-20%' width='140%' height='150%'>
    <feDropShadow dx='0' dy='10' stdDeviation='14' flood-color='#000' flood-opacity='0.45'/>
  </filter>
</defs>"""


def pie(cx, cy, size, fill=ACCENT, hole=SURFACE, rot=0, opacity=1):
    x, y = cx - size / 2, cy - size / 2
    return (f"<g opacity='{opacity}' transform='rotate({rot} {cx} {cy})'>"
            f"<use href='#rim' x='{x}' y='{y}' width='{size}' height='{size}' fill='{fill}'/></g>"
            f"<use href='#key' x='{x}' y='{y}' width='{size}' height='{size}' fill='{hole}' opacity='{opacity}'/>")


def text(x, y, s, size, fill, weight=400, anchor='middle', font=SANS, opacity=1, spacing=0):
    return (f"<text x='{x}' y='{y}' {font} font-size='{size}' font-weight='{weight}' fill='{fill}' "
            f"text-anchor='{anchor}' opacity='{opacity}' letter-spacing='{spacing}'>{s}</text>")


def menu(x, y, w, h, clip_id):
    """A light unlocked menu: header with search, then site rows."""
    rows = [('header', 'GITHUB.COM'), ('item', 'octocat', '#24292F'), ('item', 'oldcai', '#24292F'),
            ('sep',), ('header', 'RECENT'), ('item', 'Apple Account', '#1D1D1F'),
            ('item', 'Cloudflare', '#F38020'), ('item', 'Fastmail', '#2C5FB6'), ('item', 'Linear', '#5E6AD2'),
            ('item', 'Stripe', '#635BFF'), ('item', 'Vercel', '#111111'), ('item', 'Figma', '#A259FF'),
            ('item', 'Notion', '#222222'), ('item', 'Tailscale', '#3A3A3A'), ('item', 'Hetzner', '#D50C2D'),
            ('item', 'Namecheap', '#DE3723'), ('item', 'Porkbun', '#EF7878')]
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='5'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{MENU}'/>",
           pie(x + 20, y + 20, 22, fill='#4A4540', hole=MENU),
           f"<rect x='{x + 38}' y='{y + 8}' width='{w - 76}' height='24' rx='6' fill='#FFFFFF' stroke='{MENU_LINE}'/>",
           text(x + 48, y + 24.5, 'Search', 12.5, '#9C958D', anchor='start'),
           f"<circle cx='{x + w - 19}' cy='{y + 20}' r='6.5' fill='none' stroke='#6E6862' stroke-width='1.6'/>",
           f"<circle cx='{x + w - 19}' cy='{y + 20}' r='2.2' fill='#6E6862'/>",
           f"<line x1='{x}' y1='{y + 40.5}' x2='{x + w}' y2='{y + 40.5}' stroke='{MENU_LINE}'/>"]
    cy = y + 45
    for r in rows:
        if cy > y + h:
            break
        if r[0] == 'header':
            out.append(text(x + 6, cy + 12, r[1], 9.5, '#8A847D', weight=600, anchor='start', spacing=0.4))
            cy += 16
        elif r[0] == 'sep':
            out.append(f"<line x1='{x + 6}' y1='{cy + 5.5}' x2='{x + w - 6}' y2='{cy + 5.5}' stroke='{MENU_LINE}'/>")
            cy += 11
        else:
            out.append(f"<rect x='{x + 16}' y='{cy + 2.5}' width='16' height='16' rx='4' fill='{r[2]}'/>")
            out.append(text(x + 38, cy + 15, r[1], 13, '#26221E', anchor='start'))
            out.append(f"<path d='M{x + w - 20} {cy + 7} l4 3.5 l-4 3.5' fill='none' stroke='#9C958D' stroke-width='1.4'/>")
            cy += 21
    out.append('</g>')
    return '\n'.join(out)


def lock_face(x, y, w, h, clip_id, opacity=1, pulse=1.0):
    """The lock face that fills whatever frame the menu had. Layout picks by height."""
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='5'/></clipPath>",
           f"<g clip-path='url(#{clip_id})' opacity='{opacity}'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>"]
    if h < 120:
        # One line: pie, then "Locked" and the database name, centred as a group.
        mark = 30
        group = mark + 10 + 120
        left = cx - group / 2
        my = y + h / 2
        out.append(pie(left + mark / 2, my, mark * pulse))
        out.append(text(left + mark + 10, my - 1, 'Locked', 16, TEXT, weight=700, anchor='start', font=ROUND))
        out.append(text(left + mark + 10, my + 14, 'Passwords.kdbx', 10.5, SECOND, anchor='start'))
    else:
        mark = 56 if h >= 200 else 44
        title = 20 if h >= 200 else 17
        block = mark + 12 + title + 6 + 13
        top = y + (h - block) / 2 - 4
        out.append(pie(cx, top + mark / 2, mark * pulse))
        out.append(text(cx, top + mark + 12 + title * 0.78, 'Locked', title, TEXT, weight=700, font=ROUND))
        out.append(text(cx, top + mark + 12 + title + 6 + 10, 'Passwords.kdbx', 11, SECOND))
    out.append('</g>')
    return '\n'.join(out)


def frame_caption(x, y, step, title, note=''):
    out = [text(x, y, step, 10.5, ACCENT, weight=600, anchor='start', spacing=0.6),
           text(x, y + 18, title, 13, LABEL_STRONG, weight=600, anchor='start')]
    if note:
        out.append(text(x, y + 35, note, 11, LABEL, anchor='start'))
    return '\n'.join(out)


def lock_board():
    W, H = 1400, 980
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, '⌘L  Lock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           text(56, 90, 'The panel keeps the menu’s frame. The lock face fills it, centred, and never clips.',
                13, LABEL, anchor='start')]
    # Row 1: the scene in a typical menu frame.
    fw, fh, gap, top = 300, 236, 34, 150
    xs = [56 + i * (fw + gap) for i in range(4)]
    steps = [('0.00 s', 'Menu open, ⌘L'), ('0.00 → 0.20 s', 'Lock face fades in'),
             ('0.30 s', 'Pie settles, padlock clicks'), ('1.15 → 1.50 s', 'Panel fades out')]
    for i, x in enumerate(xs):
        out.append(frame_caption(x, top - 34, *steps[i]))
        if i == 0:
            out.append(f"<g filter='url(#shadow)'>{menu(x, top, fw, fh, f'm{i}')}</g>")
        elif i == 1:
            out.append(f"<g filter='url(#shadow)'>{menu(x, top, fw, fh, f'm{i}')}</g>")
            out.append(lock_face(x, top, fw, fh, f'l{i}', opacity=0.88, pulse=1.035))
        elif i == 2:
            out.append(f"<g filter='url(#shadow)'>{lock_face(x, top, fw, fh, f'l{i}')}</g>")
        else:
            out.append(f"<g opacity='0.45'><g filter='url(#shadow)'>{lock_face(x, top, fw, fh, f'l{i}')}</g></g>")
    # Arrows between frames.
    for x in xs[:-1]:
        ax = x + fw + 8
        out.append(f"<path d='M{ax} {top + fh / 2} h18 m-5 -5 l5 5 l-5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>")

    # Row 2: the same face in the frames a menu can have.
    top2 = 540
    out.append(f"<line x1='56' y1='{top2 - 70}' x2='{W - 56}' y2='{top2 - 70}' stroke='#34353A'/>")
    out.append(text(56, top2 - 38, 'Any menu height', 15, LABEL_STRONG, weight=600, anchor='start'))
    sizes = [(300, 69, 'No matches · 69 pt', 'One line: pie, Locked, database'),
             (300, 150, 'Short list · 150 pt', 'Stacked, 44 pt pie'),
             (340, 380, 'Long list · 380 pt', 'Stacked, 56 pt pie, optical centre')]
    x = 56
    for i, (w, h, title, note) in enumerate(sizes):
        out.append(frame_caption(x, top2 - 4, 'AFTER 0.30 s', title, note))
        out.append(f"<g filter='url(#shadow)'>{lock_face(x, top2 + 46, w, h, f's{i}')}</g>")
        x += w + 70
    out.append('</svg>')
    return '\n'.join(out)


def field(x, y, w, dots, focused, opacity=1, placeholder='Master password'):
    stroke, sw = (FOCUS, 1.5) if focused else (BORDER, 1)
    out = [f"<g opacity='{opacity}'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='38' rx='9' fill='{FIELD}' stroke='{stroke}' stroke-width='{sw}'/>"]
    if dots:
        for i in range(dots):
            out.append(f"<circle cx='{x + 16 + i * 9}' cy='{y + 19}' r='3.1' fill='{TEXT}'/>")
    else:
        out.append(text(x + 11, y + 23.5, placeholder, 13, SECOND, anchor='start'))
    out.append('</g>')
    return '\n'.join(out)


def button(x, y, w, label, fill=ACCENT, ink=ON_ACCENT, icon=None):
    out = [f"<rect x='{x}' y='{y}' width='{w}' height='36' rx='9' fill='{fill}'/>"]
    cx = x + w / 2
    if icon == 'check':
        out.append(f"<path d='M{cx - 38} {y + 18.5} l3.5 3.5 l7 -8' fill='none' stroke='{ink}' stroke-width='2' "
                   f"stroke-linecap='round' stroke-linejoin='round'/>")
        out.append(text(cx + 6, y + 22.5, label, 13, ink, weight=600))
    else:
        out.append(text(cx, y + 22.5, label, 13, ink, weight=600))
    return '\n'.join(out)


def lock_screen(x, y, state, clip_id):
    """300 x 360 lock screen. state: ready, unlocking, unlocked."""
    w, h = 300, 360
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='16'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>"]
    rot = {'ready': 0, 'unlocking': 17, 'unlocked': 30}[state]
    out.append(pie(cx, y + 14 + 32, 64, rot=rot))
    out.append(text(cx, y + 14 + 64 + 4 + 21, 'Password Pie', 22, TEXT, weight=700, font=ROUND))
    out.append(text(cx, y + 125, 'Passwords.kdbx', 11, SECOND, weight=500))
    out.append(text(cx, y + 141, 'Your passwords, kept safe.', 11, SECOND))
    fx, fw = x + 20, w - 40
    fy = y + 160
    if state == 'ready':
        out.append(field(fx, fy, fw, 12, True))
        out.append(button(fx, fy + 46, fw, 'Unlock'))
        footer_opacity = 1
    elif state == 'unlocking':
        out.append(field(fx, fy, fw, 12, False, opacity=0.5))
        out.append(button(fx, fy + 46, fw, 'Unlocking…', fill='#F5C08D', ink='#5A4632'))
        footer_opacity = 0.35
    else:
        out.append(field(fx, fy, fw, 12, False, opacity=0.5))
        out.append(button(fx, fy + 46, fw, 'Unlocked', icon='check'))
        footer_opacity = 0.35
    fy2 = y + h - 12 - 9
    out.append(f"<g opacity='{footer_opacity}'>")
    out.append(text(cx - 8, fy2 + 4, 'Open Database…', 11, SECOND, anchor='end'))
    out.append(f"<line x1='{cx}' y1='{fy2 - 6}' x2='{cx}' y2='{fy2 + 6}' stroke='{BORDER}'/>")
    out.append(text(cx + 8, fy2 + 4, 'New Database…', 11, SECOND, anchor='start'))
    out.append('</g></g>')
    return '\n'.join(out)


def unlock_board():
    W, H = 1400, 620
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 64, 'Unlock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           text(56, 90, 'The form stays where it is. The button carries the progress; the pie’s rim turns.',
                13, LABEL, anchor='start')]
    top, fw, gap = 190, 300, 34
    xs = [56 + i * (fw + gap) for i in range(4)]
    steps = [('RETURN', 'Unlock pressed', ''), ('DECRYPTING', 'Unlocking…', 'Field and links dim, rim turns'),
             ('DONE', 'Unlocked', 'Rim eases onto the next scallop'), ('+0.70 s', 'Menu takes over', 'Face fades and scales to 0.97 first')]
    for i, x in enumerate(xs):
        out.append(frame_caption(x, top - 52, *steps[i]))
        if i < 3:
            out.append(f"<g filter='url(#shadow)'>{lock_screen(x, top, ['ready', 'unlocking', 'unlocked'][i], f'u{i}')}</g>")
        else:
            out.append(f"<g filter='url(#shadow)'>{menu(x, top, fw, 214, 'um')}</g>")
    for x in xs[:-1]:
        ax = x + fw + 8
        out.append(f"<path d='M{ax} {top + 180} h18 m-5 -5 l5 5 l-5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>")
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    out = sys.argv[1]
    open(f'{out}/lock-scene.svg', 'w').write(lock_board())
    open(f'{out}/unlocking.svg', 'w').write(unlock_board())

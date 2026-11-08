"""Round 2 boards: the lock collapses into a card; unlocking keeps the form in place."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from gen import (defs, pie, text, menu, field, button, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT, BORDER,
                 DESK, LABEL, LABEL_STRONG, ROUND, SANS, FOCUS)

ERROR = '#AA3027'
TIME = '#8C8780'
CARD_W, CARD_H = 300, 144
OUTLINE = '#6A655E'


def caption(x, y, time, title, note=''):
    out = [f"<text x='{x}' y='{y}' {SANS} font-size='10.5' font-weight='500' fill='{TIME}' "
           f"style='font-variant-numeric: tabular-nums' letter-spacing='0.3'>{time}</text>",
           text(x, y + 19, title, 13.5, LABEL_STRONG, weight=600, anchor='start')]
    if note:
        out.append(text(x, y + 37, note, 11, LABEL, anchor='start'))
    return '\n'.join(out)


def card(x, y, clip_id, w=CARD_W, h=CARD_H, opacity=1, radius=16, scale=1.0, show_text=True):
    """The locked card: pie, "Locked", database. Always 300 x 144."""
    cx = x + w / 2
    top = y + (h - 100) / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='{radius}'/></clipPath>",
           f"<g clip-path='url(#{clip_id})' opacity='{opacity}'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           pie(cx, top + 24, 48 * scale)]
    if show_text:
        out.append(text(cx, top + 48 + 10 + 15, 'Locked', 19, TEXT, weight=700, font=ROUND))
        out.append(text(cx, top + 48 + 10 + 19 + 13, 'Passwords.kdbx', 11, SECOND))
    out.append('</g>')
    return '\n'.join(out)


def ghost(x, y, w, h, radius=5):
    return (f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='{radius}' fill='none' "
            f"stroke='{OUTLINE}' stroke-dasharray='4 4'/>")


def arrow(x, y):
    return f"<path d='M{x} {y} h18 m-5 -5 l5 5 l-5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>"


def shadowed(inner):
    return f"<g filter='url(#shadow)'>{inner}</g>"


def lock_board():
    W, H = 1400, 900
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, '⌘L  Lock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]
    fw, fh, gap, top = 300, 236, 34, 170
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 40, '0.00 s', 'Menu open, ⌘L'))
    out.append(shadowed(menu(xs[0], top, fw, fh, 'm0')))

    # The list goes under cream at once; the frame folds up from the bottom towards the card.
    out.append(caption(xs[1], top - 40, '0.00 → 0.25 s', 'Folds into the card'))
    out.append(ghost(xs[1], top, fw, fh))
    out.append(shadowed(card(xs[1], top, 'c1', h=190, radius=10, scale=0.9, show_text=False)))

    out.append(caption(xs[2], top - 40, '0.30 s', 'Pie settles, padlock clicks'))
    out.append(ghost(xs[2], top, fw, fh))
    out.append(shadowed(card(xs[2], top, 'c2')))

    out.append(caption(xs[3], top - 40, '1.15 → 1.50 s', 'Fades out'))
    out.append(f"<g opacity='0.4'>{shadowed(card(xs[3], top, 'c3'))}</g>")
    for x in xs[:-1]:
        out.append(arrow(x + fw + 8, top + 72))

    # Row 2: whatever the menu was, the same card, hung from the same top-left corner.
    top2 = 540
    out.append(f"<line x1='56' y1='{top2 - 66}' x2='{W - 56}' y2='{top2 - 66}' stroke='#34353A'/>")
    out.append(text(56, top2 - 30, 'Every menu folds into one card', 15, LABEL_STRONG, weight=600, anchor='start'))
    menus = [(300, 69, 'No matches, 69 pt'), (300, 150, 'Short list, 150 pt'), (360, 290, 'Long list, 290 pt')]
    x = 56
    for i, (w, h, title) in enumerate(menus):
        out.append(caption(x, top2, 'FROM', title))
        y = top2 + 40
        out.append(ghost(x, y, w, h))
        out.append(shadowed(card(x, y, f'r{i}')))
        x += w + 90
    out.append('</svg>')
    return '\n'.join(out)


def lock_screen(x, y, state, clip_id, opacity=1, scale=1.0):
    """300 x 360 lock screen. state: ready, unlocking, wrong."""
    w, h = 300, 360
    cx = x + w / 2
    tf = ''
    if scale != 1.0:
        tf = f" transform='translate({cx} {y + h / 2}) scale({scale}) translate({-cx} {-y - h / 2})'"
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='16'/></clipPath>",
           f"<g opacity='{opacity}'{tf}><g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>"]
    out.append(pie(cx, y + 14 + 32, 64, rot=17 if state == 'unlocking' else 0))
    out.append(text(cx, y + 14 + 64 + 4 + 21, 'Password Pie', 22, TEXT, weight=700, font=ROUND))
    out.append(text(cx, y + 125, 'Passwords.kdbx', 11, SECOND, weight=500))
    out.append(text(cx, y + 141, 'Your passwords, kept safe.', 11, SECOND))
    fx, fw, fy = x + 20, w - 40, y + 160
    footer = 1
    if state == 'ready':
        out.append(field(fx, fy, fw, 12, True))
        out.append(button(fx, fy + 46, fw, 'Unlock'))
    elif state == 'unlocking':
        out.append(field(fx, fy, fw, 12, False, opacity=0.5))
        out.append(button(fx, fy + 46, fw, 'Unlocking…', fill='#F5C08D', ink='#5A4632'))
        footer = 0.35
    else:
        out.append(f"<rect x='{fx}' y='{fy}' width='{fw}' height='38' rx='9' fill='#FFFFFF' stroke='{FOCUS}' stroke-width='1.5'/>")
        out.append(f"<rect x='{fx + 10}' y='{fy + 10}' width='{12 * 9 + 2}' height='18' rx='3' fill='#F7D9B6'/>")
        for i in range(12):
            out.append(f"<circle cx='{fx + 16 + i * 9}' cy='{fy + 19}' r='3.1' fill='{TEXT}'/>")
        out.append(button(fx, fy + 46, fw, 'Unlock'))
        out.append(text(cx, fy + 82 + 6 + 10, 'Incorrect password. Please try again.', 10, ERROR))
    fy2 = y + h - 21
    out.append(f"<g opacity='{footer}'>")
    out.append(text(cx - 8, fy2 + 4, 'Open Database…', 11, SECOND, anchor='end'))
    out.append(f"<line x1='{cx}' y1='{fy2 - 6}' x2='{cx}' y2='{fy2 + 6}' stroke='{BORDER}'/>")
    out.append(text(cx + 8, fy2 + 4, 'New Database…', 11, SECOND, anchor='start'))
    out.append('</g></g></g>')
    return '\n'.join(out)


def unlock_board():
    W, H = 1400, 640
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, 'Unlock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND)]
    top, fw, gap = 190, 300, 34
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 58, 'RETURN', 'Unlock pressed'))
    out.append(shadowed(lock_screen(xs[0], top, 'ready', 'u0')))
    out.append(caption(xs[1], top - 58, 'WHILE DECRYPTING', 'Unlocking…', 'Rim turns. Nothing moves or empties.'))
    out.append(shadowed(lock_screen(xs[1], top, 'unlocking', 'u1')))
    out.append(caption(xs[2], top - 58, 'CORRECT  ·  0.30 s', 'Menu takes over', 'The panel resizes to the menu.'))
    out.append(ghost(xs[2], top, fw, 360, radius=16))
    out.append(shadowed(menu(xs[2], top, fw, 236, 'um')))
    out.append(caption(xs[3], top - 58, 'WRONG', 'Back to the form', 'Shakes, keeps the password selected.'))
    out.append(shadowed(lock_screen(xs[3], top, 'wrong', 'u3')))
    for x in xs[:2]:
        out.append(arrow(x + fw + 8, top + 179))
    # The failure branch leaves the unlocking frame from below.
    bx = xs[1] + fw / 2
    by = top + 360 + 18
    ex = xs[3] + fw / 2
    out.append(f"<path d='M{bx} {by} v22 H{ex} v-14 m-5 5 l5 -5 l5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>")
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    out = sys.argv[1]
    open(f'{out}/lock-scene.svg', 'w').write(lock_board())
    open(f'{out}/unlocking.svg', 'w').write(unlock_board())

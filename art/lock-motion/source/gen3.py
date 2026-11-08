"""Round 3 boards."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from gen import defs, pie, text, field, button, SURFACE, TEXT, SECOND, ACCENT, ON_ACCENT, BORDER, DESK, LABEL, \
    LABEL_STRONG, ROUND, SANS, FOCUS
from gen2 import caption, arrow, shadowed, ERROR

CARD_H = 144
WIRE = '#4A4B52'
WIRE_FILL = '#26272C'
MONO = "font-family='SF Mono, Menlo'"


def legend(x, y, items):
    out = []
    for i, (kind, label) in enumerate(items):
        lx = x + i * 250
        if kind == 'new':
            out.append(f"<rect x='{lx}' y='{y - 9}' width='12' height='12' rx='3' fill='{SURFACE}'/>")
        else:
            out.append(f"<rect x='{lx + 0.5}' y='{y - 8.5}' width='11' height='11' rx='3' fill='{WIRE_FILL}' stroke='{WIRE}'/>")
        out.append(text(lx + 20, y + 1, label, 11.5, LABEL, anchor='start'))
    return '\n'.join(out)


def wire_menu(x, y, w, h, rows=True):
    """The existing menu, as context only: header bar and row lines."""
    out = [f"<rect x='{x + 0.5}' y='{y + 0.5}' width='{w - 1}' height='{h - 1}' rx='5' fill='{WIRE_FILL}' stroke='{WIRE}'/>",
           f"<rect x='{x + 38}' y='{y + 8}' width='{w - 76}' height='24' rx='6' fill='none' stroke='{WIRE}'/>",
           f"<circle cx='{x + 20}' cy='{y + 20}' r='9' fill='none' stroke='{WIRE}'/>",
           f"<line x1='{x}' y1='{y + 40.5}' x2='{x + w}' y2='{y + 40.5}' stroke='{WIRE}'/>"]
    if rows:
        cy = y + 52
        widths = [92, 70, 0, 118, 84, 76, 64, 58, 96, 72, 66, 88]
        for wd in widths:
            if cy + 12 > y + h - 4:
                break
            if wd == 0:
                cy += 11
                continue
            out.append(f"<rect x='{x + 16}' y='{cy}' width='12' height='12' rx='3' fill='{WIRE}'/>")
            out.append(f"<rect x='{x + 38}' y='{cy + 3}' width='{wd}' height='6' rx='3' fill='{WIRE}'/>")
            cy += 21
    return '\n'.join(out)


def card(x, y, w, clip_id, h=CARD_H, radius=12, mark_scale=1.0, words=True, opacity=1):
    cx = x + w / 2
    block = 46 + 14 + 19 + 4 + 13
    top = y + (h - block) / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='{radius}'/></clipPath>",
           f"<g clip-path='url(#{clip_id})' opacity='{opacity}'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           pie(cx, top + 23, 46 * mark_scale)]
    if words:
        out.append(text(cx, top + 46 + 14 + 15, 'Locked', 19, TEXT, weight=700, font=ROUND))
        out.append(text(cx, top + 46 + 14 + 19 + 4 + 10, 'Passwords.kdbx', 11, SECOND))
    out.append('</g>')
    return '\n'.join(out)


def lock_board():
    W, H = 1400, 1000
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, '⌘L', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           text(100, 66, 'Lock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           legend(56, 104, [('new', 'Locked card (new)'), ('old', 'Menu, unchanged')])]
    fw, fh, gap, top = 300, 236, 34, 200
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 40, '0.00 s', 'Menu open, ⌘L'))
    out.append(wire_menu(xs[0], top, fw, fh))

    out.append(caption(xs[1], top - 40, '0.00 → 0.18 s', 'Cream covers, frame folds up'))
    out.append(wire_menu(xs[1], top, fw, fh))
    out.append(shadowed(card(xs[1], top, fw, 'c1', h=188, radius=8, mark_scale=1.08, words=False)))

    out.append(caption(xs[2], top - 40, '0.22 s', 'Mark settles, padlock clicks'))
    out.append(shadowed(card(xs[2], top, fw, 'c2')))

    out.append(caption(xs[3], top - 40, '0.90 → 1.20 s', 'Fades out'))
    out.append(f"<g opacity='0.5'>{shadowed(card(xs[3], top, fw, 'c3'))}</g>")
    for x in xs[:-1]:
        out.append(arrow(x + fw + 8, top + 72))

    # Row 2: one diagram. Three menu heights hang from one corner; all end as the same card, at the menu's width.
    top2 = 560
    out.append(f"<line x1='56' y1='{top2 - 64}' x2='{W - 56}' y2='{top2 - 64}' stroke='#34353A'/>")
    out.append(text(56, top2 - 28, 'One card, from any menu', 15, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(56, top2 - 8, 'Same top-left corner, same width as the menu, always 144 pt tall.', 11.5, LABEL,
                    anchor='start'))
    ax, ay = 96, top2 + 24
    for h, label in [(330, '330 pt menu'), (150, '150 pt menu'), (69, '69 pt menu')]:
        out.append(f"<rect x='{ax + 0.5}' y='{ay + 0.5}' width='299' height='{h - 1}' rx='5' fill='none' "
                   f"stroke='{WIRE}' stroke-dasharray='4 4'/>")
        out.append(f"<path d='M{ax + 300} {ay + h - 0.5} h18' stroke='{WIRE}'/>")
        out.append(f"<text x='{ax + 324}' y='{ay + h + 3.5}' {MONO} font-size='10.5' fill='{LABEL}'>{label}</text>")
    out.append(shadowed(card(ax, ay, 300, 'r0')))
    dx = ax - 18
    out.append(f"<path d='M{dx} {ay} v{CARD_H} M{dx - 4} {ay} h8 M{dx - 4} {ay + CARD_H} h8' stroke='{ACCENT}' fill='none'/>")
    out.append(f"<text x='{dx - 8}' y='{ay + CARD_H / 2 + 4}' {MONO} font-size='10.5' fill='{ACCENT}' text-anchor='end'>144</text>")

    # Right: the menu shortcut during the fade opens the card into the full lock screen.
    rx = 700
    out.append(text(rx, top2 - 28, 'Shortcut pressed while it fades', 15, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(rx, top2 - 8, 'The card grows down into the lock screen; the password field takes the keys.', 11.5,
                    LABEL, anchor='start'))
    out.append(shadowed(card(rx, ay, 300, 'g0', opacity=1)))
    out.append(arrow(rx + 300 + 16, ay + 72))
    out.append(shadowed(lock_screen(rx + 300 + 50, ay, 'empty', 'g1')))
    out.append('</svg>')
    return '\n'.join(out)


def lock_screen(x, y, state, clip_id):
    w, h = 300, 360
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='16'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>"]
    out.append(pie(cx, y + 46, 64, rot=17 if state == 'unlocking' else 0))
    out.append(text(cx, y + 103, 'Password Pie', 22, TEXT, weight=700, font=ROUND))
    out.append(text(cx, y + 125, 'Passwords.kdbx', 11, SECOND, weight=500))
    out.append(text(cx, y + 141, 'Your passwords, kept safe.', 11, SECOND))
    fx, fw, fy = x + 20, w - 40, y + 160
    footer = 1
    if state in ('ready', 'empty'):
        out.append(field(fx, fy, fw, 12 if state == 'ready' else 0, True))
        out.append(button(fx, fy + 46, fw, 'Unlock'))
    elif state == 'unlocking':
        out.append(field(fx, fy, fw, 12, False, opacity=0.55))
        out.append(button(fx, fy + 46, fw, 'Unlocking…'))
        footer = 0.4
    else:
        out.append(f"<rect x='{fx}' y='{fy}' width='{fw}' height='38' rx='9' fill='#FFFFFF' stroke='{FOCUS}' stroke-width='1.5'/>")
        out.append(f"<rect x='{fx + 10}' y='{fy + 10}' width='110' height='18' rx='3' fill='#F7D9B6'/>")
        for i in range(12):
            out.append(f"<circle cx='{fx + 16 + i * 9}' cy='{fy + 19}' r='3.1' fill='{TEXT}'/>")
        out.append(button(fx, fy + 46, fw, 'Unlock'))
        out.append(text(cx, fy + 98, 'Incorrect password. Please try again.', 10, ERROR))
    out.append(f"<g opacity='{footer}'>")
    out.append(text(cx - 8, y + h - 17, 'Open Database…', 11, SECOND, anchor='end'))
    out.append(f"<line x1='{cx}' y1='{y + h - 27}' x2='{cx}' y2='{y + h - 15}' stroke='{BORDER}'/>")
    out.append(text(cx + 8, y + h - 17, 'New Database…', 11, SECOND, anchor='start'))
    out.append('</g></g>')
    return '\n'.join(out)


def unlock_board():
    W, H = 1400, 680
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, 'Unlock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           legend(56, 104, [('new', 'Unlocking state (new)'), ('old', 'Menu, unchanged')])]
    top, fw, gap = 220, 300, 34
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 58, 'RETURN', 'Unlock pressed'))
    out.append(shadowed(lock_screen(xs[0], top, 'ready', 'u0')))
    out.append(caption(xs[1], top - 58, 'WHILE DECRYPTING', 'Unlocking…', 'The form stays put; the rim turns.'))
    out.append(shadowed(lock_screen(xs[1], top, 'unlocking', 'u1')))
    out.append(caption(xs[2], top - 58, 'CORRECT  ·  +0.30 s', 'Menu takes over', 'Form fades as the panel resizes.'))
    out.append(f"<rect x='{xs[2] + 0.5}' y='{top + 0.5}' width='{fw - 1}' height='359' rx='16' fill='none' "
               f"stroke='{WIRE}' stroke-dasharray='4 4'/>")
    out.append(wire_menu(xs[2], top, fw, 236))
    out.append(caption(xs[3], top - 58, 'WRONG', 'Back to the form', 'Window shakes; password stays selected.'))
    out.append(shadowed(lock_screen(xs[3], top, 'wrong', 'u3')))
    for x in xs[:2]:
        out.append(arrow(x + fw + 8, top + 179))
    bx, by, ex = xs[1] + fw / 2, top + 378, xs[3] + fw / 2
    out.append(f"<path d='M{bx} {by} v22 H{ex} v-14 m-5 5 l5 -5 l5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>")
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    out = sys.argv[1]
    open(f'{out}/lock-scene.svg', 'w').write(lock_board())
    open(f'{out}/unlocking.svg', 'w').write(unlock_board())

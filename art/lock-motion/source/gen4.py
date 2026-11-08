"""Round 4 boards: a lock form whose height fits its content; errors take the tagline's line."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from gen import defs, pie, text, field, button, SURFACE, TEXT, SECOND, ACCENT, BORDER, DESK, LABEL, \
    LABEL_STRONG, ROUND, SANS, FOCUS
from gen2 import caption, arrow, shadowed, ERROR
from gen3 import legend, wire_menu, WIRE, MONO, CARD_H

W_PANEL = 300


def form_height(touch_id):
    return 314 if touch_id else 286


def touch_row(cx, y, opacity=1):
    # A fingerprint glyph drawn as three nested arcs, then the label.
    gx = cx - 62
    out = [f"<g opacity='{opacity}' fill='none' stroke='{SECOND}' stroke-width='1.2' stroke-linecap='round'>",
           f"<path d='M{gx - 5} {y + 3} a5 5 0 0 1 10 0 v3'/>",
           f"<path d='M{gx - 2.5} {y + 3.5} a2.5 2.5 0 0 1 5 0 v4'/>",
           f"<path d='M{gx - 7} {y + 6} v-3 a7 7 0 0 1 14 0'/>",
           "</g>",
           text(cx + 8, y + 7, 'Unlock with Touch ID', 11, SECOND, weight=500, opacity=opacity)]
    return '\n'.join(out)


def lock_screen(x, y, state, clip_id, touch_id=True):
    """state: ready, empty, unlocking, wrong."""
    w, h = W_PANEL, form_height(touch_id)
    cx = x + w / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='16'/></clipPath>",
           f"<g clip-path='url(#{clip_id})'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           pie(cx, y + 46, 64, rot=17 if state == 'unlocking' else 0),
           text(cx, y + 103, 'Password Pie', 22, TEXT, weight=700, font=ROUND),
           text(cx, y + 123, 'Passwords.kdbx', 11, SECOND, weight=500)]
    if state == 'wrong':
        out.append(text(cx, y + 139, 'Incorrect password. Please try again.', 11, ERROR, weight=500))
    else:
        out.append(text(cx, y + 139, 'Your passwords, kept safe.', 11, SECOND))
    fx, fw, fy = x + 20, w - 40, y + 156
    dim = 1
    if state in ('ready', 'empty'):
        out.append(field(fx, fy, fw, 12 if state == 'ready' else 0, True))
        out.append(button(fx, fy + 46, fw, 'Unlock'))
    elif state == 'unlocking':
        out.append(field(fx, fy, fw, 12, False, opacity=0.55))
        out.append(button(fx, fy + 46, fw, 'Unlocking…'))
        dim = 0.4
    else:
        out.append(f"<rect x='{fx}' y='{fy}' width='{fw}' height='38' rx='9' fill='#FFFFFF' stroke='{FOCUS}' stroke-width='1.5'/>")
        out.append(f"<rect x='{fx + 10}' y='{fy + 10}' width='110' height='18' rx='3' fill='#F7D9B6'/>")
        for i in range(12):
            out.append(f"<circle cx='{fx + 16 + i * 9}' cy='{fy + 19}' r='3.1' fill='{TEXT}'/>")
        out.append(button(fx, fy + 46, fw, 'Unlock'))
    if touch_id:
        out.append(touch_row(cx, fy + 92, opacity=dim))
    out.append(f"<g opacity='{dim}'>")
    out.append(text(cx - 8, y + h - 17, 'Open Database…', 11, SECOND, anchor='end'))
    out.append(f"<line x1='{cx}' y1='{y + h - 27}' x2='{cx}' y2='{y + h - 15}' stroke='{BORDER}'/>")
    out.append(text(cx + 8, y + h - 17, 'New Database…', 11, SECOND, anchor='start'))
    out.append('</g></g>')
    return '\n'.join(out)


def card(x, y, w, clip_id, h=CARD_H, radius=16, words=True, words_opacity=1, opacity=1):
    """Locked card. The mark sits at the same place whatever the card's height."""
    cx = x + w / 2
    top = y + (CARD_H - 96) / 2
    out = [f"<clipPath id='{clip_id}'><rect x='{x}' y='{y}' width='{w}' height='{h}' rx='{radius}'/></clipPath>",
           f"<g clip-path='url(#{clip_id})' opacity='{opacity}'>",
           f"<rect x='{x}' y='{y}' width='{w}' height='{h}' fill='{SURFACE}'/>",
           pie(cx, top + 23, 46)]
    if words:
        out.append(f"<g opacity='{words_opacity}'>")
        out.append(text(cx, top + 46 + 14 + 15, 'Locked', 19, TEXT, weight=700, font=ROUND))
        out.append(text(cx, top + 46 + 14 + 19 + 4 + 10, 'Passwords.kdbx', 11, SECOND))
        out.append('</g>')
    out.append('</g>')
    return '\n'.join(out)


def dim_line(x, y1, y2, label, color=ACCENT, side='left'):
    tick = f"M{x - 4} {y1} h8 M{x - 4} {y2} h8"
    anchor, tx = ('end', x - 8) if side == 'left' else ('start', x + 8)
    return (f"<path d='M{x} {y1} V{y2} {tick}' stroke='{color}' fill='none'/>"
            f"<text x='{tx}' y='{(y1 + y2) / 2 + 4}' {MONO} font-size='10.5' fill='{color}' text-anchor='{anchor}'>{label}</text>")


def lock_board():
    W, H = 1400, 960
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, '⌘L Lock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           legend(56, 104, [('new', 'New'), ('old', 'Menu, unchanged')])]
    fw, fh, gap, top = 300, 236, 34, 200
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 40, '0.00 s', 'Menu open, ⌘L'))
    out.append(wire_menu(xs[0], top, fw, fh))
    out.append(caption(xs[1], top - 40, '0.00 → 0.18 s', 'Cream covers, frame folds up'))
    out.append(wire_menu(xs[1], top, fw, fh))
    out.append(shadowed(card(xs[1], top, fw, 'c1', h=184, radius=10, words=True, words_opacity=0.25)))
    out.append(caption(xs[2], top - 40, '0.22 s', 'Mark settles, padlock clicks'))
    out.append(shadowed(card(xs[2], top, fw, 'c2')))
    out.append(caption(xs[3], top - 40, '0.90 → 1.20 s', 'Lifts 6 pt and fades'))
    out.append(f"<g opacity='0.45' transform='translate(0 -6)'>{shadowed(card(xs[3], top, fw, 'c3'))}</g>")
    for x in xs[:-1]:
        out.append(arrow(x + fw + 8, top + 72))

    top2 = 560
    out.append(f"<line x1='56' y1='{top2 - 64}' x2='{W - 56}' y2='{top2 - 64}' stroke='#34353A'/>")
    out.append(text(56, top2 - 28, 'One card, from any menu', 15, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(56, top2 - 8, 'Hangs from the menu’s top-left corner, at its width.', 11.5, LABEL, anchor='start'))
    ax, ay = 112, top2 + 24
    for h, label in [(330, '330 pt menu'), (150, '150 pt menu'), (69, '69 pt menu')]:
        out.append(f"<rect x='{ax + 0.5}' y='{ay + 0.5}' width='299' height='{h - 1}' rx='5' fill='none' "
                   f"stroke='{WIRE}' stroke-dasharray='4 4'/>")
        out.append(f"<path d='M{ax + 300} {ay + h - 0.5} h18' stroke='{WIRE}'/>")
        out.append(f"<text x='{ax + 324}' y='{ay + h + 3.5}' {MONO} font-size='10.5' fill='{LABEL}'>{label}</text>")
    out.append(shadowed(card(ax, ay, 300, 'r0')))
    out.append(dim_line(ax - 18, ay, ay + CARD_H, '144'))

    rx = 720
    out.append(text(rx, top2 - 28, 'Shortcut pressed while it fades', 15, LABEL_STRONG, weight=600, anchor='start'))
    out.append(text(rx, top2 - 8, 'The card grows down into the lock form, focused.', 11.5, LABEL, anchor='start'))
    out.append(shadowed(card(rx, ay, 300, 'g0')))
    out.append(arrow(rx + 300 + 14, ay + 72))
    out.append(shadowed(lock_screen(rx + 300 + 46, ay, 'empty', 'g1')))
    out.append('</svg>')
    return '\n'.join(out)


def unlock_board():
    W, H = 1400, 640
    out = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{W}' height='{H}' viewBox='0 0 {W} {H}'>", defs(),
           f"<rect width='{W}' height='{H}' fill='{DESK}'/>",
           text(56, 66, 'Unlock', 26, LABEL_STRONG, weight=700, anchor='start', font=ROUND),
           legend(56, 104, [('new', 'New'), ('old', 'Menu, unchanged')])]
    top, fw, gap = 220, 300, 34
    fh = form_height(True)
    xs = [56 + i * (fw + gap) for i in range(4)]
    out.append(caption(xs[0], top - 58, 'RETURN', 'Unlock pressed', 'The form is as tall as what it holds.'))
    out.append(shadowed(lock_screen(xs[0], top, 'ready', 'u0')))
    out.append(dim_line(xs[0] - 14, top, top + fh, str(fh)))
    out.append(caption(xs[1], top - 58, 'WHILE DECRYPTING', 'Unlocking…', 'Nothing moves or empties; the rim turns.'))
    out.append(shadowed(lock_screen(xs[1], top, 'unlocking', 'u1')))
    out.append(caption(xs[2], top - 58, 'CORRECT  ·  +0.30 s', 'Menu takes over', 'The form fades as the panel resizes.'))
    out.append(f"<rect x='{xs[2] + 0.5}' y='{top + 0.5}' width='{fw - 1}' height='{fh - 1}' rx='16' fill='none' "
               f"stroke='{WIRE}' stroke-dasharray='4 4'/>")
    out.append(wire_menu(xs[2], top, fw, 236))
    out.append(caption(xs[3], top - 58, 'WRONG', 'Back to the form', 'Shakes; the error takes the tagline’s line.'))
    out.append(shadowed(lock_screen(xs[3], top, 'wrong', 'u3')))
    for x in xs[:2]:
        out.append(arrow(x + fw + 8, top + fh / 2))
    bx, by, ex = xs[1] + fw / 2, top + fh + 18, xs[3] + fw / 2
    out.append(f"<path d='M{bx} {by} v22 H{ex} v-14 m-5 5 l5 -5 l5 5' fill='none' stroke='#5B5650' stroke-width='1.5'/>")
    out.append('</svg>')
    return '\n'.join(out)


if __name__ == '__main__':
    out = sys.argv[1]
    open(f'{out}/lock-scene.svg', 'w').write(lock_board())
    open(f'{out}/unlocking.svg', 'w').write(unlock_board())

"""ClaudeBook app icon: Clawd (the Claude Code pixel crab) doodling in a notebook.

    python3 make_icon.py > AppIcon.svg

Render the SVG at 1024x1024 with any SVG renderer (we used headless Chromium at 2x,
downscaled), then flatten to RGB: iOS rejects app icons with an alpha channel.
bg can be "orange" (the shipped icon), "dark" or "cream".
"""
import math, sys

S = 1024
ORANGE = "#D97757"
ORANGE_DK = "#B85A3C"
INK = "#1F1E1D"


def clawd(x0, y0, u, body=ORANGE, shade=ORANGE_DK, eye=INK, blush=None, shine=False):
    """Clawd on a square grid: 16u wide, 10u tall. Eyes/legs follow the
    Claude Code terminal logo (quadrant blocks, 1:2 cells)."""
    r = []
    def px(x, y, w, h, fill):
        r.append(f'<rect x="{x0+x*u:.2f}" y="{y0+y*u:.2f}" width="{w*u:.2f}" height="{h*u:.2f}" fill="{fill}"/>')
    # legs first so the body overlaps their tops
    for lx in (3, 5, 10, 12):
        px(lx, 7.9, 1, 2.1, body)
    px(2, 0, 12, 8, body)          # body
    px(0, 4, 2, 2, body)           # left claw
    px(14, 4, 2, 2, body)          # right claw
    # soft bottom shade on body for a bit of depth
    px(2, 7.25, 12, 0.75, shade)
    px(0, 5.5, 2, 0.5, shade)
    px(14, 5.5, 2, 0.5, shade)
    # eyes
    px(4, 2, 1, 2, eye)
    px(11, 2, 1, 2, eye)
    if shine:
        px(4.12, 2.15, 0.4, 0.45, "#FFFFFF")
        px(11.12, 2.15, 0.4, 0.45, "#FFFFFF")
    if blush:
        px(3, 4.5, 1.5, 0.75, blush)
        px(11.5, 4.5, 1.5, 0.75, blush)
    return "\n".join(r)


def cursive(x0, y0, length, r=16, k=10, turns=None, w=7, color="#6B6A66"):
    """Fake handwriting: a prolate cycloid gives loopy cursive."""
    if turns is None:
        turns = length / (k * 2 * math.pi)
    pts = []
    n = int(turns * 40)
    for i in range(n + 1):
        t = i / 40 * 2 * math.pi
        x = x0 + k * t + r * 0.85 * math.sin(t)
        y = y0 + r * math.cos(t) * 0.9 - r * 0.9
        pts.append(f"{x:.1f},{y:.1f}")
    return f'<polyline points="{" ".join(pts)}" fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>'


def hand_ellipse(cx, cy, rx, ry, color=ORANGE, w=11, rot=-6):
    """A loop drawn by hand: a bit more than one turn, wobbly radius."""
    pts = []
    n = 120
    for i in range(n + 1):
        t = -0.6 + i / n * (2 * math.pi + 0.95)
        wob = 1 + 0.04 * math.sin(3 * t + 0.5) + 0.025 * (t / (2 * math.pi))
        x = cx + rx * wob * math.cos(t)
        y = cy + ry * wob * math.sin(t)
        pts.append(f"{x:.1f},{y:.1f}")
    return (f'<g transform="rotate({rot} {cx} {cy})"><polyline points="{" ".join(pts)}" fill="none" '
            f'stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/></g>')


LEAD = "#D97757"

def pencil(tipx, tipy, angle, length=360, th=58):
    """Yellow pencil, tip at (tipx, tipy), body going off at `angle` degrees."""
    h = th / 2
    cone = th * 1.15
    lead = cone * 0.32
    ferrule = th * 0.62
    eraser = th * 0.72
    body_end = length - ferrule - eraser
    g = []
    # wood cone
    g.append(f'<polygon points="0,0 {cone},{-h} {cone},{h}" fill="#F2CF9B"/>')
    g.append(f'<polygon points="0,0 {cone},{h*0.05} {cone},{h}" fill="#E2B57A"/>')
    # graphite
    g.append(f'<polygon points="0,0 {lead},{-h*lead/cone} {lead},{h*lead/cone}" fill="{LEAD}"/>')
    # body with three facets
    g.append(f'<rect x="{cone}" y="{-h}" width="{body_end-cone}" height="{th}" fill="#F7C548"/>')
    g.append(f'<rect x="{cone}" y="{-h}" width="{body_end-cone}" height="{th*0.3}" fill="#FBDA7A"/>')
    g.append(f'<rect x="{cone}" y="{h-th*0.32}" width="{body_end-cone}" height="{th*0.32}" fill="#E5A92E"/>')
    # scalloped edge where paint meets wood
    sc = []
    for i in range(3):
        y1 = -h + i * th / 3
        y2 = y1 + th / 3
        sc.append(f'M{cone},{y1} Q{cone-th*0.16},{(y1+y2)/2} {cone},{y2}')
    g.append(f'<path d="{" ".join(sc)} Z" fill="#F2CF9B"/>')
    # ferrule
    g.append(f'<rect x="{body_end}" y="{-h}" width="{ferrule}" height="{th}" fill="#C9CDD3"/>')
    for i in range(1, 3):
        xx = body_end + ferrule * i / 3
        g.append(f'<rect x="{xx-2.5}" y="{-h}" width="5" height="{th}" fill="#A3A8B0"/>')
    g.append(f'<rect x="{body_end}" y="{h-th*0.3}" width="{ferrule}" height="{th*0.3}" fill="#000" opacity=".12"/>')
    # eraser
    g.append(f'<path d="M{body_end+ferrule},{-h} h{eraser-14} q14,0 14,14 v{th-28} q0,14 -14,14 h{-(eraser-14)} Z" fill="#F08C9A"/>')
    g.append(f'<path d="M{body_end+ferrule},{h-th*0.3} h{eraser-6} q6,0 0,0 v0 h0 v{th*0.3-14} q0,14 -14,14 h{-(eraser-14)} Z" fill="#D9707F" opacity=".9"/>')
    return f'<g transform="translate({tipx} {tipy}) rotate({angle})">' + "".join(g) + "</g>"


def sparkle(cx, cy, s, color):
    return (f'<path d="M{cx},{cy-s} Q{cx+s*0.16},{cy-s*0.16} {cx+s},{cy} Q{cx+s*0.16},{cy+s*0.16} {cx},{cy+s} '
            f'Q{cx-s*0.16},{cy+s*0.16} {cx-s},{cy} Q{cx-s*0.16},{cy-s*0.16} {cx},{cy-s} Z" fill="{color}"/>')


def icon(bg="orange", blush=True, tilt=-4, U=29, CX=556, CY=846, PTX=14.3, PTY=9.6, PA=-64, PL=360, SHINE=True, LINES=3):
    if bg == "orange":
        bgdef = '<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#EA9677"/><stop offset="1" stop-color="#C8603E"/></linearGradient>'
        dots = "#FFF3EA"; dot_op = 0.16
        spark = "#FFF1E6"
    elif bg == "dark":
        bgdef = '<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#3A3936"/><stop offset="1" stop-color="#1C1B1A"/></linearGradient>'
        dots = "#FFFFFF"; dot_op = 0.07
        spark = "#F2B49A"
    else:  # cream
        bgdef = '<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#F6EFE4"/><stop offset="1" stop-color="#E7D9C4"/></linearGradient>'
        dots = "#9C8466"; dot_op = 0.18
        spark = ORANGE

    paper = "#FFFCF6"
    # page geometry (before tilt)
    px0, py0, pw, ph = 236, 150, 600, 724
    pcx, pcy = px0 + pw / 2, py0 + ph / 2

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}">',
           '<defs>', bgdef,
           f'<pattern id="dots" width="64" height="64" patternUnits="userSpaceOnUse"><circle cx="32" cy="32" r="4.5" fill="{dots}" opacity="{dot_op}"/></pattern>',
           '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="22"/><feComponentTransfer><feFuncA type="linear" slope=".28"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
           '<filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="8"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".22"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
           f'<clipPath id="pageclip"><rect x="{px0}" y="{py0}" width="{pw}" height="{ph}" rx="46"/></clipPath>',
           '</defs>',
           f'<rect width="{S}" height="{S}" fill="url(#bg)"/>',
           f'<rect width="{S}" height="{S}" fill="url(#dots)"/>']

    # notebook page, tilted
    out.append(f'<g transform="rotate({tilt} {pcx} {pcy})">')
    out.append(f'<g filter="url(#shadow)">')
    # back sheet peeking out for a "stack of pages" feel
    out.append(f'<rect x="{px0+14}" y="{py0+16}" width="{pw}" height="{ph}" rx="46" fill="#EFE6D8"/>')
    out.append(f'<rect x="{px0}" y="{py0}" width="{pw}" height="{ph}" rx="46" fill="{paper}"/>')
    out.append('</g>')
    out.append('<g clip-path="url(#pageclip)">')
    for i in range(10):
        y = py0 + 150 + i * 64
        out.append(f'<rect x="{px0}" y="{y}" width="{pw}" height="5" fill="#B9D0EC"/>')
    out.append(f'<rect x="{px0+122}" y="{py0}" width="5" height="{ph}" fill="#F3A9A9"/>')
    out.append('</g>')
    # spiral binding
    for i in range(7):
        y = py0 + 78 + i * 96
        out.append(f'<circle cx="{px0+44}" cy="{y}" r="13" fill="#D9CFC0"/>')
        out.append(f'<path d="M{px0+44},{y} C{px0-10},{y-6} {px0-42},{y+4} {px0-30},{y+30}" fill="none" stroke="#4A4743" stroke-width="13" stroke-linecap="round"/>')
    # handwriting + Claude's circle
    out.append(cursive(px0 + 160, py0 + 206, 340, r=22, k=13, w=8))
    out.append(cursive(px0 + 160, py0 + 270, 230, r=22, k=13, w=8))
    if LINES >= 3:
        out.append(cursive(px0 + 160, py0 + 334, 290, r=22, k=13, w=8))
    out.append(hand_ellipse(px0 + 400, py0 + 240, 128, 62, w=12, rot=-6))
    out.append('</g>')

    # Clawd, upright, in front of the page
    u = U
    cw, chh = 16 * u, 10 * u
    cx0 = CX - cw / 2
    cy0 = CY - chh
    out.append(f'<g filter="url(#soft)">')
    # pencil goes behind his right claw
    out.append(pencil(cx0 + PTX * u, cy0 + PTY * u, PA, length=PL, th=58))
    out.append(clawd(cx0, cy0, u, blush="#F2A08A" if blush else None, shine=SHINE))
    # right claw in front of the pencil so he's holding it
    out.append(f'<rect x="{cx0+14*u:.1f}" y="{cy0+4*u:.1f}" width="{2*u}" height="{2*u}" fill="{ORANGE}"/>')
    out.append(f'<rect x="{cx0+14*u:.1f}" y="{cy0+5.5*u:.1f}" width="{2*u}" height="{0.5*u}" fill="{ORANGE_DK}"/>')
    out.append('</g>')

    out.append(sparkle(150, 200, 34, spark))
    out.append(sparkle(880, 860, 26, spark))
    out.append('</svg>')
    return "\n".join(out)


if __name__ == "__main__":
    print(icon(bg=sys.argv[1] if len(sys.argv) > 1 else "orange"))

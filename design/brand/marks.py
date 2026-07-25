"""Cuate — six marks from one grammar: two discs of equal radius at different phases."""
import math, json, os

R = 300.0
CX = CY = 512.0

def crescent(ax, ay, bx, by, r=R):
    """Path for (disc A) minus (disc B), equal radii. Generic flag resolution."""
    dx, dy = bx - ax, by - ay
    dist = math.hypot(dx, dy)
    if dist == 0 or dist >= 2 * r:
        raise ValueError('discs must overlap and not coincide')
    ux, uy = dx / dist, dy / dist
    px, py = -uy, ux
    mx, my = ax + dx / 2, ay + dy / 2
    h = math.sqrt(r * r - (dist / 2) ** 2)
    p1 = (mx + h * px, my + h * py)
    p2 = (mx - h * px, my - h * py)

    def arc(cx, cy, s, e, through):
        a1 = math.atan2(s[1] - cy, s[0] - cx)
        a2 = math.atan2(e[1] - cy, e[0] - cx)
        af = math.atan2(through[1] - cy, through[0] - cx)
        # forward (increasing angle) span from a1 to a2
        fwd = (a2 - a1) % (2 * math.pi)
        fwd_f = (af - a1) % (2 * math.pi)
        if fwd_f <= fwd:                    # F sits on the increasing path
            sweep, span = 1, fwd
        else:
            sweep, span = 0, 2 * math.pi - fwd
        large = 1 if span > math.pi else 0
        return f'A {r:.2f} {r:.2f} 0 {large} {sweep} {e[0]:.2f} {e[1]:.2f}'

    far  = (ax - r * ux, ay - r * uy)       # point of A furthest from B
    near = (bx - r * ux, by - r * uy)       # point of B deepest inside A
    return (f'M {p1[0]:.2f} {p1[1]:.2f} '
            + arc(ax, ay, p1, p2, far) + ' '
            + arc(bx, by, p2, p1, near) + ' Z')


def half(ax, ay, r, angle_deg, side=1):
    """Half disc cut by a chord through the centre at `angle_deg`."""
    a = math.radians(angle_deg)
    p1 = (ax + r * math.cos(a), ay + r * math.sin(a))
    p2 = (ax - r * math.cos(a), ay - r * math.sin(a))
    sweep = 1 if side > 0 else 0
    return (f'M {p1[0]:.2f} {p1[1]:.2f} '
            f'A {r:.2f} {r:.2f} 0 0 {sweep} {p2[0]:.2f} {p2[1]:.2f} Z')


def lens(ax, ay, bx, by, r=R):
    """Intersection of two equal discs — the vesica."""
    dx, dy = bx - ax, by - ay
    dist = math.hypot(dx, dy)
    ux, uy = dx / dist, dy / dist
    px, py = -uy, ux
    mx, my = ax + dx / 2, ay + dy / 2
    h = math.sqrt(r * r - (dist / 2) ** 2)
    p1 = (mx + h * px, my + h * py)
    p2 = (mx - h * px, my - h * py)
    return (f'M {p1[0]:.2f} {p1[1]:.2f} '
            f'A {r:.2f} {r:.2f} 0 0 1 {p2[0]:.2f} {p2[1]:.2f} '
            f'A {r:.2f} {r:.2f} 0 0 1 {p1[0]:.2f} {p1[1]:.2f} Z')


WARM = ('#C77800', '#F9A211', '#FFD27A', '#FEFCF2')
COOL = ('#344E65', '#5C7A96', '#839DB5', '#ACBFD2')

def grads():
    def stops(cs, ids, x1, y1, x2, y2):
        s = ''.join(f'<stop offset="{o}%" stop-color="{c}"/>'
                    for o, c in zip((0, 42, 76, 100), cs))
        return (f'<linearGradient id="{ids}" gradientUnits="userSpaceOnUse" '
                f'x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>')
    return ('<defs>' + stops(WARM, 'w', 300, 330, 700, 820)
            + stops(COOL, 'c', 760, 700, 300, 240) + '</defs>')


def svg(body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
            f'width="1024" height="1024" role="img" aria-label="Cuate — {title}">'
            f'<title>Cuate — {title}</title>{grads()}{body}</svg>')


# ---- the six phases -------------------------------------------------------
MARKS = {}

# 1 · ECLIPSE — two rim lights on one body. The chosen mark.
MARKS['eclipse'] = svg(
    f'<path fill="url(#w)" d="{crescent(CX, CY, CX - 28, CY - 106)}"/>'
    f'<path fill="url(#c)" d="{crescent(CX, CY, CX + 18, CY + 68)}"/>',
    'eclipse')

# 2 · FASE — one crescent only. Survives smallest.
MARKS['fase'] = svg(
    f'<path fill="url(#w)" d="{crescent(CX, CY, CX - 40, CY - 150)}"/>', 'fase')

# 3 · TERMINADOR — the day/night line. Flattest, most reductive.
MARKS['terminador'] = svg(
    f'<path fill="url(#w)" d="{half(CX, CY, R, 8, 1)}"/>'
    f'<path fill="url(#c)" d="{half(CX, CY, R, 8, 0)}" opacity="0.55"/>', 'terminador')

# 4 · SICIGIA — two bodies in a line, each keeping its own light.
_s = 168.0
MARKS['sicigia'] = svg(
    f'<g transform="translate(-{_s} 0)"><path fill="url(#w)" '
    f'd="{crescent(CX, CY, CX - 24, CY - 118)}"/></g>'
    f'<g transform="translate({_s} 0)"><path fill="url(#c)" '
    f'd="{crescent(CX, CY, CX + 24, CY + 118)}"/></g>', 'sicigia')

# 5 · CONJUNCION — the overlap itself is what lights up.
_o = 150.0
MARKS['conjuncion'] = svg(
    f'<path fill="url(#w)" d="{crescent(CX - _o, CY, CX + _o, CY)}" opacity="0.30"/>'
    f'<path fill="url(#c)" d="{crescent(CX + _o, CY, CX - _o, CY)}" opacity="0.30"/>'
    f'<path fill="url(#w)" d="{lens(CX - _o, CY, CX + _o, CY)}"/>', 'conjuncion')

# 6 · ANILLO — total occultation, light escapes all the way round.
MARKS['anillo'] = svg(
    f'<path fill="url(#w)" d="{crescent(CX, CY, CX - 6, CY - 24)}"/>'
    f'<path fill="url(#c)" d="{crescent(CX, CY, CX + 6, CY + 24)}"/>', 'anillo')

os.makedirs('/home/claude/brand/marks', exist_ok=True)
for name, doc in MARKS.items():
    open(f'/home/claude/brand/marks/{name}.svg', 'w').write(doc)
print('wrote', ', '.join(MARKS))

# menu bar reductions of each, monochrome, 18 pt
MB = {
    'eclipse':    crescent(9, 9.4, 8.2, 6.5, 6.6),
    'fase':       crescent(9, 9.4, 8.6, 5.9, 6.6),
    'terminador': half(9, 9, 6.6, 8, 1),
    'anillo':     crescent(9, 9.4, 8.9, 8.9, 6.6),
}
json.dump(MB, open('/home/claude/brand/menubar_paths.json', 'w'), indent=2)
print('menu bar paths ready')

# ---- refinement: cut the ring open so it reads as two lights, not a loader ----
def halfplane(cx, cy, angle_deg, gap, ident):
    """Clip rect covering the half-plane on the far side of a line through (cx,cy)
    perpendicular to `angle_deg`, pushed back by `gap`."""
    a = math.radians(angle_deg)
    ox, oy = -math.cos(a) * gap, -math.sin(a) * gap
    return (f'<clipPath id="{ident}"><rect x="-1200" y="-1200" width="2400" height="1200" '
            f'transform="rotate({angle_deg + 90} {cx + ox} {cy + oy}) '
            f'translate({cx + ox - 0} {cy + oy - 0}) translate(-0 -0)"/></clipPath>')

def cut_rect(cx, cy, angle_deg, gap):
    """Rect (in local space) rotated so it keeps the side the far point lies on."""
    return (f'<g transform="rotate({angle_deg} {cx} {cy})">'
            f'<rect x="{cx - 1200}" y="{cy + gap}" width="2400" height="2400"/></g>')

GAP = 26
warm_dir = math.degrees(math.atan2(-106, -28))     # direction A -> warm twin
cool_dir = math.degrees(math.atan2(68, 18))
# keep the side opposite each twin
body_eclipse2 = (
    f'<defs>'
    f'<clipPath id="kw">{cut_rect(CX, CY, warm_dir + 90, GAP)}</clipPath>'
    f'<clipPath id="kc">{cut_rect(CX, CY, cool_dir + 90, GAP)}</clipPath>'
    f'</defs>'
    f'<g clip-path="url(#kw)"><path fill="url(#w)" d="{crescent(CX, CY, CX - 28, CY - 106)}"/></g>'
    f'<g clip-path="url(#kc)"><path fill="url(#c)" d="{crescent(CX, CY, CX + 18, CY + 68)}"/></g>')
MARKS['eclipse2'] = svg(body_eclipse2, 'eclipse, cut')
open('/home/claude/brand/marks/eclipse2.svg', 'w').write(MARKS['eclipse2'])
print('wrote eclipse2  warm_dir=%.1f cool_dir=%.1f' % (warm_dir, cool_dir))

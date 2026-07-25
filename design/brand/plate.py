"""CUATE · LÁMINA I — a phase table of the twin, drawn as a systematic plate."""
import math
from marks import crescent

W, H = 2480, 3508                      # A4 at 300 dpi
M = 210                                # outer margin

OBS = '#08070C'
CAL = '#FEFCF2'
AMB = '#F9A211'
AMB_D = '#B07000'
CIE = '#5C7A96'
CIE_L = '#839DB5'
PIE_600 = '#726E69'
PIE_800 = '#39342F'

# ---- phase grid -------------------------------------------------------------
COLS, ROWS = 9, 8
CELL = 180
GX = (W - 2 * M - COLS * CELL) / (COLS - 1)     # gutter
GRID_TOP = 1180
GY = 30
r = 68.0                                        # disc radius inside a cell

# columns sweep the twin's bearing, rows sweep its distance
BEARINGS = [-165, -150, -135, -120, -104.8, -90, -75, -60, -45]
RATIOS = [0.063, 0.125, 0.188, 0.250, 0.305, 0.3667, 0.428, 0.490]
DISTANCES = [round(k * r, 2) for k in RATIOS]
CANON_COL, CANON_ROW = 4, 5                     # the chosen mark's coordinates

def cell_svg(cx, cy, bearing, dist, canonical):
    a = math.radians(bearing)
    bx, by = cx + dist * math.cos(a), cy + dist * math.sin(a)
    try:
        d = crescent(cx, cy, bx, by, r)
    except ValueError:
        return ''
    col = AMB if canonical else AMB_D
    op = 1.0 if canonical else 0.86
    ring = AMB if canonical else PIE_800
    rw = 1.6 if canonical else 1.1
    out = (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r + (10 if canonical else 0):.1f}" '
           f'fill="none" stroke="{ring}" stroke-width="{rw}" '
           f'opacity="{0.55 if canonical else 1}"/>'
           f'<path d="{d}" fill="{col}" opacity="{op}"/>')
    if canonical:
        a2 = a + math.pi
        b2x, b2y = cx + 0.636 * dist * math.cos(a2), cy + 0.636 * dist * math.sin(a2)
        out += f'<path d="{crescent(cx, cy, b2x, b2y, r)}" fill="{CIE}"/>'
    return out

cells = []
for row in range(ROWS):
    for col in range(COLS):
        cx = M + col * (CELL + GX) + CELL / 2
        cy = GRID_TOP + row * (CELL + GY) + CELL / 2
        cells.append(cell_svg(cx, cy, BEARINGS[col], DISTANCES[row],
                              col == CANON_COL and row == CANON_ROW))
GRID_BOTTOM = GRID_TOP + ROWS * (CELL + GY) - GY

# ---- axis ticks -------------------------------------------------------------
ticks = []
for col in range(COLS):
    cx = M + col * (CELL + GX) + CELL / 2
    ticks.append(f'<text x="{cx:.1f}" y="{GRID_TOP - 38}" class="tick" '
                 f'text-anchor="middle">{BEARINGS[col]:.0f}°</text>')
for row in range(ROWS):
    cy = GRID_TOP + row * (CELL + GY) + CELL / 2
    ticks.append(f'<text x="{M - 38}" y="{cy + 9:.1f}" class="tick" '
                 f'text-anchor="end">{RATIOS[row]:.3f}</text>')

# ---- palette band -----------------------------------------------------------
PAL = [('OBSIDIANA', '#08070C'), ('PIEDRA', '#726E69'), ('CIELO', '#5C7A96'),
       ('ÁMBAR', '#F9A211'), ('CAL', '#FEFCF2')]
BAND_Y = GRID_BOTTOM + 128
bw = (W - 2 * M - 4 * 26) / 5
band = []
for i, (nm, hx) in enumerate(PAL):
    x = M + i * (bw + 26)
    band.append(f'<rect x="{x:.1f}" y="{BAND_Y}" width="{bw:.1f}" height="26" fill="{hx}"/>'
                f'<text x="{x:.1f}" y="{BAND_Y + 62}" class="mono s">{nm}</text>'
                f'<text x="{x:.1f}" y="{BAND_Y + 100}" class="mono s dim">{hx}</text>')

# ---- corner registration ----------------------------------------------------
def reg(x, y, sx, sy):
    L = 46
    return (f'<path d="M {x} {y + sy * L} L {x} {y} L {x + sx * L} {y}" '
            f'fill="none" stroke="{PIE_800}" stroke-width="1.6"/>')
regs = (reg(96, 96, 1, 1) + reg(W - 96, 96, -1, 1)
        + reg(96, H - 96, 1, -1) + reg(W - 96, H - 96, -1, -1))

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}"
     viewBox="0 0 {W} {H}">
<defs>
  <radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="{W/2}" cy="{H*0.60}" r="{W*0.78}">
    <stop offset="0%" stop-color="#F9A211" stop-opacity="0.075"/>
    <stop offset="48%" stop-color="#C77800" stop-opacity="0.022"/>
    <stop offset="100%" stop-color="#C77800" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="hw"><g transform="rotate(-14.8 176 176)"><rect x="-1024" y="191" width="2400" height="2400"/></g></clipPath>
  <clipPath id="hc"><g transform="rotate(165.2 176 176)"><rect x="-1024" y="191" width="2400" height="2400"/></g></clipPath>
  <style>
    text {{ font-family: 'Geist Mono'; fill: {CAL}; }}
    .display {{ font-family: 'Outfit'; font-size: 196px; letter-spacing: 0.055em; fill: {CAL}; }}
    .sub {{ font-family: 'Outfit'; font-size: 40px; letter-spacing: 0.30em; fill: {CIE_L}; }}
    .mono {{ font-family: 'Geist Mono'; font-size: 25px; letter-spacing: 0.16em; fill: {CAL}; }}
    .mono.s {{ font-size: 22px; }}
    .dim {{ fill: {PIE_600}; }}
    .tick {{ font-family: 'Geist Mono'; font-size: 21px; letter-spacing: 0.10em; fill: {PIE_600}; }}
    .note {{ font-family: 'Geist Mono'; font-size: 23px; letter-spacing: 0.10em; fill: {PIE_600}; }}
    .anchor {{ font-family: 'Outfit'; font-size: 54px; letter-spacing: 0.22em; fill: {AMB}; }}
  </style>
</defs>

<rect width="{W}" height="{H}" fill="{OBS}"/>
<rect width="{W}" height="{H}" fill="url(#glow)"/>
{regs}

<!-- header -->
<text x="{M}" y="{M + 6}" class="mono dim">CUATE</text>
<text x="{W - M}" y="{M + 6}" class="mono dim" text-anchor="end">LÁMINA&#160;I</text>
<line x1="{M}" y1="{M + 44}" x2="{W - M}" y2="{M + 44}" stroke="{PIE_800}" stroke-width="1.6"/>

<text x="{M}" y="{M + 292}" class="display">FASES</text>
<text x="{M}" y="{M + 372}" class="sub">DEL&#160;GEMELO</text>

<text x="{W - M}" y="{M + 232}" class="note" text-anchor="end">UN CUERPO</text>
<text x="{W - M}" y="{M + 276}" class="note" text-anchor="end">DOS LUCES</text>
<text x="{W - M}" y="{M + 344}" class="note" text-anchor="end">r = 300</text>
<text x="{W - M}" y="{M + 388}" class="note" text-anchor="end">d = 110 &#183; 70</text>

<!-- hero specimen -->
<g transform="translate({W/2 - 0} {GRID_TOP - 372}) scale(0.86)">
  <g transform="translate(-176 -176) scale(1.0)">
    <circle cx="176" cy="176" r="172" fill="none" stroke="{PIE_800}" stroke-width="1.4"/>
    <g clip-path="url(#hw)"><path d="{crescent(176, 176, 176 - 16.05, 176 - 60.77, 172)}" fill="{AMB}"/></g>
    <g clip-path="url(#hc)"><path d="{crescent(176, 176, 176 + 10.32, 176 + 38.99, 172)}" fill="{CIE}"/></g>
  </g>
</g>

<line x1="{M}" y1="{GRID_TOP - 92}" x2="{W - M}" y2="{GRID_TOP - 92}" stroke="{PIE_800}" stroke-width="1.6"/>
<text x="{M}" y="{GRID_TOP - 128}" class="note">DEMORA ANGULAR &#8594;</text>
<text x="{W - M}" y="{GRID_TOP - 128}" class="note" text-anchor="end">SEPARACI&#211;N &#8595;</text>

{''.join(ticks)}
{''.join(cells)}

<line x1="{M}" y1="{GRID_BOTTOM + 62}" x2="{W - M}" y2="{GRID_BOTTOM + 62}" stroke="{PIE_800}" stroke-width="1.6"/>
{''.join(band)}

<text x="{M}" y="{H - M - 96}" class="anchor">un cuerpo, dos luces</text>
<line x1="{M}" y1="{H - M - 56}" x2="{W - M}" y2="{H - M - 56}" stroke="{PIE_800}" stroke-width="1.6"/>
<text x="{M}" y="{H - M - 8}" class="note">TABLA DE ECLIPSES</text>
<text x="{W - M}" y="{H - M - 8}" class="note" text-anchor="end">c&#333;&#257;tl &#183; gemelo</text>
</svg>'''

open('/home/claude/brand/plate.svg', 'w').write(svg)
print('plate.svg written', W, 'x', H, ' grid bottom', GRID_BOTTOM, ' band', BAND_Y)

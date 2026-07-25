"""Cuate colour system — OKLCH ramps built from the three brand anchors."""
import math, json

# ---------- sRGB <-> OKLab ----------
def _srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def _lin_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055

def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) / 255 for i in (0, 2, 4))

def rgb_to_hex(rgb):
    return '#' + ''.join(f'{max(0,min(255,round(c*255))):02X}' for c in rgb)

def rgb_to_oklab(rgb):
    r, g, b = (_srgb_to_lin(c) for c in rgb)
    l = 0.4122214708*r + 0.5363325363*g + 0.0514459929*b
    m = 0.2119034982*r + 0.6806995451*g + 0.1073969566*b
    s = 0.0883024619*r + 0.2817188376*g + 0.6299787005*b
    l_, m_, s_ = l ** (1/3), m ** (1/3), s ** (1/3)
    return (0.2104542553*l_ + 0.7936177850*m_ - 0.0040720468*s_,
            1.9779984951*l_ - 2.4285922050*m_ + 0.4505937099*s_,
            0.0259040371*l_ + 0.7827717662*m_ - 0.8086757660*s_)

def oklab_to_rgb(lab):
    L, a, b = lab
    l_ = L + 0.3963377774*a + 0.2158037573*b
    m_ = L - 0.1055613458*a - 0.0638541728*b
    s_ = L - 0.0894841775*a - 1.2914855480*b
    l, m, s = l_**3, m_**3, s_**3
    r = +4.0767416621*l - 3.3077115913*m + 0.2309699292*s
    g = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
    bb = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
    return tuple(_lin_to_srgb(c) for c in (r, g, bb))

def oklch(L, C, H):
    h = math.radians(H)
    return (L, C * math.cos(h), C * math.sin(h))

def lab_to_lch(lab):
    L, a, b = lab
    return (L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360)

def in_gamut(rgb, eps=1e-4):
    return all(-eps <= c <= 1 + eps for c in rgb)

def clamp_chroma(L, C, H):
    """Binary-search the largest in-gamut chroma <= C."""
    if in_gamut(oklab_to_rgb(oklch(L, C, H))):
        return C
    lo, hi = 0.0, C
    for _ in range(40):
        mid = (lo + hi) / 2
        if in_gamut(oklab_to_rgb(oklch(L, mid, H))):
            lo = mid
        else:
            hi = mid
    return lo

def lch_hex(L, C, H):
    return rgb_to_hex(oklab_to_rgb(oklch(L, clamp_chroma(L, C, H), H)))

# ---------- WCAG ----------
def rel_lum(rgb):
    r, g, b = (_srgb_to_lin(c) for c in rgb)
    return 0.2126*r + 0.7152*g + 0.0722*b

def contrast(h1, h2):
    a, b = rel_lum(hex_to_rgb(h1)), rel_lum(hex_to_rgb(h2))
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)

# ---------- anchors, pipetted from the original app icon ----------
ANCHORS = {'ambar': '#F9A211', 'cielo': '#5C7A96', 'obsidiana': '#08070C'}

for name, hx in ANCHORS.items():
    L, C, H = lab_to_lch(rgb_to_oklab(hex_to_rgb(hx)))
    print(f'{name:10s} {hx}  L={L:.4f} C={C:.4f} H={H:.2f}')

AMBAR_H = lab_to_lch(rgb_to_oklab(hex_to_rgb(ANCHORS['ambar'])))[2]
CIELO_H = lab_to_lch(rgb_to_oklab(hex_to_rgb(ANCHORS['cielo'])))[2]
NEUTRAL_H = lab_to_lch(rgb_to_oklab(hex_to_rgb('#151A21')))[2]

# Each ramp gets its own lightness ladder, built so that step 500 *is* the anchor
# colour. Amber is intrinsically light and slate is intrinsically dark; forcing both
# onto one ladder would mean neither brand colour appears in its own scale.
STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]

def ramp(hue, peak_chroma, chroma_curve, l_ladder):
    return {s: lch_hex(L, peak_chroma * k, hue)
            for s, L, k in zip(STEPS, l_ladder, chroma_curve)}

CURVE_ACCENT = [0.14, 0.28, 0.50, 0.72, 0.90, 1.00, 0.99, 0.90, 0.76, 0.58, 0.42]
CURVE_COOL   = [0.13, 0.25, 0.43, 0.61, 0.82, 1.00, 0.99, 0.90, 0.76, 0.58, 0.43]
CURVE_NEUTRAL= [0.30, 0.42, 0.50, 0.55, 0.58, 0.60, 0.62, 0.66, 0.72, 0.80, 0.90]

L_AMBAR  = [0.978, 0.948, 0.902, 0.856, 0.820, 0.7806, 0.700, 0.600, 0.482, 0.356, 0.258]
L_CIELO  = [0.972, 0.936, 0.874, 0.796, 0.684, 0.5672, 0.492, 0.412, 0.334, 0.254, 0.190]
L_PIEDRA = [0.985, 0.955, 0.900, 0.830, 0.740, 0.6400, 0.540, 0.430, 0.330, 0.235, 0.160]

AMBAR = ramp(AMBAR_H, 0.1657, CURVE_ACCENT, L_AMBAR)
CIELO = ramp(CIELO_H, 0.0556, CURVE_COOL,   L_CIELO)
# neutrals carry a whisper of the amber hue so greys never read blue-cold
PIEDRA = ramp(AMBAR_H, 0.016, CURVE_NEUTRAL, L_PIEDRA)

print()
for nm, r in (('ambar', AMBAR), ('cielo', CIELO), ('piedra', PIEDRA)):
    print(nm.ljust(7), ' '.join(f'{s}:{r[s]}' for s in STEPS))

# obsidiana is darker than piedra-950 on purpose: it is the page, not a surface
OBSIDIANA = '#08070C'
CAL = '#FEFCF2'

print(f'\nanchor check: ambar-500 {AMBAR[500]} (want #F9A211), '
      f'cielo-500 {CIELO[500]} (want #5C7A96)')

# Status hues, spaced far enough from the 70 degree brand amber to stay distinct.
VERDE = ramp(148, 0.115, CURVE_ACCENT,
             [0.972, 0.936, 0.874, 0.800, 0.710, 0.620, 0.545, 0.462, 0.376, 0.286, 0.212])
ROJO  = ramp(26,  0.155, CURVE_ACCENT,
             [0.972, 0.936, 0.876, 0.808, 0.726, 0.638, 0.560, 0.474, 0.386, 0.294, 0.218])

# ---------- semantic tokens ----------
# `accent` is the FILL colour and stays bright amber in both modes — that is what the
# brand looks like. `accent-ink` is amber used AS TEXT, and it has to darken on light
# grounds to clear 4.5:1. The codebase already carries this distinction as `accentInk`.
DARK = {
    'bg':                 OBSIDIANA,
    'surface':            PIEDRA[950],
    'surface-raised':     PIEDRA[900],
    'border':             PIEDRA[800],   # hairlines, decorative
    'border-interactive': PIEDRA[600],   # inputs, control outlines — needs 3:1
    'text':               CAL,
    'text-secondary':     PIEDRA[300],
    'text-muted':         PIEDRA[500],
    'accent':             AMBAR[500],
    'accent-hover':       AMBAR[400],
    'accent-pressed':     AMBAR[600],
    'accent-quiet':       AMBAR[950],
    'accent-ink':         AMBAR[500],
    'on-accent':          OBSIDIANA,
    'twin':               CIELO[400],
    'twin-quiet':         CIELO[950],
    'focus':              AMBAR[400],
    'success':            VERDE[400],
    'danger':             ROJO[400],
}
LIGHT = {
    'bg':                 CAL,
    'surface':            PIEDRA[50],
    'surface-raised':     '#FFFFFF',
    'border':             PIEDRA[200],
    'border-interactive': PIEDRA[500],
    'text':               PIEDRA[950],
    'text-secondary':     PIEDRA[700],
    'text-muted':         PIEDRA[600],
    'accent':             AMBAR[500],
    'accent-hover':       AMBAR[400],
    'accent-pressed':     AMBAR[600],
    'accent-quiet':       AMBAR[100],
    'accent-ink':         AMBAR[800],
    'on-accent':          PIEDRA[950],
    'twin':               CIELO[700],
    'twin-quiet':         CIELO[100],
    'focus':              AMBAR[700],
    'success':            VERDE[700],
    'danger':             ROJO[700],
}

print('\nContrast checks (WCAG 2.1)')
def check(label, fg, bg, need=4.5):
    c = contrast(fg, bg)
    grade = 'AAA' if c >= 7 else 'AA' if c >= 4.5 else 'AA-large' if c >= 3 else 'FAIL'
    flag = '' if c >= need else '   <-- below target'
    print(f'  {label:34s} {fg} on {bg}  {c:5.2f}  {grade}{flag}')
    return c

for mode, T in (('dark', DARK), ('light', LIGHT)):
    print(f'-- {mode}')
    check('text', T['text'], T['bg'], 7)
    check('text-secondary', T['text-secondary'], T['bg'], 4.5)
    check('text-muted', T['text-muted'], T['bg'], 4.5)
    check('accent-ink as text', T['accent-ink'], T['bg'], 4.5)
    check('twin as text', T['twin'], T['bg'], 4.5)
    check('on-accent over accent', T['on-accent'], T['accent'], 4.5)
    check('success', T['success'], T['bg'], 4.5)
    check('danger', T['danger'], T['bg'], 4.5)
    check('border-interactive (3:1)', T['border-interactive'], T['bg'], 3)
    check('focus ring (3:1)', T['focus'], T['bg'], 3)

json.dump({'ramps': {'ambar': AMBAR, 'cielo': CIELO, 'piedra': PIEDRA,
                     'verde': VERDE, 'rojo': ROJO},
           'anchors': {'obsidiana': OBSIDIANA, 'cal': CAL},
           'semantic': {'dark': DARK, 'light': LIGHT}},
          open('/home/claude/brand/tokens.json', 'w'), indent=2)
print('\nwrote tokens.json')

# ---------- exporters ----------
def css_block(T, sel):
    lines = [f'{sel} {{']
    for k, v in T.items():
        lines.append(f'  --cuate-{k}: {v};')
    lines.append('}')
    return '\n'.join(lines)

ramp_css = ['/* Cuate — colour ramps. Generated by design/brand/color.py. Do not hand-edit. */',
            ':root {']
for nm, r in (('ambar', AMBAR), ('cielo', CIELO), ('piedra', PIEDRA),
              ('verde', VERDE), ('rojo', ROJO)):
    for s in STEPS:
        ramp_css.append(f'  --{nm}-{s}: {r[s]};')
ramp_css += [f'  --obsidiana: {OBSIDIANA};', f'  --cal: {CAL};', '}', '']
css = '\n'.join(ramp_css) + '\n' + css_block(DARK, ':root, [data-theme="dark"]') \
      + '\n\n' + css_block(LIGHT, '[data-theme="light"]') + '\n'
open('tokens.css', 'w').write(css)

def swift_color(hexv):
    return f'Color(hex: 0x{hexv.lstrip("#")})'

sw = ['// Cuate — brand tokens. Generated by design/brand/color.py. Do not hand-edit.',
      '// The eight in-app themes still paint the interface; these paint the brand.',
      'import SwiftUI', '', 'enum Brand {', '    enum Ramp {']
for nm, r in (('ambar', AMBAR), ('cielo', CIELO), ('piedra', PIEDRA),
              ('verde', VERDE), ('rojo', ROJO)):
    sw.append(f'        static let {nm}: [Int: Color] = [')
    sw.append('            ' + ', '.join(f'{s}: {swift_color(r[s])}' for s in STEPS))
    sw.append('        ]')
sw.append('    }')
sw.append('')
sw.append('    struct Tokens {')
keys = list(DARK.keys())
for k in keys:
    sw.append(f'        let {k.replace("-", "_")}: Color')
sw.append('    }')
for mode, T in (('dark', DARK), ('light', LIGHT)):
    sw.append('')
    sw.append(f'    static let {mode} = Tokens(')
    sw.append(',\n'.join(f'        {k.replace("-", "_")}: {swift_color(T[k])}' for k in keys))
    sw.append('    )')
sw.append('}')
open('BrandTokens.swift', 'w').write('\n'.join(sw) + '\n')
print('wrote tokens.css, BrandTokens.swift')

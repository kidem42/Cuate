"""Regenerate the Cuate design-system sheet from tokens.json + the mark SVGs."""
import json, re, io

T = json.load(open('/home/claude/brand/tokens.json'))
R, SEM = T['ramps'], T['semantic']
STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
ANCHOR = {'ambar': 500, 'cielo': 500}

def contrast_pair(fg, bg):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
    def lum(h):
        h = h.lstrip('#')
        r, g, b = (int(h[i:i+2], 16) for i in (0, 2, 4))
        return .2126*lin(r) + .7152*lin(g) + .0722*lin(b)
    a, b = lum(fg), lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + .05) / (lo + .05)

def inner(path):
    s = io.open(path, encoding='utf-8').read()
    s = re.sub(r'\swidth="\d+"\s*height="\d+"', '', s, count=1)
    return s

def uniq(svg, tag):
    """Namespace gradient / clip ids so several marks can share one page."""
    for i in ('w', 'c', 'kw', 'kc'):
        svg = svg.replace(f'id="{i}"', f'id="{i}{tag}"').replace(f'url(#{i})', f'url(#{i}{tag})')
    return svg

VARIANTS = [
    ('eclipse',    'Eclipse',     'Accepted',   'Two lights on one body. It holds the twin idea, survives at small sizes, and inherits the previous sphere.'),
    ('fase',       'Fase',        'Reserve',   'A single crescent. It reads at the smallest size of them all — hence the menu-bar glyph. But the twin disappears.'),
    ('terminador', 'Terminador',  'Rejected', 'The line of day and night. Strong and terse, but it loses the light: a flat fill instead of illumination.'),
    ('sicigia',    'Sicigia',     'Rejected', 'Two bodies in a row. The most expressive and the least usable: it is wide and never fits the icon square.'),
    ('conjuncion', 'Conjuncion',  'Rejected', 'The intersection glows. It reads as a Venn diagram — that is, like every other startup.'),
    ('anillo',     'Anillo',      'Rejected', 'Full coverage, light around the whole edge. At small sizes it is a loading indicator.'),
]

def swatch_row(name, ramp):
    cells = ''
    for s in STEPS:
        hx = ramp[str(s)] if isinstance(list(ramp.keys())[0], str) else ramp[s]
        star = ' <b>·</b>' if ANCHOR.get(name) == s else ''
        cells += (f'<div class="st"><div class="ch" style="background:{hx}"></div>'
                  f'<div class="sn">{s}{star}</div><div class="sh">{hx}</div></div>')
    return f'<div class="ramp"><div class="rn">{name}</div><div class="row">{cells}</div></div>'

def token_table(mode):
    S = SEM[mode]
    bg = S['bg']
    rows = ''
    for k, v in S.items():
        if k in ('bg',) or k.endswith(('-quiet', 'surface', 'surface-raised')) \
                or k in ('surface', 'surface-raised', 'border'):
            note = ''
        elif k.startswith(('text', 'accent-ink', 'twin', 'success', 'danger')) and not k.endswith('-quiet'):
            c = contrast_pair(v, bg)
            note = f'{c:.2f}:1 ' + ('AAA' if c >= 7 else 'AA' if c >= 4.5 else 'AA-lg' if c >= 3 else 'FAIL')
        elif k in ('border-interactive', 'focus'):
            c = contrast_pair(v, bg)
            note = f'{c:.2f}:1 ' + ('ok' if c >= 3 else 'FAIL')
        elif k == 'on-accent':
            c = contrast_pair(v, S['accent'])
            note = f'{c:.2f}:1 over accent'
        else:
            note = ''
        rows += (f'<tr><td class="mono">{k}</td>'
                 f'<td><span class="dot" style="background:{v}"></span><span class="mono dim">{v}</span></td>'
                 f'<td class="mono dim">{note}</td></tr>')
    return rows

marks_html = ''
for slug, title, status, note in VARIANTS:
    svg = uniq(inner(f'/home/claude/brand/marks/{slug}.svg'), slug)
    cls = 'ok' if status == 'Accepted' else ('alt' if status == 'Reserve' else 'no')
    marks_html += (f'<figure class="mk"><div class="mkart">{svg}</div>'
                   f'<figcaption><div class="mkh"><b>{title}</b>'
                   f'<span class="badge {cls}">{status}</span></div>'
                   f'<p>{note}</p></figcaption></figure>')

hero = uniq(inner('/home/claude/brand/cuate-icon.svg'), 'hero')

HTML = f'''<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cuate — Design System</title>
<style>
:root{{--bg:{SEM['dark']['bg']};--sf:{SEM['dark']['surface']};--sfr:{SEM['dark']['surface-raised']};
--bd:{SEM['dark']['border']};--tx:{SEM['dark']['text']};--t2:{SEM['dark']['text-secondary']};
--t3:{SEM['dark']['text-muted']};--ac:{SEM['dark']['accent']};--tw:{SEM['dark']['twin']}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--tx);
font:15px/1.62 ui-sans-serif,-apple-system,"SF Pro Text",Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased}}
.wrap{{max-width:1080px;margin:0 auto;padding:56px 28px 110px}}
h1{{font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:var(--t3);font-weight:600;margin:0 0 46px}}
h2{{font-size:12px;letter-spacing:.16em;text-transform:uppercase;color:var(--t3);font-weight:600;
margin:0 0 22px;padding-bottom:12px;border-bottom:1px solid var(--bd)}}
section{{margin-bottom:74px}}
p{{margin:0 0 14px;max-width:66ch;color:var(--t2)}}
.mono{{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:12.5px;letter-spacing:.02em}}
.dim{{color:var(--t3)}}
.hero{{display:flex;gap:44px;align-items:center;flex-wrap:wrap;margin-bottom:70px}}
.hero svg{{width:172px;height:172px;display:block}}
.nm{{font-size:60px;font-weight:600;letter-spacing:-.02em;line-height:1;color:var(--tx)}}
.say{{color:var(--ac);margin-top:12px;font-size:14px;letter-spacing:.04em}}
.tg{{color:var(--t3);margin-top:12px;max-width:34ch}}
/* marks */
.mks{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:22px}}
.mk{{margin:0;background:var(--sf);border:1px solid var(--bd);border-radius:14px;overflow:hidden}}
.mkart{{background:var(--bg);padding:26px;display:flex;justify-content:center}}
.mkart svg{{width:150px;height:150px;display:block}}
.mk figcaption{{padding:16px 18px 20px}}
.mkh{{display:flex;align-items:center;gap:10px;margin-bottom:7px}}
.mkh b{{font-size:15px;color:var(--tx)}}
.badge{{font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;padding:2px 8px;border-radius:20px;border:1px solid}}
.badge.ok{{color:{SEM['dark']['accent']};border-color:{SEM['dark']['accent-pressed']};background:{SEM['dark']['accent-quiet']}}}
.badge.alt{{color:{SEM['dark']['twin']};border-color:{SEM['dark']['twin']};background:{SEM['dark']['twin-quiet']}}}
.badge.no{{color:var(--t3);border-color:var(--bd)}}
.mk p{{margin:0;font-size:13.5px;color:var(--t3);line-height:1.55}}
/* ramps */
.ramp{{margin-bottom:20px}}
.rn{{font-family:ui-monospace,Menlo,monospace;font-size:12px;letter-spacing:.14em;
text-transform:uppercase;color:var(--t3);margin-bottom:8px}}
.row{{display:grid;grid-template-columns:repeat(11,1fr);gap:5px}}
.st .ch{{height:52px;border-radius:6px;border:1px solid rgba(255,255,255,.06)}}
.sn{{font-family:ui-monospace,Menlo,monospace;font-size:10.5px;color:var(--t2);margin-top:5px}}
.sn b{{color:{SEM['dark']['accent']}}}
.sh{{font-family:ui-monospace,Menlo,monospace;font-size:9.5px;color:var(--t3)}}
/* tokens */
.cols{{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:26px}}
table{{width:100%;border-collapse:collapse}}
td,th{{text-align:left;padding:6px 8px;border-bottom:1px solid var(--bd);font-size:12.5px}}
th{{color:var(--t3);font-size:11px;letter-spacing:.12em;text-transform:uppercase}}
.dot{{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:7px;
vertical-align:-1px;border:1px solid rgba(255,255,255,.14)}}
.lightcard{{background:{SEM['light']['bg']};border-radius:14px;padding:18px;border:1px solid {SEM['light']['border']}}}
.lightcard th{{color:{SEM['light']['text-muted']}}}
.lightcard td{{color:{SEM['light']['text']};border-color:{SEM['light']['border']}}}
.lightcard .dim{{color:{SEM['light']['text-secondary']}}}
.lightcard h3{{color:{SEM['light']['text']}}}
h3{{font-size:13px;letter-spacing:.1em;text-transform:uppercase;color:var(--t3);margin:0 0 12px;font-weight:600}}
/* menu bar */
.bar{{display:flex;align-items:center;gap:16px;padding:0 14px;height:26px;border-radius:7px;font-size:12px}}
.bar.l{{background:#F2F2F5;color:#2A2A2E;border:1px solid #DDDDE2}}
.bar.d{{background:#2C2C30;color:#F0F0F4;border:1px solid #3A3A40}}
.cap{{font-size:12px;color:var(--t3);margin:16px 0 6px}}
</style></head><body><div class="wrap">

<h1>Cuate · Design System</h1>

<div class="hero">{hero}
<div><div class="nm">Cuate</div>
<div class="say">KWAH-teh · from Nahuatl <i>cōātl</i> — "twin"</div>
<div class="tg">One disc, two lights. Warm from below, cold from above.</div></div></div>

<section><h2>The mark — an exploration</h2>
<p>Six variants from a single geometric grammar: two discs of equal radius at different phases.
Only the offset and the angle change — everything else follows. The <b>Lámina I</b> plate shows
72 phases of the same grid; the accepted mark is marked on it with an amber ring.</p>
<div class="mks">{marks_html}</div>
<p style="margin-top:22px">The accepted variant is trimmed by 26 units at the poles: without that the crescents
close into a ring and the mark reads as a loading indicator rather than two sources of light.</p>
</section>

<section><h2>Ramps</h2>
<p>Built in OKLCH — a perceptually uniform space, so the steps look
even rather than merely being counted as even. Each ramp has its own lightness
ladder so the brand color lands exactly on step <b>500</b>: ámbar is light by nature,
cielo is dark, and a shared ladder would distort both. Chroma is clamped by binary search
against the sRGB boundary — nothing sits out of gamut.</p>
{swatch_row('ambar', R['ambar'])}
{swatch_row('cielo', R['cielo'])}
{swatch_row('piedra', R['piedra'])}
{swatch_row('verde', R['verde'])}
{swatch_row('rojo', R['rojo'])}
<p style="margin-top:16px">The neutral <b>piedra</b> is built on the same hue as ámbar,
at chroma 0.016 — the grey never drifts cold. <b>Verde</b> and <b>rojo</b> are pushed to
148° and 26° so they don't argue with the accent at 70°.</p>
</section>

<section><h2>Semantic tokens</h2>
<p><b>accent</b> is a fill color; it stays bright ámbar in both themes, because that is what
the brand looks like. <b>accent-ink</b> is the same ámbar in the role of text, and on a light background it
must darken to 4.5:1. In <code>AppTheme.swift</code> that distinction already lives as
<code>accentInk</code>.</p>
<div class="cols">
<div><h3>Dark</h3><table><tr><th>Token</th><th>Value</th><th>Contrast</th></tr>
{token_table('dark')}</table></div>
<div class="lightcard"><h3>Light</h3><table><tr><th>Token</th><th>Value</th><th>Contrast</th></tr>
{token_table('light')}</table></div>
</div>
</section>

<section><h2>The menu bar</h2>
<p>The glyph is <b>deliberately not the mark</b>. What works as a logo at 200&nbsp;px falls apart
at 18&nbsp;pt. All they share is the grammar: one body, two identical halves.</p>
<p>The disc is cut on the diagonal, and the halves have slid past each other <i>along</i> the cut.
Two silhouettes were rejected after a check at actual size: a <b>crescent</b> is the macOS
"Do Not Disturb" glyph, and a <b>circle with a diagonal slot</b> reads as a prohibition sign.
Sliding along the cut breaks the round silhouette, and both readings disappear.</p>
<p>State through geometry only: while working, the halves close and the body is whole again.</p>
<div class="cap">Light · idle and active</div>
<div class="bar l"><span>Finder</span><span style="opacity:.5">File</span><span style="flex:1"></span>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#2A2A2E" d="M 16.545 4.120 A 7.35 7.35 0 0 1 4.961 13.170 Z M 13.039 4.830 A 7.35 7.35 0 0 0 1.455 13.880 Z"/></svg>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#2A2A2E" d="M 14.792 4.475 A 7.35 7.35 0 0 1 3.208 13.525 Z M 14.792 4.475 A 7.35 7.35 0 0 0 3.208 13.525 Z"/></svg>
<span>13:24</span></div>
<div class="cap">Dark</div>
<div class="bar d"><span>Finder</span><span style="opacity:.5">File</span><span style="flex:1"></span>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#F0F0F4" d="M 16.545 4.120 A 7.35 7.35 0 0 1 4.961 13.170 Z M 13.039 4.830 A 7.35 7.35 0 0 0 1.455 13.880 Z"/></svg>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#F0F0F4" d="M 14.792 4.475 A 7.35 7.35 0 0 1 3.208 13.525 Z M 14.792 4.475 A 7.35 7.35 0 0 0 3.208 13.525 Z"/></svg>
<span>13:24</span></div>
</section>

<section><h2>Files</h2>
<table class="mono">
<tr><td>design/brand/PHILOSOPHY.md</td><td class="dim">the visual philosophy; everything is derived from it</td></tr>
<tr><td>design/brand/color.py</td><td class="dim">the ramp and token generator, with WCAG checking</td></tr>
<tr><td>design/brand/marks.py</td><td class="dim">the mark generator from a single grammar</td></tr>
<tr><td>design/brand/plate.py</td><td class="dim">the "Fases del gemelo" plate</td></tr>
<tr><td>design/brand/tokens.css</td><td class="dim">CSS variables — for the site</td></tr>
<tr><td>design/brand/BrandTokens.swift</td><td class="dim">tokens for the app</td></tr>
<tr><td>design/brand/tokens.json</td><td class="dim">the source for any other platform</td></tr>
<tr><td>design/brand/cuate-lamina-I.pdf</td><td class="dim">the print plate, A4 300 dpi</td></tr>
</table>
<p style="margin-top:18px" class="dim">The raster is always regenerated from
<code>color.py</code> and <code>marks.py</code>. Never edit by hand — otherwise the ramps
drift out of sync with the contrast checks.</p>
</section>

</div></body></html>'''

io.open('/home/claude/brand/design-system.html', 'w', encoding='utf-8').write(HTML)
print('design-system.html written')

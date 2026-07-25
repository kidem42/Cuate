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
    ('eclipse',    'Eclipse',     'Принят',   'Два света на одном теле. Держит идею близнеца, выживает в размере, наследует прежнюю сферу.'),
    ('fase',       'Fase',        'Резерв',   'Один серп. Читается меньше всех остальных — отсюда глиф строки меню. Но близнец пропадает.'),
    ('terminador', 'Terminador',  'Отклонён', 'Линия дня и ночи. Сильно и лаконично, но теряет свет: плоская заливка вместо подсветки.'),
    ('sicigia',    'Sicigia',     'Отклонён', 'Два тела в ряд. Самое выразительное и самое непригодное: широкое, в квадрат иконки не садится.'),
    ('conjuncion', 'Conjuncion',  'Отклонён', 'Светится пересечение. Читается как диаграмма Венна — то есть как любой другой стартап.'),
    ('anillo',     'Anillo',      'Отклонён', 'Полное покрытие, свет по всему краю. На малых размерах — индикатор загрузки.'),
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
            note = f'{c:.2f}:1 над accent'
        else:
            note = ''
        rows += (f'<tr><td class="mono">{k}</td>'
                 f'<td><span class="dot" style="background:{v}"></span><span class="mono dim">{v}</span></td>'
                 f'<td class="mono dim">{note}</td></tr>')
    return rows

marks_html = ''
for slug, title, status, note in VARIANTS:
    svg = uniq(inner(f'/home/claude/brand/marks/{slug}.svg'), slug)
    cls = 'ok' if status == 'Принят' else ('alt' if status == 'Резерв' else 'no')
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
<div class="say">KWAH-teh · от науатль <i>cōātl</i> — «близнец»</div>
<div class="tg">Один диск, две подсветки. Тёплая снизу, холодная сверху.</div></div></div>

<section><h2>Марка — исследование</h2>
<p>Шесть вариантов из одной геометрической грамматики: два диска равного радиуса на разной фазе.
Меняются только смещение и угол — всё остальное следствие. Лист <b>Láminа I</b> показывает
72 фазы этой же сетки; принятая марка отмечена на нём янтарным кольцом.</p>
<div class="mks">{marks_html}</div>
<p style="margin-top:22px">Принятый вариант обрезан у полюсов на 26 единиц: без этого серпы
смыкаются в кольцо и марка читается как индикатор загрузки, а не как два источника света.</p>
</section>

<section><h2>Шкалы</h2>
<p>Построены в OKLCH — перцептивно равномерном пространстве, поэтому шаги выглядят
равномерными, а не только считаются такими. Каждая шкала имеет собственную лестницу
светлоты, чтобы фирменный цвет попадал ровно на ступень <b>500</b>: янтарь по природе
светлый, сьело тёмный, общая лестница исказила бы оба. Хрома зажимается бинарным поиском
по границе sRGB — вне гаммы ничего нет.</p>
{swatch_row('ambar', R['ambar'])}
{swatch_row('cielo', R['cielo'])}
{swatch_row('piedra', R['piedra'])}
{swatch_row('verde', R['verde'])}
{swatch_row('rojo', R['rojo'])}
<p style="margin-top:16px">Нейтральная <b>piedra</b> построена на том же тоне, что и янтарь,
с хромой 0.016 — серый никогда не уходит в холод. <b>Verde</b> и <b>rojo</b> отнесены на
148° и 26°, чтобы не спорить с акцентом на 70°.</p>
</section>

<section><h2>Семантические токены</h2>
<p><b>accent</b> — цвет заливки, он остаётся ярким янтарём в обеих темах, потому что так
выглядит бренд. <b>accent-ink</b> — тот же янтарь в роли текста, и на светлом фоне он
обязан темнеть до 4.5:1. В <code>AppTheme.swift</code> это различие уже живёт как
<code>accentInk</code>.</p>
<div class="cols">
<div><h3>Тёмная</h3><table><tr><th>Токен</th><th>Значение</th><th>Контраст</th></tr>
{token_table('dark')}</table></div>
<div class="lightcard"><h3>Светлая</h3><table><tr><th>Токен</th><th>Значение</th><th>Контраст</th></tr>
{token_table('light')}</table></div>
</div>
</section>

<section><h2>Строка меню</h2>
<p>Глиф — <b>намеренно не марка</b>. То, что работает логотипом на 200&nbsp;px, разваливается
на 18&nbsp;pt. Общая у них только грамматика: одно тело, две одинаковые половины.</p>
<p>Диск разрезан по диагонали, половины соскользнули друг с другом <i>вдоль</i> разреза.
Два силуэта отброшены после проверки в натуральную величину: <b>полумесяц</b> — это значок
«Не беспокоить» в macOS, а <b>круг с диагональной прорезью</b> читается как знак запрета.
Сдвиг вдоль разреза ломает круглый силуэт, и оба прочтения исчезают.</p>
<p>Состояние — только геометрией: в работе половины смыкаются, тело снова целое.</p>
<div class="cap">Светлая · покой и активность</div>
<div class="bar l"><span>Finder</span><span style="opacity:.5">Файл</span><span style="flex:1"></span>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#2A2A2E" d="M 16.545 4.120 A 7.35 7.35 0 0 1 4.961 13.170 Z M 13.039 4.830 A 7.35 7.35 0 0 0 1.455 13.880 Z"/></svg>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#2A2A2E" d="M 14.792 4.475 A 7.35 7.35 0 0 1 3.208 13.525 Z M 14.792 4.475 A 7.35 7.35 0 0 0 3.208 13.525 Z"/></svg>
<span>13:24</span></div>
<div class="cap">Тёмная</div>
<div class="bar d"><span>Finder</span><span style="opacity:.5">Файл</span><span style="flex:1"></span>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#F0F0F4" d="M 16.545 4.120 A 7.35 7.35 0 0 1 4.961 13.170 Z M 13.039 4.830 A 7.35 7.35 0 0 0 1.455 13.880 Z"/></svg>
<svg width="18" height="18" viewBox="0 0 18 18"><path fill="#F0F0F4" d="M 14.792 4.475 A 7.35 7.35 0 0 1 3.208 13.525 Z M 14.792 4.475 A 7.35 7.35 0 0 0 3.208 13.525 Z"/></svg>
<span>13:24</span></div>
</section>

<section><h2>Файлы</h2>
<table class="mono">
<tr><td>design/brand/PHILOSOPHY.md</td><td class="dim">визуальная философия, из неё всё выведено</td></tr>
<tr><td>design/brand/color.py</td><td class="dim">генератор шкал и токенов, с проверкой WCAG</td></tr>
<tr><td>design/brand/marks.py</td><td class="dim">генератор марок из одной грамматики</td></tr>
<tr><td>design/brand/plate.py</td><td class="dim">лист «Fases del gemelo»</td></tr>
<tr><td>design/brand/tokens.css</td><td class="dim">переменные CSS — для сайта</td></tr>
<tr><td>design/brand/BrandTokens.swift</td><td class="dim">токены для приложения</td></tr>
<tr><td>design/brand/tokens.json</td><td class="dim">источник для любых других платформ</td></tr>
<tr><td>design/brand/cuate-lamina-I.pdf</td><td class="dim">печатный лист, A4 300 dpi</td></tr>
</table>
<p style="margin-top:18px" class="dim">Растр всегда пересобирается из
<code>color.py</code> и <code>marks.py</code>. Руками не править — иначе шкалы
разъедутся с проверкой контраста.</p>
</section>

</div></body></html>'''

io.open('/home/claude/brand/design-system.html', 'w', encoding='utf-8').write(HTML)
print('design-system.html written')

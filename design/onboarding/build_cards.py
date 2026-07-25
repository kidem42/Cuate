#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Макет нового онбординг-тура Cuate: 5 анимированных сцен по пунктам
меню статус-бара + окно тура целиком.

    python3 design/onboarding/build_cards.py
    open design/onboarding/dist/preview.html

Собирает самодостаточные HTML-карточки в dist/ (формат Claude Design:
первая строка — маркер @dsCard) плюс локальный стенд preview.html.

Значки настоящие: SF Symbols отрисованы AppKit'ом в PNG (dump_symbols.swift →
symbols.json) и подключаются CSS-маской, поэтому красятся currentColor ровно
как template-изображения в приложении. Логотипы провайдеров берутся как есть
из Cuate/Assets.xcassets/Provider-*.imageset/*.svg.

Модель анимации, которую переносить в SwiftUI: ОДИН такт на сцену, у каждого
слоя своё окно внутри фазы 0…1 (проценты в @keyframes). В приложении сцена
играет один проход и замирает на кадре-результате; здесь зациклена, чтобы её
можно было разглядывать, и её можно скраббить по шкале под сценой.
"""

import json, pathlib, re

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent                      # корень репозитория
ASSETS = REPO / "Cuate" / "Assets.xcassets"
OUT = HERE / "dist"

SYMBOLS = json.loads((HERE / "symbols.json").read_text())


def sf(name, size=13, extra=""):
    """SF Symbol как маска. name — как в Image(systemName:)."""
    key = name.replace(".", "-")
    assert key in SYMBOLS, "нет символа " + name
    return ('<i class="sf" style="--u:var(--sf-%s);width:%spx;height:%spx;%s"></i>'
            % (key, size, size, extra))


def symbol_defs(body):
    """Только те символы, что реально встретились в карточке."""
    used = sorted(set(re.findall(r"var\(--sf-([a-z0-9-]+)\)", body)))
    return ":root{" + "".join(
        '--sf-%s:url(data:image/png;base64,%s);' % (k, SYMBOLS[k]) for k in used) + "}"


_LOGO = {}


def logo(provider, size=12, extra=""):
    if provider not in _LOGO:
        svg = (ASSETS / ("Provider-%s.imageset" % provider) / ("%s.svg" % provider)).read_text()
        svg = svg.replace("\n", "").strip()
        svg = re.sub(r"<title>.*?</title>", "", svg)
        svg = svg.replace('fill="#000000"', 'fill="currentColor"')
        svg = re.sub(r'\s(width|height)="[^"]*"', "", svg)
        if 'fill="currentColor"' not in svg:
            svg = svg.replace("<svg ", '<svg fill="currentColor" ', 1)
        _LOGO[provider] = svg
    return _LOGO[provider].replace(
        "<svg ", '<svg class="lg" style="width:%spx;height:%spx;%s" ' % (size, size, extra), 1)


# ============================================================ ОБЩЕЕ
CORE = """
*{margin:0;padding:0;box-sizing:border-box;-webkit-font-smoothing:antialiased}
:root{
  --text:#1D1D1F; --sec:rgba(60,60,67,.62); --sec2:rgba(60,60,67,.35); --blue:#0071E3;
  --glass:rgba(255,255,255,.70); --glassline:rgba(255,255,255,.6);
  --field:rgba(0,0,0,.055); --win:#FBFBFD; --sep:rgba(0,0,0,.10); --bg:#F1F1F4;
  --mono:ui-monospace,'SF Mono',SFMono-Regular,Menlo,monospace;
}
body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Arial,sans-serif;
  color:var(--text); background:var(--bg)}
.sf{display:inline-block; background:currentColor; flex:none;
  -webkit-mask:var(--u) no-repeat center/contain; mask:var(--u) no-repeat center/contain}
.lg{display:inline-block; flex:none}

.stage{position:relative; width:560px; height:300px; overflow:hidden; --delay:0ms; --play:running}
.scene{position:absolute; inset:0; display:none}
.scene.is-on{display:block}
.wall{position:absolute; inset:0;
  background:
    radial-gradient(90% 70% at 22% 6%, rgba(126,196,224,.42), transparent 60%),
    radial-gradient(70% 80% at 88% 94%, rgba(26,74,116,.6), transparent 65%),
    linear-gradient(158deg,#1F3370 0%,#245E77 52%,#102E45 100%)}
.wall::after{content:""; position:absolute; inset:0; box-shadow:inset 0 0 90px rgba(0,0,0,.35)}

.menubar{position:absolute; top:0; left:0; right:0; height:24px; z-index:5; display:flex;
  align-items:center; gap:12px; padding:0 10px; font-size:10px; color:#fff;
  background:rgba(255,255,255,.14); backdrop-filter:blur(14px); -webkit-backdrop-filter:blur(14px);
  border-bottom:1px solid rgba(255,255,255,.07)}
.menubar .app{font-weight:700; font-size:10.5px}
.menubar .mi{opacity:.8}
.menubar .sp{flex:1}
.mb-icon{display:grid; place-items:center; width:19px; height:19px; border-radius:4px}

.hostwin{position:absolute; border-radius:9px; overflow:hidden; background:var(--win);
  box-shadow:0 20px 38px -14px rgba(0,0,0,.6); border:1px solid rgba(0,0,0,.18);
  display:flex; flex-direction:column}
.hw-bar{height:20px; display:flex; align-items:center; gap:5px; padding:0 8px;
  background:#EDEDF0; border-bottom:1px solid var(--sep); flex:none}
.hw-bar i{width:7px; height:7px; border-radius:50%; background:#DDD}
.hw-bar i.r{background:#FF5F57}.hw-bar i.y{background:#FEBC2E}.hw-bar i.g{background:#28C840}
.hw-bar b{margin-left:6px; font-size:8.5px; font-weight:500; color:var(--sec)}
.hw-body{padding:10px 11px; display:flex; flex-direction:column; gap:6px; flex:1; min-height:0}
.tl{height:4px; border-radius:3px; background:currentColor; opacity:.2}
.tl.b{height:6px; opacity:.4}

.panel{position:absolute; border-radius:14px; overflow:hidden; background:var(--glass);
  backdrop-filter:blur(26px) saturate(180%); -webkit-backdrop-filter:blur(26px) saturate(180%);
  border:1px solid var(--glassline); box-shadow:0 26px 50px -18px rgba(0,0,0,.62)}
.p-head{display:flex; align-items:center; gap:5px; padding:6px 9px 3px; font-size:9px; color:var(--sec)}
.p-head .sp{flex:1}
.p-head .grp{display:flex; align-items:center; gap:3.5px}
.thread{padding:4px 9px 7px; display:flex; flex-direction:column; gap:5px}
.row{display:flex; gap:5px; align-items:flex-start}
.row.user{justify-content:flex-end}
.bub{font-size:10px; line-height:1.45; padding:5px 8px; border-radius:12px; max-width:84%}
.row.user .bub{background:var(--blue); color:#fff; border-radius:12px 12px 4px 12px}
.row.bot .bub{background:rgba(0,0,0,.055); border-radius:12px 12px 12px 4px}
.avatar{color:var(--blue); margin-top:3px}
.ts{font-size:7px; color:var(--sec2); padding:1px 3px 0}
.composer{display:flex; align-items:center; gap:6px; padding:6px 8px 7px; border-top:1px solid var(--sep)}
.clip{color:var(--sec)}
.field{flex:1; height:22px; border-radius:7px; background:var(--field); display:flex; align-items:center;
  padding:0 8px; font-size:10px; position:relative; overflow:hidden}
.field .ph{color:var(--sec); position:absolute; left:8px}
.mic,.send{width:21px; height:21px; border-radius:50%; flex:none; display:grid; place-items:center}
.mic{border:1px dashed var(--blue); color:var(--blue)}
.send{background:var(--blue); color:#fff}

.status{display:flex; align-items:center; gap:5px; font-size:9px; color:var(--blue); padding:1px 2px}
.src{display:inline-flex; align-items:center; gap:3px; font-size:8px; color:var(--blue);
  background:rgba(0,113,227,.13); padding:2px 6px; border-radius:999px; margin-top:3px}

/* Печать: ширина от 0 до натуральной; натуральную меряет скрипт (scrollWidth),
   подбирать её в ch бессмысленно — шрифт пропорциональный. Ширина, а не клип:
   так строка раздвигается и каретка едет за текстом. */
.type{display:inline-block; overflow:hidden; white-space:nowrap; vertical-align:bottom; --w:0px; width:0}
.caret{display:inline-block; width:1px; height:10px; background:var(--text); vertical-align:-1px;
  animation:blink 1.05s steps(1) infinite; animation-delay:var(--delay,0ms); animation-play-state:var(--play,running)}
@keyframes blink{0%,50%{opacity:1}50.01%,100%{opacity:0}}

.keycap{position:absolute; left:0; right:0; margin:0 auto; width:max-content; bottom:13px; z-index:14;
  font-family:var(--mono); font-size:12px; font-weight:600; padding:5px 11px; border-radius:8px; color:#fff;
  background:rgba(18,20,26,.7); backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px);
  border:1px solid rgba(255,255,255,.22); box-shadow:0 6px 16px -6px rgba(0,0,0,.6)}

.an{animation-duration:var(--cycle); animation-timing-function:cubic-bezier(.24,.86,.3,1);
  animation-iteration-count:infinite; animation-fill-mode:both;
  animation-delay:var(--delay,0ms); animation-play-state:var(--play,running)}
.an.st{animation-timing-function:steps(26)}
/* «проезды» (шторка, лупа, рамка колонки) идут равномерно, без разгона */
.an.lin{animation-timing-function:linear}
.per{animation-iteration-count:infinite; animation-fill-mode:both; animation-timing-function:ease-in-out;
  animation-delay:calc(var(--delay,0ms) + var(--i,0) * -70ms); animation-play-state:var(--play,running)}
@keyframes dots{0%,100%{opacity:.28;transform:translateY(0)}50%{opacity:1;transform:translateY(-2px)}}
@keyframes shim{0%{opacity:.35}50%{opacity:1}100%{opacity:.35}}
"""


def menubar(app, hot=False):
    return """
  <div class="menubar">
    <span class="app">%s</span>
    <span class="mi">Файл</span><span class="mi">Правка</span><span class="mi">Вид</span>
    <span class="sp"></span>
    <span class="mb-icon%s">%s</span>%s%s<span>9:41</span>
  </div>""" % (app, ' hot" style="background:rgba(255,255,255,.28)' if hot else "",
               sf("brain.head.profile", 13), sf("wifi", 12, "opacity:.85;"),
               sf("battery.100", 15, "opacity:.85;"))


def head(provider="openai", provider_name="OpenAI", preset="Стандартный"):
    return """
    <div class="p-head">
      <span class="grp">%s %s %s</span><span class="sp"></span>
      <span class="grp">%s %s</span><span class="grp" style="margin-left:6px">%s</span>
    </div>""" % (logo(provider, 11), provider_name, sf("chevron.down", 6, "opacity:.6;"),
                 preset, sf("chevron.down", 6, "opacity:.6;"), sf("square.and.pencil", 11))


def composer(ph):
    return """
    <div class="composer">
      <span class="clip">%s</span>
      <div class="field"><span class="ph">%s</span></div>
      <span class="mic">%s</span><span class="send">%s</span>
    </div>""" % (sf("paperclip", 12), ph, sf("mic.fill", 10), sf("paperplane.fill", 10))


# ============================================================ 1 · ЧАТ
S1_CSS = """
.s1 .hostwin{left:22px; top:44px; width:266px; height:180px; color:var(--text)}
.s1 .panel{left:172px; top:64px; width:368px; z-index:10}
.s1 .stack{display:grid}
.s1 .stack>*{grid-area:1/1}
@keyframes c1glow{0%,3%{background:rgba(255,255,255,0)}7%,14%{background:rgba(255,255,255,.32)}21%,100%{background:rgba(255,255,255,0)}}
@keyframes c1key{0%,3%{opacity:0;transform:translateY(6px) scale(.95)}7%{opacity:1;transform:none}9%{transform:scale(.92)}12%{transform:none}17%,100%{opacity:0}}
@keyframes c1panel{0%,9%{opacity:0;transform:translateY(9px) scale(.965);filter:blur(7px)}17%,93%{opacity:1;transform:none;filter:blur(0)}100%{opacity:0;transform:translateY(-5px) scale(.99);filter:blur(5px)}}
@keyframes c1type{0%,18%{width:0}37%,100%{width:var(--w)}}
@keyframes c1clear{0%,37%{opacity:1}40%,100%{opacity:0}}
@keyframes c1ph{0%,18%{opacity:1}20%,39%{opacity:0}42%,100%{opacity:1}}
@keyframes c1user{0%,38%{opacity:0;transform:translateY(7px) scale(.97)}44%,100%{opacity:1;transform:none}}
@keyframes c1search{0%,45%{opacity:0}48%,58%{opacity:1}62%,100%{opacity:0}}
@keyframes c1bot{0%,59%{opacity:0;transform:translateY(6px)}64%,100%{opacity:1;transform:none}}
@keyframes c1a1{0%,63%{width:0}72%,100%{width:var(--w)}}
@keyframes c1a2{0%,70%{width:0}79%,100%{width:var(--w)}}
@keyframes c1src{0%,80%{opacity:0;transform:translateY(3px)}84%,100%{opacity:1;transform:none}}
@keyframes c1esc{0%,87%{opacity:0}90%,96%{opacity:1}99%,100%{opacity:0}}
"""

S1 = """
<div class="scene s1" data-scene="chat" style="--cycle:9000ms">
  <div class="wall"></div>
  __MENUBAR__
  <div class="hostwin">
    <div class="hw-bar"><i class="r"></i><i class="y"></i><i class="g"></i><b>Почта — Входящие</b></div>
    <div class="hw-body">
      <div class="tl b" style="width:52%"></div><div class="tl" style="width:88%"></div>
      <div class="tl" style="width:74%"></div><div class="tl" style="width:82%"></div>
      <div class="tl" style="width:46%"></div><div class="tl" style="width:69%"></div>
      <div class="tl" style="width:58%"></div>
    </div>
  </div>
  <div class="keycap an" style="animation-name:c1key">⇧⌘Space</div>

  <div class="panel an" style="animation-name:c1panel">
    __HEAD__
    <div class="thread">
      <div class="an" style="animation-name:c1user">
        <div class="row user"><div class="bub">Какая погода сегодня в Барселоне?</div></div>
        <div class="ts" style="text-align:right">9:41</div>
      </div>
      <div class="stack">
        <div class="status an" style="animation-name:c1search">
          __GLOBE__<span class="per" style="animation-name:shim;animation-duration:1.4s">Ищу в интернете…</span>
        </div>
        <div class="row bot an" style="animation-name:c1bot">
          <span class="avatar">__BRAIN__</span>
          <div class="bub" style="display:flex;flex-direction:column;gap:2px;align-self:start">
            <span class="type an" style="animation-name:c1a1">Сейчас +26 °C, ясно, ветер 12 км/ч.</span>
            <span class="type an" style="animation-name:c1a2">К вечеру +21 °C, дождя не будет.</span>
            <span class="src an" style="animation-name:c1src">__GLOBE2__ weather.com</span>
          </div>
        </div>
      </div>
    </div>
    <div class="composer">
      <span class="clip">__CLIP__</span>
      <div class="field">
        <span class="ph an" style="animation-name:c1ph">Спросите что угодно…</span>
        <span class="an" style="animation-name:c1clear;white-space:nowrap">
          <span class="type an st" style="animation-name:c1type">Какая погода сегодня в Барселоне?</span><span class="caret"></span>
        </span>
      </div>
      <span class="mic">__MIC__</span><span class="send">__SEND__</span>
    </div>
  </div>
  <div class="keycap an" style="animation-name:c1esc">Esc — скрыть</div>
</div>
"""

# ============================================================ 2 · СКРИНШОТ ОБЛАСТИ → ТАБЛИЦА
S2_CSS = """
.s2 .hostwin{left:16px; top:40px; width:300px; height:206px; color:var(--text)}
.s2 .dtable{width:100%; border-collapse:collapse; font-size:7.5px}
.s2 .dtable th{text-align:left; font-weight:700; color:var(--sec); padding:2.5px 4px;
  border-bottom:1px solid rgba(0,0,0,.18)}
.s2 .dtable td{padding:2.5px 4px; border-bottom:1px solid rgba(0,0,0,.07); font-variant-numeric:tabular-nums}
.s2 .dtable td.n,.s2 .dtable th.n{text-align:right}
.s2 .dim{position:absolute; inset:24px 0 0; background:rgba(8,12,20,.45); z-index:6}
.s2 .marq{position:absolute; left:24px; top:76px; z-index:7; border:1.5px solid rgba(255,255,255,.96);
  background:rgba(120,190,255,.14)}
.s2 .marq b{position:absolute; left:0; bottom:-16px; font-family:var(--mono); font-size:8.5px; color:#fff;
  background:rgba(18,20,26,.75); padding:1px 5px; border-radius:4px; white-space:nowrap}
.s2 .cross{position:absolute; z-index:8; width:13px; height:13px}
.s2 .cross::before,.s2 .cross::after{content:""; position:absolute; background:rgba(255,255,255,.96)}
.s2 .cross::before{left:6px; top:0; width:1px; height:13px}
.s2 .cross::after{top:6px; left:0; height:1px; width:13px}
.s2 .flash{position:absolute; inset:24px 0 0; background:#fff; z-index:9}
.s2 .panel{left:160px; top:24px; width:386px; z-index:11}
.s2 .att{display:flex; gap:7px; align-items:flex-start; padding:5px 9px 0}
.s2 .shot{width:74px; height:46px; border-radius:6px; flex:none; overflow:hidden; background:#fff;
  border:1px solid var(--sep); padding:3px 4px; color:var(--text)}
.s2 .shot .dtable{font-size:3.6px; table-layout:fixed; white-space:nowrap}
.s2 .shot .dtable th,.s2 .shot .dtable td{padding:.5px 1.5px; overflow:hidden}
.s2 .actbar{display:flex; gap:4px; flex-wrap:wrap}
.s2 .act{display:inline-flex; align-items:center; gap:3px; font-size:8.5px; padding:3px 7px;
  border-radius:6px; background:rgba(255,255,255,.75); border:1px solid var(--sep); white-space:nowrap}
.s2 .act.hot{background:var(--blue); border-color:transparent; color:#fff}
/* одна таблица на все строки — колонки обязаны совпадать, поэтому строки
   проявляются прозрачностью, а не высотой */
.s2 .mdtable{width:100%; border-collapse:collapse; font-size:8px; table-layout:fixed}
.s2 .mdtable th{text-align:left; font-weight:700; padding:1.5px 4px; border-bottom:1px solid rgba(0,0,0,.22)}
.s2 .mdtable td{padding:1.5px 4px; border-bottom:1px solid rgba(0,0,0,.07); font-variant-numeric:tabular-nums}
.s2 .mdtable .n{text-align:right}
@keyframes c2key{0%,2%{opacity:0;transform:translateY(6px) scale(.95)}5%{opacity:1;transform:none}7%{transform:scale(.92)}9%{transform:none}14%,100%{opacity:0}}
@keyframes c2dim{0%,7%{opacity:0}10%,25%{opacity:1}29%,100%{opacity:0}}
@keyframes c2marq{0%,10%{opacity:0;width:0;height:0}12%{opacity:1;width:0;height:0}23%,25%{opacity:1;width:262px;height:126px}28%,100%{opacity:0;width:262px;height:126px}}
@keyframes c2cross{0%,10%{opacity:0;transform:translate(18px,70px)}12%{opacity:1;transform:translate(18px,70px)}23%,26%{opacity:1;transform:translate(280px,196px)}29%,100%{opacity:0;transform:translate(280px,196px)}}
@keyframes c2flash{0%,25%{opacity:0}26%{opacity:.92}30%,100%{opacity:0}}
@keyframes c2panel{0%,27%{opacity:0;transform:translateY(9px) scale(.965);filter:blur(7px)}34%,94%{opacity:1;transform:none;filter:blur(0)}100%{opacity:0;transform:translateY(-5px) scale(.99);filter:blur(5px)}}
@keyframes c2thumb{0%,29%{opacity:0;transform:translate(-96px,58px) scale(3.1)}39%,100%{opacity:1;transform:none}}
@keyframes c2act{0%,39%{opacity:0;transform:translateY(5px)}44%,100%{opacity:1;transform:none}}
@keyframes c2press{0%,45%{transform:scale(1)}47%{transform:scale(.93)}50%,100%{transform:scale(1)}}
@keyframes c2ocr{0%,47%{opacity:0}50%,56%{opacity:1}59%,100%{opacity:0}}
@keyframes c2t1{0%,56%{opacity:0}59%,100%{opacity:1}}
@keyframes c2t2{0%,59%{opacity:0}62%,100%{opacity:1}}
@keyframes c2t3{0%,62%{opacity:0}65%,100%{opacity:1}}
@keyframes c2t4{0%,65%{opacity:0}68%,100%{opacity:1}}
@keyframes c2t5{0%,68%{opacity:0}71%,100%{opacity:1}}
@keyframes c2q{0%,72%{width:0}83%,100%{width:var(--w)}}
@keyframes c2qclear{0%,83%{opacity:1}85%,100%{opacity:0}}
@keyframes c2user{0%,83%{opacity:0;transform:translateY(6px)}87%,100%{opacity:1;transform:none}}
@keyframes c2ans{0%,88%{opacity:0;transform:translateY(5px)}92%,100%{opacity:1;transform:none}}
"""

TABLE_ROWS = [("Прямые продажи", "3,6", "4,2", "+17 %"),
              ("Партнёры", "1,5", "1,8", "+20 %"),
              ("Подписки", "5,4", "6,4", "+19 %")]


def doc_table():
    rows = "".join('<tr><td>%s</td><td class="n">%s</td><td class="n">%s</td><td class="n">%s</td></tr>' % r
                   for r in TABLE_ROWS)
    return ('<table class="dtable"><tr><th>Канал</th><th class="n">Q2</th>'
            '<th class="n">Q3</th><th class="n">Δ</th></tr>%s</table>' % rows)


def md_table():
    out = ('<colgroup><col style="width:46%"><col style="width:18%"><col style="width:18%">'
           '<col style="width:18%"></colgroup>'
           '<tr class="an" style="animation-name:c2t1"><th>Канал</th><th class="n">Q2</th>'
           '<th class="n">Q3</th><th class="n">Δ</th></tr>')
    for i, r in enumerate(TABLE_ROWS):
        out += ('<tr class="an" style="animation-name:c2t%d"><td>%s</td><td class="n">%s</td>'
                '<td class="n">%s</td><td class="n">%s</td></tr>' % (i + 2, r[0], r[1], r[2], r[3]))
    out += ('<tr class="an" style="animation-name:c2t5"><td><b>Итого</b></td><td class="n">10,5</td>'
            '<td class="n"><b>12,4</b></td><td class="n">+18 %</td></tr>')
    return '<table class="mdtable">' + out + "</table>"


S2 = ("""
<div class="scene s2" data-scene="shot" style="--cycle:12000ms">
  <div class="wall"></div>
  __MENUBAR__
  <div class="hostwin">
    <div class="hw-bar"><i class="r"></i><i class="y"></i><i class="g"></i><b>Q3-отчёт.numbers</b></div>
    <div class="hw-body"><div class="tl b" style="width:44%"></div>__DOCTABLE__</div>
  </div>
  <div class="keycap an" style="animation-name:c2key">⇧⌘D</div>
  <div class="dim an" style="animation-name:c2dim"></div>
  <div class="marq an lin" style="animation-name:c2marq"><b>786 × 378</b></div>
  <div class="cross an lin" style="animation-name:c2cross"></div>
  <div class="flash an" style="animation-name:c2flash"></div>

  <div class="panel an" style="animation-name:c2panel">
    __HEAD__
    <div class="att">
      <div class="shot an" style="animation-name:c2thumb">__SHOTTABLE__</div>
      <div class="actbar an" style="animation-name:c2act">
        <span class="act hot an" style="animation-name:c2press">__VIEWFINDER__ Извлечь текст</span>
        <span class="act">__BGDOT__ Убрать фон</span>
        <span class="act">__UPSCALE__ Апскейл</span>
      </div>
    </div>
    <div class="thread" style="padding-top:5px">
      <div class="status an" style="animation-name:c2ocr">
        __VIEWFINDER2__ <span class="per" style="animation-name:shim;animation-duration:1.4s">Распознаю таблицу…</span>
      </div>
      <div class="row bot">
        <span class="avatar">__BRAIN__</span>
        <div class="bub" style="align-self:start;padding:5px 7px;width:100%">__MDTABLE__</div>
      </div>
      <div class="an" style="animation-name:c2user">
        <div class="row user"><div class="bub">Посчитай прирост к Q2</div></div>
      </div>
      <div class="row bot an" style="animation-name:c2ans">
        <span class="avatar">__BRAIN2__</span>
        <div class="bub" style="align-self:start">Итого 12,4 млн — на 18 % больше Q2.</div>
      </div>
    </div>
    <div class="composer">
      <span class="clip">__CLIP__</span>
      <div class="field">
        <span class="an" style="animation-name:c2qclear;white-space:nowrap">
          <span class="type an st" style="animation-name:c2q">Посчитай прирост к Q2</span><span class="caret"></span>
        </span>
      </div>
      <span class="mic">__MIC__</span><span class="send">__SEND__</span>
    </div>
  </div>
</div>
""").replace("__DOCTABLE__", doc_table()).replace("__SHOTTABLE__", doc_table()) \
    .replace("__MDTABLE__", md_table())

# ============================================================ 3 · ДИКТОВКА С ПЕРЕВОДОМ (EN → ES)
S3_CSS = """
.s3 .notch{position:absolute; left:0; right:0; margin:0 auto; top:0; width:108px; height:21px;
  background:#08090C; border-radius:0 0 10px 10px; z-index:8}
.s3 .notch::after{content:""; position:absolute; left:50%; top:7px; width:5px; height:5px;
  margin-left:-2.5px; border-radius:50%; background:#23272F}
.s3 .pill{position:absolute; left:0; right:0; margin:0 auto; width:max-content; top:25px; z-index:9;
  display:flex; align-items:center; gap:7px; padding:5px 10px; border-radius:999px;
  background:rgba(20,22,28,.86); backdrop-filter:blur(14px); -webkit-backdrop-filter:blur(14px);
  border:1px solid rgba(255,255,255,.16); box-shadow:0 12px 26px -8px rgba(0,0,0,.75); color:#fff}
.s3 .rec{width:6px; height:6px; border-radius:50%; background:#FF453A; flex:none}
.s3 .eq{display:flex; align-items:center; gap:2px; height:14px}
.s3 .eq i{width:2px; height:13px; border-radius:2px; background:#7FD3FF; transform:scaleY(.2)}
.s3 .lang{font-family:var(--mono); font-size:8.5px; font-weight:600; background:rgba(255,255,255,.18);
  padding:1.5px 5px; border-radius:5px}
.s3 .heard{position:absolute; left:0; right:0; margin:0 auto; width:max-content; top:56px; z-index:9;
  font-size:9px; color:rgba(255,255,255,.85); background:rgba(18,20,26,.55); padding:3px 10px;
  border-radius:999px; backdrop-filter:blur(6px); -webkit-backdrop-filter:blur(6px)}
.s3 .heard u{text-decoration:none; opacity:.55; margin-right:5px}
.s3 .hostwin{left:96px; top:86px; width:370px; height:180px; color:var(--text)}
.s3 .msg{display:flex; flex-direction:column; gap:5px; padding:2px 0 6px}
.s3 .m{font-size:8.5px; line-height:1.4; padding:4px 7px; border-radius:9px; width:fit-content; max-width:76%}
.s3 .m.in{background:#EFEFF2; align-self:flex-start; border-radius:9px 9px 9px 3px}
.s3 .m.out{background:#D9F0D5; align-self:flex-end; border-radius:9px 9px 3px 9px}
.s3 .done{display:flex; gap:5px; align-items:center; font-size:8px; color:var(--sec); margin-top:auto}
.s3 .tgfield{display:flex; align-items:center; gap:6px; border-top:1px solid var(--sep);
  margin:8px -11px -10px; padding:7px 11px; background:#FAFAFC}
.s3 .tgin{flex:1; font-size:9px; min-height:14px; line-height:1.4}
@keyframes c3key{0%,2%{opacity:0;transform:translateY(6px) scale(.95)}5%{opacity:1;transform:none}7%{transform:scale(.92)}10%{transform:none}15%,100%{opacity:0}}
@keyframes c3pill{0%,9%{opacity:0;transform:translateY(-28px) scale(.9)}15%{opacity:1;transform:translateY(0) scale(1.05)}19%,84%{opacity:1;transform:none}91%,100%{opacity:0;transform:translateY(-24px) scale(.94)}}
@keyframes c3heard{0%,15%{opacity:0}19%,84%{opacity:1}90%,100%{opacity:0}}
@keyframes c3eq{0%,12%{transform:scaleY(.16)}17%{transform:scaleY(1)}100%{transform:scaleY(.16)}}
@keyframes c3lang{0%,26%{background:rgba(255,255,255,.18)}30%{background:rgba(127,211,255,.75)}36%,100%{background:rgba(255,255,255,.18)}}
@keyframes c3h1{0%,18%{width:0}34%,100%{width:var(--w)}}
@keyframes c3h2{0%,50%{width:0}66%,100%{width:var(--w)}}
@keyframes c3p1{0%,24%{width:0}42%,100%{width:var(--w)}}
@keyframes c3p2{0%,56%{width:0}76%,100%{width:var(--w)}}
@keyframes c3done{0%,86%{opacity:0;transform:translateY(4px)}90%,100%{opacity:1;transform:none}}
"""

S3 = """
<div class="scene s3" data-scene="dictation" style="--cycle:9500ms">
  <div class="wall"></div>
  __MENUBAR__
  <div class="notch"></div>
  <div class="pill an" style="animation-name:c3pill">
    <span class="rec"></span>
    <span class="eq">
      <i class="per" style="animation-name:c3eq;animation-duration:.90s;--i:0"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:.72s;--i:1"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:1.05s;--i:2"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:.83s;--i:3"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:.95s;--i:4"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:.68s;--i:5"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:1.10s;--i:6"></i>
      <i class="per" style="animation-name:c3eq;animation-duration:.78s;--i:7"></i>
    </span>
    <span class="lang an" style="animation-name:c3lang">EN → ES</span>
  </div>
  <div class="heard an" style="animation-name:c3heard">
    <u>говорю:</u><span class="type an st" style="animation-name:c3h1">Sorry for the delay,</span><span class="type an st" style="animation-name:c3h2"> I'll send the file tonight</span>
  </div>
  <div class="keycap an" style="animation-name:c3key">⌥⇧Space</div>

  <div class="hostwin">
    <div class="hw-bar"><i class="r"></i><i class="y"></i><i class="g"></i><b>Telegram — Lucía Fernández</b></div>
    <div class="hw-body">
      <div class="msg">
        <div class="m in">¿Cómo va la presentación?</div>
        <div class="m out">¡Casi lista!</div>
        <div class="m in">¿Me la mandas hoy?</div>
      </div>
      <div class="done an" style="animation-name:c3done">
        <span style="width:5px;height:5px;border-radius:50%;background:#34C759"></span>
        вставлено на месте курсора — приложение ничего не заметило
      </div>
      <div class="tgfield">
        <div class="tgin"><span class="type an st" style="animation-name:c3p1">Perdona el retraso —</span><span class="type an st" style="animation-name:c3p2"> te envío el archivo esta noche.</span><span class="caret"></span></div>
        <span style="color:var(--blue)">__SEND2__</span>
      </div>
    </div>
  </div>
</div>
"""

# ============================================================ 4 · МИРОВОЕ ВРЕМЯ
# Структура 1:1 с WorldTimeView: шапка (закрыть · поиск города · ссылка на
# Календарь · AM-PM/24 · Esc), полоса дней, сетка. Слева шапка строки —
# смещение от дома (или house.fill у домашнего города), название, чип
# аббревиатуры зоны, страна, свои часы и дата. Справа сплошная «стеклянная
# лента» из 24 ячеек без зазоров: номер часа в каждой, чип даты в локальную
# полночь (день недели / число / месяц), пунктир «сейчас». Рамка колонки —
# одна на всю высоту сетки (columnFrames), не по строкам.
S4_CSS = """
.s4 .menu{position:absolute; right:14px; top:26px; z-index:9; width:214px; padding:4px; border-radius:9px;
  background:rgba(250,250,252,.92); backdrop-filter:blur(24px) saturate(180%);
  -webkit-backdrop-filter:blur(24px) saturate(180%); border:1px solid rgba(0,0,0,.08);
  box-shadow:0 22px 44px -14px rgba(0,0,0,.55); font-size:9.5px}
.s4 .mi{display:flex; align-items:center; gap:6px; padding:3.5px 7px; border-radius:5px; position:relative}
.s4 .mi span.k{margin-left:auto; color:var(--sec); font-family:var(--mono); font-size:8.5px}
.s4 .msep{height:1px; background:rgba(0,0,0,.09); margin:3px 7px}
.s4 .hl{position:absolute; inset:0; border-radius:5px; background:var(--blue)}
.s4 .mi b,.s4 .mi .sf{position:relative; z-index:1}
.s4 .mi b{font-weight:400}
.s4 .mi.wt b,.s4 .mi.wt .sf{color:#fff}

.s4 .wtpanel{position:absolute; left:10px; top:34px; width:540px; padding:8px 9px 74px;
  border-radius:12px; background:var(--glass); backdrop-filter:blur(26px) saturate(180%);
  -webkit-backdrop-filter:blur(26px) saturate(180%); border:1px solid var(--glassline);
  box-shadow:0 26px 50px -18px rgba(0,0,0,.62)}
.s4 .wt-top{display:flex; align-items:center; gap:7px; padding:0 1px 7px; font-size:7px; color:var(--sec)}
.s4 .wt-top .sp{flex:1}
.s4 .wt-search{display:inline-flex; align-items:center; gap:4px; padding:2.5px 8px;
  border-radius:999px; background:rgba(0,0,0,.06)}
.s4 .wt-link{color:var(--blue); text-decoration:underline; font-weight:500}
.s4 .wt-seg{display:inline-flex; padding:1px; border-radius:5px; background:rgba(0,0,0,.06); gap:1px}
.s4 .wt-seg b{font-size:6.5px; font-weight:500; padding:1px 5px; border-radius:4px; color:var(--sec)}
.s4 .wt-seg b.on{background:#fff; color:var(--text); box-shadow:0 1px 1.5px rgba(0,0,0,.18)}
.s4 .wt-esc{font-size:6.5px; opacity:.55}
.s4 .wt-strip{display:flex; align-items:center; gap:2px; padding:0 0 7px 136px}
.s4 .wt-strip i{font-style:normal; font-size:7px; color:var(--sec); padding:2px 5px; border-radius:999px}
.s4 .wt-strip i.we{color:rgba(255,59,48,.8)}
.s4 .wt-strip i.on{background:rgba(0,0,0,.1); color:var(--text); font-weight:600; padding:2px 8px}

.s4 .wt-grid{position:relative; display:flex; flex-direction:column; gap:4px; padding:2px 0}
.s4 .wtrow{display:flex; align-items:center; height:26px}
.s4 .wthead{width:136px; flex:none; display:flex; align-items:center; gap:5px; padding-right:7px}
.s4 .off{width:15px; flex:none; font-size:7px; font-weight:600; color:var(--sec);
  font-variant-numeric:tabular-nums; display:flex; justify-content:flex-end}
.s4 .who{display:flex; flex-direction:column; min-width:0; flex:1}
.s4 .who b{font-size:8px; font-weight:600; display:flex; align-items:center; gap:3px; white-space:nowrap}
.s4 .abbr{font-size:5px; font-weight:500; font-style:normal; color:var(--sec);
  background:rgba(120,120,128,.16); padding:.5px 3px; border-radius:999px}
.s4 .who u{font-size:6px; color:var(--sec); text-decoration:none; white-space:nowrap}
.s4 .clock{display:flex; flex-direction:column; align-items:flex-end; flex:none}
.s4 .clock b{font-size:8px; font-weight:600; font-variant-numeric:tabular-nums}
.s4 .clock u{font-size:6px; color:var(--sec); text-decoration:none; white-space:nowrap}

.s4 .band{display:flex; flex:1; height:26px; border-radius:7px; overflow:hidden;
  box-shadow:0 0 0 .5px rgba(0,0,0,.08)}
.s4 .cell{flex:1; display:flex; flex-direction:column; align-items:center; justify-content:center;
  font-size:7.5px; font-weight:600; font-variant-numeric:tabular-nums; position:relative;
  box-shadow:inset .5px 0 0 rgba(255,255,255,.22)}
.s4 .cell:first-child{box-shadow:none}
.s4 .cell.night{background:rgba(64,84,209,.55); color:#fff}
.s4 .cell.shoulder{background:rgba(250,204,99,.38)}
.s4 .cell.work{background:rgba(255,255,255,.32)}
.s4 .cell.mid{background:rgba(38,51,161,.85); color:#fff; line-height:1.05}
.s4 .cell.mid s{font-size:4.5px; font-weight:700; text-decoration:none}
.s4 .cell.mid b{font-size:7px; font-weight:700}
.s4 .cell.now::after{content:""; position:absolute; left:3px; right:3px; bottom:3.5px; height:1.5px;
  background:repeating-linear-gradient(90deg, rgba(0,0,0,.5) 0 3px, transparent 3px 5.5px)}
.s4 .cell.night.now::after,.s4 .cell.mid.now::after{
  background:repeating-linear-gradient(90deg, rgba(255,255,255,.85) 0 3px, transparent 3px 5.5px)}

.s4 .fr{position:absolute; top:-3px; bottom:-3px; width:20px; border-radius:6px; pointer-events:none}
.s4 .hovfr{border:1.2px solid rgba(0,0,0,.35)}
.s4 .selfr{border:1.5px solid rgba(0,0,0,.8); background:rgba(0,0,0,.05)}
.s4 .split{position:absolute; top:-3px; bottom:-3px; width:1px;
  background:repeating-linear-gradient(180deg, rgba(0,0,0,.42) 0 3px, transparent 3px 5.5px)}
.s4 .slotpop{position:absolute; z-index:6; width:154px; padding:7px 8px; border-radius:8px;
  background:#fff; border:1px solid rgba(0,0,0,.08); box-shadow:0 16px 30px -10px rgba(0,0,0,.45)}
.s4 .slotpop::before{content:""; position:absolute; top:-4.5px; left:62px; width:9px; height:9px;
  background:#fff; transform:rotate(45deg); border-left:1px solid rgba(0,0,0,.08);
  border-top:1px solid rgba(0,0,0,.08)}
.s4 .slotpop .ttl{font-size:7.5px; font-weight:600; display:flex; align-items:center; gap:4px; margin-bottom:5px}
.s4 .slotpop .fld{height:13px; border-radius:4px; background:rgba(0,0,0,.05); display:flex;
  align-items:center; padding:0 5px; color:var(--sec); font-size:6.5px}
.s4 .slotpop .btns{display:flex; gap:4px; margin-top:5px; justify-content:flex-end}
.s4 .slotpop .btn2{font-size:6.5px; padding:2px 8px; border-radius:4px; background:var(--blue);
  color:#fff; font-weight:600}
.s4 .slotpop .btn2.gh{background:rgba(0,0,0,.06); color:var(--sec)}

@keyframes c4menu{0%,4%{opacity:0;transform:translateY(-7px) scale(.97)}9%,20%{opacity:1;transform:none}25%,100%{opacity:0;transform:translateY(-4px) scale(.99)}}
@keyframes c4hl{0%,10%{opacity:0}13%,20%{opacity:1}24%,100%{opacity:0}}
@keyframes c4panel{0%,20%{opacity:0;transform:translateY(10px) scale(.97);filter:blur(7px)}28%,93%{opacity:1;transform:none;filter:blur(0)}100%{opacity:0;transform:translateY(-5px) scale(.99);filter:blur(5px)}}
@keyframes c4r1{0%,28%{opacity:0;transform:translateX(-8px)}34%,100%{opacity:1;transform:none}}
@keyframes c4r2{0%,31%{opacity:0;transform:translateX(-8px)}37%,100%{opacity:1;transform:none}}
@keyframes c4r3{0%,34%{opacity:0;transform:translateX(-8px)}40%,100%{opacity:1;transform:none}}
@keyframes c4r4{0%,37%{opacity:0;transform:translateX(-8px)}43%,100%{opacity:1;transform:none}}
@keyframes c4hov{0%,46%{opacity:0;transform:translateX(0)}49%{opacity:1;transform:translateX(0)}58%{opacity:1;transform:translateX(__DX__px)}61%,100%{opacity:0;transform:translateX(__DX__px)}}
@keyframes c4sel{0%,59%{opacity:0}62%,92%{opacity:1}96%,100%{opacity:0}}
@keyframes c4split{0%,67%{opacity:0}70%,92%{opacity:1}96%,100%{opacity:0}}
@keyframes c4pop{0%,73%{opacity:0;transform:translateY(5px) scale(.96)}78%,92%{opacity:1;transform:none}96%,100%{opacity:0}}
"""

# Дом — Москва; «сейчас» 13:04 по дому, планируется слот 15:30.
WT_CITIES = [
    ("Москва",   "Россия",         "MSK",  0, "13:04", "чт, 23 июл", ("ЧТ", "23", "ИЮЛ")),
    ("Лондон",   "Великобритания", "BST", -2, "11:04", "чт, 23 июл", ("ЧТ", "23", "ИЮЛ")),
    ("Нью-Йорк", "США",            "EDT", -7, "06:04", "чт, 23 июл", ("ЧТ", "23", "ИЮЛ")),
    ("Токио",    "Япония",         "JST",  6, "19:04", "чт, 23 июл", ("ПТ", "24", "ИЮЛ")),
]
NOW_COL, SEL_COL = 13, 15
HEAD_W, BAND_W = 136.0, 386.0
CELL_W = BAND_W / 24
FR_X0 = HEAD_W - 2                      # рамка колонки 0 (ширина = ячейка + 4)
FR_DX = SEL_COL * CELL_W                # проезд рамки до выбранной колонки
SPLIT_X = HEAD_W + (SEL_COL + 0.5) * CELL_W
POP_X = SPLIT_X - 66.5                  # стрелка поповера смотрит в центр колонки


def cell_kind(h):
    """cellKind(): ночь / плечо / рабочие часы (по умолчанию 9…18)."""
    if h < 6 or h >= 22: return "night"
    if 9 <= h < 18:      return "work"
    return "shoulder"


def wt_rows():
    out = []
    for i, (name, country, abbr, off, clock, date, chip) in enumerate(WT_CITIES):
        cells = ""
        for col in range(24):
            local = ((col + off) % 24 + 24) % 24
            now = " now" if col == NOW_COL else ""
            if local == 0:
                cells += ('<i class="cell mid%s"><s>%s</s><b>%s</b><s>%s</s></i>'
                          % (now, chip[0], chip[1], chip[2]))
            else:
                cells += '<i class="cell %s%s">%d</i>' % (cell_kind(local), now, local)
        offcell = sf("house.fill", 7) if off == 0 else ("−%d" % -off if off < 0 else "+%d" % off)
        out.append('<div class="wtrow an" style="animation-name:c4r%d"><div class="wthead">'
                   '<span class="off">%s</span>'
                   '<span class="who"><b>%s<i class="abbr">%s</i></b><u>%s</u></span>'
                   '<span class="clock"><b>%s</b><u>%s</u></span></div>'
                   '<div class="band">%s</div></div>'
                   % (i + 1, offcell, name, abbr, country, clock, date, cells))
    return "".join(out)


def wt_strip():
    days = [("20", 0), ("21", 0), ("22", 0), ("23", 1), ("24", 0), ("25", 2), ("26", 2), ("27", 0)]
    return "".join('<i class="%s">%s</i>' % (["", "on", "we"][k], "июл 23" if k == 1 else d)
                   for d, k in days)


S4 = """
<div class="scene s4" data-scene="worldtime" style="--cycle:8500ms">
  <div class="wall"></div>
  __MENUBAR_HOT__
  <div class="menu an" style="animation-name:c4menu">
    <div class="mi">__M1__<b>Открыть ассистента</b><span class="k">⇧⌘Space</span></div>
    <div class="mi">__M2__<b>Скриншот + панель</b><span class="k">⇧⌘S</span></div>
    <div class="mi">__M3__<b>Скриншот области + панель</b><span class="k">⇧⌘D</span></div>
    <div class="msep"></div>
    <div class="mi wt"><span class="hl an" style="animation-name:c4hl"></span>__M4__<b>Мировое время</b></div>
    <div class="msep"></div>
    <div class="mi">__M5__<b>Диктовка</b><span class="k">⌥Space</span></div>
    <div class="mi">__M6__<b>Диктовка с переводом</b><span class="k">⌥⇧Space</span></div>
  </div>

  <div class="wtpanel an" style="animation-name:c4panel">
    <div class="wt-top">
      __XMARK__
      <span class="wt-search">__PLUS__ Добавить город…</span>
      <span class="sp"></span>
      <span class="wt-link">Открыть Календарь</span>
      <span class="wt-seg"><b>AM/PM</b><b class="on">24</b></span>
      <span class="wt-esc">Esc — закрыть</span>
    </div>
    <div class="wt-strip">__STRIP__</div>
    <div class="wt-grid">
      __ROWS__
      <div class="fr hovfr an lin" style="animation-name:c4hov;left:__FRX__px"></div>
      <div class="fr selfr an" style="animation-name:c4sel;left:__SELX__px"></div>
      <div class="split an" style="animation-name:c4split;left:__SPLITX__px"></div>
      <div class="slotpop an" style="animation-name:c4pop;left:__POPX__px;top:124px">
        <div class="ttl">__CAL__ Новая встреча · 15:30</div>
        <div class="fld">Синк с Лондоном и Токио</div>
        <div class="btns"><span class="btn2 gh">Отмена</span><span class="btn2">Создать</span></div>
      </div>
    </div>
  </div>
</div>
"""

# ============================================================ 5 · ТРИ ОПЕРАЦИИ С КАРТИНКОЙ
# Каждая операция читается по трём признакам: нажатая пилюля, прогресс по её
# нижней кромке и строка результата под панелью действий. «Убрать фон» —
# шторка со светящимся краем едет по кадру, за ней остаётся прозрачность,
# после чего контур предмета коротко подсвечивается: видно, что вырезали.
S5_CSS = """
.s5 .panel{left:52px; top:42px; width:456px}
.s5 .work{display:flex; gap:12px; padding:8px 10px 7px}
.s5 .shotwrap{position:relative; width:196px; height:132px; flex:none}
.s5 .photo{position:absolute; inset:0; border-radius:8px; overflow:hidden; border:1px solid var(--sep)}
.s5 .ph-checker{position:absolute; inset:0; background:#fff;
  background-image:conic-gradient(rgba(0,0,0,.08) 90deg, transparent 0 180deg, rgba(0,0,0,.08) 0 270deg, transparent 0);
  background-size:13px 13px}
.s5 .ph-bg{position:absolute; inset:0; background:linear-gradient(160deg,#F6CE86,#E38B6B 55%,#8E5476)}
.s5 .ph-bg::after{content:""; position:absolute; left:20px; top:16px; width:30px; height:30px;
  border-radius:50%; background:rgba(255,255,255,.62)}
.s5 .ph-bg .shadow{position:absolute; left:52px; bottom:22px; width:92px; height:12px; border-radius:50%;
  background:rgba(0,0,0,.26); filter:blur(3px)}
.s5 .wipe{position:absolute; top:0; bottom:0; width:16px; z-index:4;
  background:linear-gradient(90deg, rgba(255,255,255,0), rgba(255,255,255,.9));
  border-right:1.5px solid #fff; box-shadow:0 0 14px 2px rgba(255,255,255,.75)}
.s5 .mug{position:absolute; left:70px; bottom:26px; width:56px; height:64px; z-index:2}
.s5 .mug .body{position:absolute; inset:0; border-radius:7px 7px 17px 17px;
  background:linear-gradient(150deg,#3B5771,#1B2938)}
.s5 .mug .rim{position:absolute; left:0; right:0; top:0; height:9px; border-radius:7px; background:#51708F}
.s5 .mug .hand{position:absolute; right:-15px; top:17px; width:21px; height:26px;
  border:6px solid #3B5771; border-left:0; border-radius:0 14px 14px 0}
.s5 .blob{position:absolute; right:18px; bottom:30px; width:28px; height:19px; border-radius:6px;
  background:#6E4B2E; z-index:2; transform:rotate(-8deg)}
.s5 .brush{position:absolute; right:11px; bottom:25px; width:0; height:30px; border-radius:15px;
  z-index:5; background:rgba(0,113,227,.55)}
.s5 .loupe{position:absolute; z-index:5; top:22px; left:8px; width:60px; height:60px; border-radius:50%;
  border:1.5px solid rgba(255,255,255,.92); box-shadow:0 0 0 1px rgba(0,0,0,.22), 0 6px 14px -4px rgba(0,0,0,.5)}
.s5 .side{flex:1; display:flex; flex-direction:column; gap:9px; min-width:0}
.s5 .actbar{display:flex; gap:5px; flex-wrap:wrap}
.s5 .act{position:relative; overflow:hidden; display:inline-flex; align-items:center; gap:4px;
  font-size:9.5px; padding:4px 9px; border-radius:6px; background:rgba(255,255,255,.75);
  border:1px solid var(--sep); white-space:nowrap}
.s5 .act u{position:absolute; left:0; bottom:0; height:2px; width:100%; background:var(--blue);
  transform:scaleX(0); transform-origin:0 50%}
.s5 .results{position:relative; height:15px}
.s5 .res1{position:absolute; inset:0; display:flex; align-items:center; gap:5px; font-size:9px;
  color:#1B7F3B; white-space:nowrap}
.s5 .note{font-size:9px; color:var(--sec); line-height:1.5}
@keyframes c5panel{0%,3%{opacity:0;transform:translateY(9px) scale(.97);filter:blur(6px)}9%,94%{opacity:1;transform:none;filter:blur(0)}100%{opacity:0;transform:translateY(-4px) scale(.99);filter:blur(4px)}}
@keyframes c5bar{0%,8%{opacity:0;transform:translateY(5px)}13%,100%{opacity:1;transform:none}}
/* 1 · убрать фон */
@keyframes c5hot1{0%,15%{background:rgba(255,255,255,.75);color:var(--text)}17%,31%{background:var(--blue);color:#fff}35%,100%{background:rgba(255,255,255,.75);color:var(--text)}}
@keyframes c5p1{0%,16%{transform:scaleX(0)}18%{transform:scaleX(.06)}31%,100%{transform:scaleX(1)}}
@keyframes c5wipe{0%,18%{opacity:0;transform:translateX(-18px)}20%{opacity:1;transform:translateX(-18px)}30%{opacity:1;transform:translateX(196px)}32%,100%{opacity:0;transform:translateX(196px)}}
@keyframes c5bgout{0%,19%{clip-path:inset(0 0 0 0)}31%,100%{clip-path:inset(0 0 0 100%)}}
@keyframes c5cut{0%,31%{filter:none}34%,40%{filter:drop-shadow(0 0 2px rgba(0,113,227,.95)) drop-shadow(0 0 5px rgba(0,113,227,.5))}45%,100%{filter:none}}
@keyframes c5r1{0%,33%{opacity:0;transform:translateY(3px)}36%,49%{opacity:1;transform:none}52%,100%{opacity:0}}
/* 2 · апскейл */
@keyframes c5hot2{0%,43%{background:rgba(255,255,255,.75);color:var(--text)}45%,57%{background:var(--blue);color:#fff}61%,100%{background:rgba(255,255,255,.75);color:var(--text)}}
@keyframes c5p2{0%,44%{transform:scaleX(0)}46%{transform:scaleX(.06)}57%,100%{transform:scaleX(1)}}
@keyframes c5soft{0%,46%{filter:blur(1.6px) saturate(.9)}58%,100%{filter:blur(0) saturate(1)}}
@keyframes c5loupe{0%,45%{opacity:0;transform:translate(0,0)}48%{opacity:1;transform:translate(0,0)}57%,60%{opacity:1;transform:translate(120px,34px)}64%,100%{opacity:0;transform:translate(120px,34px)}}
@keyframes c5r2{0%,57%{opacity:0;transform:translateY(3px)}60%,70%{opacity:1;transform:none}73%,100%{opacity:0}}
/* 3 · удалить объекты */
@keyframes c5hot3{0%,64%{background:rgba(255,255,255,.75);color:var(--text)}66%,79%{background:var(--blue);color:#fff}83%,100%{background:rgba(255,255,255,.75);color:var(--text)}}
@keyframes c5p3{0%,65%{transform:scaleX(0)}67%{transform:scaleX(.06)}79%,100%{transform:scaleX(1)}}
@keyframes c5brush{0%,66%{width:0;opacity:0}68%{opacity:1;width:0}74%,78%{width:52px;opacity:1}83%,100%{width:52px;opacity:0}}
@keyframes c5blob{0%,77%{opacity:1;filter:blur(0)}84%,100%{opacity:0;filter:blur(3px)}}
@keyframes c5r3{0%,83%{opacity:0;transform:translateY(3px)}86%,100%{opacity:1;transform:none}}
"""

S5 = """
<div class="scene s5" data-scene="image" style="--cycle:11000ms">
  <div class="wall"></div>
  __MENUBAR__
  <div class="panel an" style="animation-name:c5panel">
    __HEAD__
    <div class="work">
      <div class="shotwrap">
        <div class="photo an" style="animation-name:c5soft">
          <div class="ph-checker"></div>
          <div class="ph-bg an lin" style="animation-name:c5bgout"><div class="shadow"></div></div>
          <div class="mug an" style="animation-name:c5cut">
            <div class="hand"></div><div class="body"></div><div class="rim"></div>
          </div>
          <div class="blob an" style="animation-name:c5blob"></div>
          <div class="brush an" style="animation-name:c5brush"></div>
          <div class="wipe an lin" style="animation-name:c5wipe"></div>
        </div>
        <div class="loupe an lin" style="animation-name:c5loupe"></div>
      </div>
      <div class="side">
        <div class="actbar an" style="animation-name:c5bar">
          <span class="act an" style="animation-name:c5hot1">__BGDOT__ Убрать фон<u class="an" style="animation-name:c5p1"></u></span>
          <span class="act an" style="animation-name:c5hot2">__UPSCALE__ Апскейл ×4<u class="an" style="animation-name:c5p2"></u></span>
          <span class="act an" style="animation-name:c5hot3">__ERASER__ Удалить объекты<u class="an" style="animation-name:c5p3"></u></span>
        </div>
        <div class="results">
          <span class="res1 an" style="animation-name:c5r1">__CHECK1__ Фон удалён — PNG с прозрачностью</span>
          <span class="res1 an" style="animation-name:c5r2">__CHECK2__ Увеличено ×4 — 2048 × 1536</span>
          <span class="res1 an" style="animation-name:c5r3">__CHECK3__ Объект убран, место заращено</span>
        </div>
        <div class="note an" style="animation-name:c5bar">
          Фон и распознавание текста — на нативных движках Apple, без ключей и без токенов.
          Апскейл и удаление объектов — по ключу fal.ai.
        </div>
      </div>
    </div>
    __COMPOSER__
  </div>
</div>
"""


# ============================================================ ПОДСТАНОВКИ
def fill(html, **kw):
    for k, v in kw.items():
        html = html.replace("__%s__" % k, v)
    return html


S1 = fill(S1, MENUBAR=menubar("Почта"), HEAD=head("openai", "OpenAI", "Стандартный"),
          GLOBE=sf("globe", 10), GLOBE2=sf("globe", 8), BRAIN=sf("brain", 12),
          CLIP=sf("paperclip", 12), MIC=sf("mic.fill", 10), SEND=sf("paperplane.fill", 10))

S2 = fill(S2, MENUBAR=menubar("Numbers"), HEAD=head("anthropic", "Anthropic", "Аналитик"),
          VIEWFINDER=sf("text.viewfinder", 9), VIEWFINDER2=sf("text.viewfinder", 10),
          BGDOT=sf("person.and.background.dotted", 9),
          UPSCALE=sf("arrow.up.backward.and.arrow.down.forward.rectangle", 9),
          BRAIN=sf("brain", 12), BRAIN2=sf("brain", 12),
          CLIP=sf("paperclip", 12), MIC=sf("mic.fill", 10), SEND=sf("paperplane.fill", 10))

S3 = fill(S3, MENUBAR=menubar("Telegram"), SEND2=sf("paperplane.fill", 11))

S4 = fill(S4, MENUBAR_HOT=menubar("Finder", hot=True),
          M1=sf("brain", 11), M2=sf("camera.viewfinder", 11), M3=sf("camera.viewfinder", 11),
          M4=sf("clock", 11), M5=sf("mic.fill", 11), M6=sf("globe", 11),
          XMARK=sf("xmark.circle.fill", 10), PLUS=sf("plus", 7), CAL=sf("calendar", 8),
          STRIP=wt_strip(), ROWS=wt_rows(),
          FRX="%.1f" % FR_X0, SELX="%.1f" % (FR_X0 + FR_DX),
          SPLITX="%.1f" % SPLIT_X, POPX="%.1f" % POP_X)
S4_CSS = S4_CSS.replace("__DX__", "%.1f" % FR_DX)

S5 = fill(S5, MENUBAR=menubar("Cuate"), HEAD=head("mistral", "Mistral", "Стандартный"),
          BGDOT=sf("person.and.background.dotted", 10),
          UPSCALE=sf("arrow.up.backward.and.arrow.down.forward.rectangle", 10),
          ERASER=sf("eraser", 10), CHECK1=sf("checkmark.circle.fill", 9),
          CHECK2=sf("checkmark.circle.fill", 9), CHECK3=sf("checkmark.circle.fill", 9),
          COMPOSER=composer("Или просто спросите про картинку…"))

# ============================================================ ОПИСАНИЯ СЦЕН
SCENES = [
    dict(key="chat", file="1-chat", css=S1_CSS, html=S1, cycle=9000, hold=.86,
         name="1 · Чат", sub="⇧⌘Space → панель → веб-поиск → ответ со ссылкой", step="Чат",
         ru=("Спросите что угодно, где угодно",
             "Cuate живёт в строке меню и открывается поверх любого приложения. "
             "Спросили — получили ответ — Esc.",
             [("⇧⌘Space", "Открыть ассистента")]),
         en=("Ask anything, anywhere",
             "Cuate lives in the menu bar and opens over any app. Ask, read the answer, press Esc.",
             [("⇧⌘Space", "Open Assistant")]),
         beats=[(.04, "иконка в строке меню подсвечивается"),
                (.08, "клавиша ⇧⌘Space «нажимается»"),
                (.13, "панель въезжает: scale .965 → 1, blur 7 → 0"),
                (.20, "вопрос про погоду печатается в поле ввода"),
                (.40, "поле очищается, пузырь вопроса встаёт в ленту"),
                (.48, "«Ищу в интернете…» — модель сама пошла в веб"),
                (.64, "ответ проявляется построчно, как при стриминге"),
                (.84, "чип источника weather.com"),
                (.90, "подсказка «Esc — скрыть»")]),

    dict(key="shot", file="2-area-shot", css=S2_CSS, html=S2, cycle=12000, hold=.93,
         name="2 · Скриншот области → таблица",
         sub="⇧⌘D → рамка по таблице → распознавание → вопрос по данным", step="Скриншот",
         ru=("Сняли таблицу — получили таблицу",
             "Выделите кусок экрана: он попадёт в чат. «Извлечь текст» превращает снимок таблицы "
             "в настоящую таблицу — и по ней сразу можно спрашивать.",
             [("⇧⌘D", "Скриншот области + панель"), ("⇧⌘S", "Скриншот экрана + панель")]),
         en=("Capture a table, get a table",
             "Drag a region and it lands in the chat. Extract Text turns a screenshot of a table into "
             "a real table — then just ask about the numbers.",
             [("⇧⌘D", "Area Screenshot + Panel"), ("⇧⌘S", "Screenshot + Panel")]),
         beats=[(.05, "клавиша ⇧⌘D"),
                (.10, "экран притухает, курсор — перекрестие"),
                (.12, "рамка тянется по таблице, размер считается на лету"),
                (.26, "вспышка затвора"),
                (.30, "панель, снимок «прилетает» в неё вложением"),
                (.44, "панель действий; «Извлечь текст» нажимается"),
                (.50, "«Распознаю таблицу…»"),
                (.56, "таблица собирается в чате строка за строкой"),
                (.72, "печатается вопрос по этим же данным"),
                (.88, "ответ по распознанным числам")]),

    dict(key="dictation", file="3-dictation", css=S3_CSS, html=S3, cycle=9500, hold=.82,
         name="3 · Диктовка с переводом",
         sub="⌥⇧Space → пилюля под камерой → английская речь, испанский текст", step="Диктовка",
         ru=("Говорите по-английски — пишется по-испански",
             "Пилюля появляется под камерой, а перевод впечатывается туда, где стоит курсор, — "
             "фраза за фразой, пока вы говорите. Чужое приложение ничего не замечает.",
             [("⌥Space", "Диктовка"), ("⌥⇧Space", "Диктовка с переводом")]),
         en=("Speak English, type Spanish",
             "A pill drops under the camera and the translation is typed where the cursor is, "
             "phrase by phrase, while you speak. The other app never notices.",
             [("⌥Space", "Dictate"), ("⌥⇧Space", "Dictate with translation")]),
         beats=[(.05, "клавиша ⌥⇧Space"),
                (.10, "пилюля выпадает из-под камеры с перелётом"),
                (.17, "эквалайзер оживает, идёт запись"),
                (.19, "под пилюлей видно, что именно услышано по-английски"),
                (.25, "в поле Telegram печатается испанский перевод"),
                (.30, "бейдж EN → ES моргает: язык меняется на лету"),
                (.56, "вторая фраза — речь и перевод идут внахлёст"),
                (.90, "пилюля уезжает, текст остаётся в чужом поле")]),

    dict(key="worldtime", file="4-world-time", css=S4_CSS, html=S4, cycle=8500, hold=.86,
         name="4 · Мировое время",
         sub="меню → сетка суток → колонка = один момент → встреча в календаре", step="Мир",
         ru=("Один момент — сразу во всех городах",
             "Сетка суток по вашим городам: вертикальный срез — это один и тот же момент везде. "
             "Клик по получасу зовёт на встречу.",
             []),
         en=("One moment, every city",
             "A 24-hour grid across your cities: one vertical slice is the same instant everywhere. "
             "Click a half-hour to send an invite.",
             []),
         beats=[(.05, "меню статус-бара раскрывается"),
                (.13, "подсветка доезжает до «Мировое время»"),
                (.22, "панель разворачивается"),
                (.28, "строки городов въезжают: часы, страна, свои сутки"),
                (.49, "пунктирная рамка ведёт курсор по суткам"),
                (.62, "колонка выбрана — 15 / 13 / 08 / 21 сверху вниз"),
                (.70, "получасовой пунктир делит выбранный час"),
                (.78, "поповер: встреча на 15:30 в Календаре")]),

    dict(key="image", file="5-image-ops", css=S5_CSS, html=S5, cycle=11000, hold=.90,
         name="5 · Картинки: три операции",
         sub="фон → апскейл ×4 → удаление объектов, на одном снимке", step="Картинки",
         ru=("Три операции с любой картинкой",
             "Прикрепите изображение — появится панель действий: убрать фон, апскейл ×4 "
             "или закрасить лишнее, чтобы стереть.",
             []),
         en=("Three fixes for any image",
             "Attach a picture and the actions bar appears: remove the background, upscale ×4, "
             "or brush over something to erase it.",
             []),
         beats=[(.04, "панель с прикреплённой картинкой"),
                (.17, "«Убрать фон» нажата, по кромке кнопки идёт прогресс"),
                (.20, "шторка со светящимся краем едет по кадру"),
                (.31, "за шторкой — прозрачность; контур предмета подсвечен"),
                (.36, "результат: PNG с альфа-каналом"),
                (.45, "«Апскейл ×4» — лупа идёт по кадру, мягкое становится резким"),
                (.60, "результат: 2048 × 1536"),
                (.66, "«Удалить объекты» — кисть закрашивает лишний предмет"),
                (.77, "объект растворяется, место заращивается"),
                (.86, "результат: чистый кадр")]),
]

# ============================================================ ТРАНСПОРТ (карточка сцены)
TRANSPORT_CSS = """
.card{width:560px; background:var(--bg)}
.bar{display:flex; align-items:center; gap:10px; padding:9px 12px; border-top:1px solid var(--sep); background:#fff}
.play{width:26px; height:26px; flex:none; border-radius:50%; border:1px solid var(--sep); background:#fff;
  cursor:pointer; display:grid; place-items:center; padding:0; color:var(--text)}
.play svg{width:10px; height:10px; fill:currentColor}
.play .p2{display:none}
.play[data-playing="true"] .p1{display:none}
.play[data-playing="true"] .p2{display:block}
.rail{position:relative; flex:1; height:26px; cursor:pointer; touch-action:none}
.rail .ln{position:absolute; left:0; right:0; top:12px; height:2px; background:var(--sep); border-radius:2px}
.rail .fl{position:absolute; left:0; top:12px; height:2px; width:100%; background:var(--blue);
  border-radius:2px; transform-origin:0 50%}
.rail .tk{position:absolute; top:8px; width:1px; height:10px; background:var(--sec); opacity:.4}
.rail .hd{position:absolute; top:7px; width:2px; height:12px; background:var(--text); border-radius:2px; margin-left:-1px}
.rdout{font-family:var(--mono); font-size:10px; color:var(--sec); white-space:nowrap;
  font-variant-numeric:tabular-nums; width:250px; text-align:right; overflow:hidden; text-overflow:ellipsis}
.rdout b{color:var(--text); font-weight:600}
"""

TRANSPORT_HTML = """
  <div class="bar">
    <button class="play" type="button" id="play" data-playing="true" aria-label="Пауза">
      <svg class="p1" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 1.5v9l7-4.5z"/></svg>
      <svg class="p2" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 1.5h2.5v9H2.5zM7 1.5h2.5v9H7z"/></svg>
    </button>
    <div class="rail" id="rail" role="slider" tabindex="0" aria-label="Позиция в сцене"
         aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">
      <div class="ln"></div><div class="fl" id="fl" style="transform:scaleX(0)"></div>
      __TICKS__<div class="hd" id="hd" style="left:0"></div>
    </div>
    <div class="rdout" id="out"><b>0.00 с</b></div>
  </div>
"""

TRANSPORT_JS = """
(function(){
  var CYCLE=__CYCLE__, HOLD=__HOLD__, BEATS=__BEATS__;
  var stage=document.getElementById('stage'), play=document.getElementById('play');
  var rail=document.getElementById('rail'), fl=document.getElementById('fl');
  var hd=document.getElementById('hd'), out=document.getElementById('out');
  var t=0, playing=false, start=0;
  var reduce=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // натуральная ширина каждой «печатаемой» строки — измеряется, а не задаётся
  Array.prototype.forEach.call(document.querySelectorAll('.type'),function(el){
    el.style.setProperty('--w', el.scrollWidth+'px');
  });
  function paint(){
    stage.style.setProperty('--delay',(-t*CYCLE)+'ms');
    fl.style.transform='scaleX('+t+')';
    hd.style.left=(t*100).toFixed(2)+'%';
    rail.setAttribute('aria-valuenow',Math.round(t*100));
    var lab='',i; for(i=0;i<BEATS.length;i++){ if(t>=BEATS[i][0]) lab=BEATS[i][1]; }
    out.textContent=(t*CYCLE/1000).toFixed(2)+' с — '+lab;
    out.title=lab;
  }
  function setPlay(on){
    playing=on; play.setAttribute('data-playing',on?'true':'false');
    play.setAttribute('aria-label',on?'Пауза':'Проиграть');
    stage.style.setProperty('--play',on?'running':'paused');
    if(on) start=performance.now()-t*CYCLE;
  }
  function frame(now){ if(playing){ t=((now-start)%CYCLE)/CYCLE; paint(); } requestAnimationFrame(frame); }
  play.addEventListener('click',function(){ setPlay(!playing); });
  function scrub(ev){ var r=rail.getBoundingClientRect();
    t=Math.min(1,Math.max(0,(ev.clientX-r.left)/r.width)); paint(); }
  rail.addEventListener('pointerdown',function(ev){ setPlay(false); rail.setPointerCapture(ev.pointerId); scrub(ev); });
  rail.addEventListener('pointermove',function(ev){ if(ev.buttons===1) scrub(ev); });
  rail.addEventListener('keydown',function(ev){ var s=ev.shiftKey?.1:.02;
    if(ev.key==='ArrowRight'){ setPlay(false); t=Math.min(1,t+s); paint(); ev.preventDefault(); }
    if(ev.key==='ArrowLeft'){ setPlay(false); t=Math.max(0,t-s); paint(); ev.preventDefault(); } });
  if(reduce){ t=HOLD; setPlay(false); } else { setPlay(true); }
  paint(); requestAnimationFrame(frame);
})();
"""


def js_beats(beats):
    return "[" + ",".join('[%s,"%s"]' % (round(b[0], 3), b[1]) for b in beats) + "]"


def ticks(beats):
    return "".join('<span class="tk" style="left:%.2f%%"></span>' % (b[0] * 100) for b in beats)


def scene_card(s):
    body = "\n".join(['<div class="card">', '  <div class="stage" id="stage">',
                      s["html"].replace('class="scene ', 'class="scene is-on '), "  </div>",
                      TRANSPORT_HTML.replace("__TICKS__", ticks(s["beats"])), "</div>"])
    css = CORE + TRANSPORT_CSS + s["css"]
    js = (TRANSPORT_JS.replace("__CYCLE__", str(s["cycle"])).replace("__HOLD__", str(s["hold"]))
          .replace("__BEATS__", js_beats(s["beats"])))
    return "\n".join([
        '<!-- @dsCard group="08 · Онбординг" name="%s" subtitle="%s" width="560" height="352" -->'
        % (s["name"], s["sub"]),
        '<meta charset="utf-8"><meta name="viewport" content="width=560">',
        "<style>" + symbol_defs(body + css) + css + "</style>", body,
        "<script>" + js + "</script>", ""])


# ============================================================ ОКНО ТУРА
SHELL_CSS = """
.win{width:560px; height:640px; background:var(--bg); display:flex; flex-direction:column; overflow:hidden}
.cap{padding:20px 30px 0; text-align:center; display:flex; flex-direction:column; align-items:center; gap:9px; flex:1}
.cap h2{font-size:17px; font-weight:600; letter-spacing:-.01em}
.cap p{font-size:13px; line-height:1.5; color:var(--sec); max-width:45ch}
.chips{display:flex; flex-direction:column; gap:7px; margin-top:2px}
.chip{display:flex; align-items:center; gap:9px; justify-content:center}
.kbd{font-family:var(--mono); font-size:12px; font-weight:600; padding:3px 8px; border-radius:6px; background:var(--field)}
.chip span{font-size:12.5px; color:var(--sec)}
.langpick{display:inline-flex; padding:2px; gap:2px; border-radius:8px; background:var(--field)}
.langpick button{font:inherit; font-size:11.5px; padding:3px 12px; border:0; border-radius:6px;
  background:transparent; color:var(--sec); cursor:pointer}
.langpick button[aria-pressed="true"]{background:#fff; color:var(--text); box-shadow:0 1px 2px rgba(0,0,0,.16)}
.steps{display:flex; gap:6px; padding:18px 30px 14px}
.step{flex:1; display:flex; flex-direction:column; gap:5px; align-items:center; cursor:pointer;
  background:none; border:0; padding:0; font:inherit}
.step-bar{width:100%; height:3px; border-radius:2px; background:var(--field); overflow:hidden}
.step-bar i{display:block; height:100%; width:100%; background:var(--blue); transform:scaleX(0); transform-origin:0 50%}
.step[data-done="true"] .step-bar i{transform:scaleX(1); background:var(--sec); opacity:.4}
.step-label{font-size:10px; color:var(--sec)}
.step[aria-current="step"] .step-label{color:var(--text); font-weight:600}
.foot{display:flex; align-items:center; gap:8px; padding:11px 14px; border-top:1px solid var(--sep)}
.foot .sp{flex:1}
.btn{font:inherit; font-size:13px; padding:4px 13px; border-radius:7px; cursor:pointer;
  border:1px solid var(--sep); background:#fff; color:var(--text)}
.btn.ghost{border-color:transparent; background:transparent; color:var(--sec)}
.btn.primary{background:var(--blue); border-color:transparent; color:#fff; font-weight:500}
"""

SHELL_JS = """
(function(){
  var S=__DATA__;
  var stage=document.getElementById('stage'), scenes=stage.querySelectorAll('.scene');
  var steps=document.getElementById('steps'), capT=document.getElementById('capT');
  var capB=document.getElementById('capB'), capC=document.getElementById('capC');
  var back=document.getElementById('back'), next=document.getElementById('next'), skip=document.getElementById('skip');
  var i=0, lang='ru', t=0, start=0;
  var reduce=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var STR={ru:{skip:'Пропустить',back:'Назад',next:'Далее',done:'Начать'},
           en:{skip:'Skip',back:'Back',next:'Next',done:'Get Started'}};
  S.forEach(function(s,k){
    var el=document.createElement('button');
    el.type='button'; el.className='step';
    el.innerHTML='<span class="step-bar"><i></i></span><span class="step-label"></span>';
    el.querySelector('.step-label').textContent=s.step;
    el.addEventListener('click',function(){ go(k); });
    steps.appendChild(el);
  });
  function cap(){
    var s=S[i], c=s[lang];
    capT.textContent=c.t; capB.textContent=c.b; capC.innerHTML='';
    c.keys.forEach(function(k){
      var r=document.createElement('div'); r.className='chip';
      var a=document.createElement('span'); a.className='kbd'; a.textContent=k[0];
      var b=document.createElement('span'); b.textContent=k[1];
      r.appendChild(a); r.appendChild(b); capC.appendChild(r);
    });
    var st=STR[lang];
    skip.textContent=st.skip; back.textContent=st.back;
    next.textContent = i===S.length-1 ? st.done : st.next;
    back.style.visibility = i===0 ? 'hidden':'visible';
    skip.style.visibility = i===S.length-1 ? 'hidden':'visible';
  }
  function paintSteps(){
    var k,kids=steps.children;
    for(k=0;k<kids.length;k++){
      kids[k].setAttribute('data-done', k<i ?'true':'false');
      if(k===i) kids[k].setAttribute('aria-current','step'); else kids[k].removeAttribute('aria-current');
      kids[k].querySelector('i').style.transform='scaleX('+(k<i?1:(k===i?t:0))+')';
    }
  }
  // ширину печатаемых строк можно измерить только у видимой сцены
  function measure(root){
    Array.prototype.forEach.call(root.querySelectorAll('.type'),function(el){
      if(el.getAttribute('data-m')) return;
      el.setAttribute('data-m','1'); el.style.setProperty('--w', el.scrollWidth+'px');
    });
  }
  function go(k){
    i=(k+S.length)%S.length;
    var n; for(n=0;n<scenes.length;n++) scenes[n].classList.toggle('is-on', n===i);
    measure(scenes[i]);
    t = reduce ? S[i].hold : 0;
    stage.style.setProperty('--play', reduce?'paused':'running');
    stage.style.setProperty('--delay', (-t*S[i].cycle)+'ms');
    start=performance.now(); cap(); paintSteps();
  }
  function frame(now){ if(!reduce){ t=((now-start)%S[i].cycle)/S[i].cycle; paintSteps(); }
    requestAnimationFrame(frame); }
  next.addEventListener('click',function(){ go(i+1); });
  back.addEventListener('click',function(){ go(i-1); });
  skip.addEventListener('click',function(){ go(S.length-1); });
  Array.prototype.forEach.call(document.querySelectorAll('.langpick button'),function(b){
    b.addEventListener('click',function(){
      lang=b.getAttribute('data-lang');
      Array.prototype.forEach.call(document.querySelectorAll('.langpick button'),function(x){
        x.setAttribute('aria-pressed', x===b?'true':'false'); });
      cap(); });
  });
  go(0); requestAnimationFrame(frame);
})();
"""


def jstr(x):
    return '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'


def shell_card():
    data = "[" + ",".join(
        "{step:%s,cycle:%d,hold:%s,ru:{t:%s,b:%s,keys:[%s]},en:{t:%s,b:%s,keys:[%s]}}" % (
            jstr(s["step"]), s["cycle"], s["hold"],
            jstr(s["ru"][0]), jstr(s["ru"][1]),
            ",".join("[%s,%s]" % (jstr(k[0]), jstr(k[1])) for k in s["ru"][2]),
            jstr(s["en"][0]), jstr(s["en"][1]),
            ",".join("[%s,%s]" % (jstr(k[0]), jstr(k[1])) for k in s["en"][2]))
        for s in SCENES) + "]"
    body = "\n".join([
        '<div class="win">', '  <div class="stage" id="stage">',
        "".join(s["html"] for s in SCENES), "  </div>",
        '  <div class="cap">',
        '    <div class="langpick" role="group" aria-label="Язык">',
        '      <button type="button" data-lang="ru" aria-pressed="true">Русский</button>',
        '      <button type="button" data-lang="en" aria-pressed="false">English</button>',
        "    </div>",
        '    <h2 id="capT"></h2><p id="capB"></p><div class="chips" id="capC"></div>',
        "  </div>", '  <div class="steps" id="steps"></div>', '  <div class="foot">',
        '    <button class="btn ghost" type="button" id="skip"></button><span class="sp"></span>',
        '    <button class="btn" type="button" id="back"></button>',
        '    <button class="btn primary" type="button" id="next"></button>',
        "  </div>", "</div>"])
    css = CORE + SHELL_CSS + "".join(s["css"] for s in SCENES)
    return "\n".join([
        '<!-- @dsCard group="08 · Онбординг" name="0 · Окно тура · 560×640" '
        'subtitle="Пять страниц, рельс шагов, переключение RU/EN" width="560" height="640" -->',
        '<meta charset="utf-8"><meta name="viewport" content="width=560">',
        "<style>" + symbol_defs(body + css) + css + "</style>", body,
        "<script>" + SHELL_JS.replace("__DATA__", data) + "</script>", ""])


# ============================================================ ЛОКАЛЬНЫЙ СТЕНД
PREVIEW = """<!doctype html>
<meta charset="utf-8">
<title>Онбординг Cuate — стенд</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#E9E9ED; color:#15161A; padding:32px 28px 64px;
    font:15px/1.6 -apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif}
  h1{font-size:22px; font-weight:600; letter-spacing:-.01em}
  .lede{color:#5A5F6A; max-width:74ch; margin-top:6px; font-size:13.5px}
  .grid{display:flex; gap:26px; align-items:flex-start; margin-top:26px; flex-wrap:wrap}
  .col{display:flex; flex-direction:column; gap:22px}
  .card{background:#fff; border-radius:12px; box-shadow:0 18px 40px -22px rgba(12,14,20,.55); overflow:hidden}
  .cap{display:flex; align-items:baseline; gap:8px; padding:9px 13px;
    border-bottom:1px solid rgba(0,0,0,.08); font-size:12px; font-weight:600}
  .cap span{font-weight:400; color:#7A7F8A; font-size:11.5px}
  iframe{display:block; border:0; width:560px}
</style>
<h1>Онбординг Cuate — 5 сцен в движении</h1>
<p class="lede">
  Пересобирается командой <code>python3 design/onboarding/build_cards.py</code>.
  У каждой сцены снизу плеер: пауза и перетаскивание по шкале разбирают движение по кадрам,
  засечки — ключевые моменты. В окне тура страницы листаются кнопками, подписи — RU/EN.
</p>
<div class="grid">
  <div class="col">
    <div class="card"><div class="cap">0 · Окно тура целиком <span>560×640</span></div>
      <iframe src="onboarding/tour/shell.html" height="640" title="Окно тура"></iframe></div>
  </div>
  <div class="col">__COL2__</div>
  <div class="col">__COL3__</div>
</div>
"""


def preview():
    def card(s):
        return ('<div class="card"><div class="cap">%s <span>%s</span></div>'
                '<iframe src="onboarding/scenes/%s.html" height="352" title="%s"></iframe></div>'
                % (s["name"], s["sub"], s["file"], s["name"]))
    return (PREVIEW.replace("__COL2__", "".join(card(s) for s in SCENES[:3]))
                   .replace("__COL3__", "".join(card(s) for s in SCENES[3:])))


def write(rel, text):
    p = OUT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    print("%-40s %7.1f KB" % (rel, len(text.encode()) / 1024))


write("onboarding/tour/shell.html", shell_card())
for sc in SCENES:
    write("onboarding/scenes/%s.html" % sc["file"], scene_card(sc))
write("preview.html", preview())
print("готово →", OUT)

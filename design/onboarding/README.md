# Mockup of the new onboarding tour

Five animated scenes, one per status-bar menu item, plus the whole tour
window — a replacement for the eight static images in
`OnboardingIllustrations.swift`.

```sh
python3 design/onboarding/build_cards.py     # rebuild
open design/onboarding/dist/preview.html     # open the preview stand
```

## What lives where

| File | What it is |
|---|---|
| `build_cards.py` | the generator: scenes, timings, captions — everything is here |
| `dump_symbols.swift` | renders SF Symbols to PNG → `symbols.json` |
| `symbols.json` | base64 glyphs, attached as a CSS mask |
| `dist/` | the built cards + `preview.html` (not needed in git, they are regenerated) |

The cards also live in Claude Design, project "Cuate Settings Redesign",
group "08 · Onboarding" — the `@dsCard` format on the file's first line.

## The glyphs are real

SF Symbols are rendered by the system (`NSImage(systemSymbolName:)`) into PNG
with alpha and attached as a `mask`, so they take `currentColor` — exactly like
template images in the app. The symbols are the same ones the code uses:
`brain.head.profile` in the menu bar, `brain` in the reply avatar,
`paperplane.fill`, `mic.fill`, `paperclip`, `text.viewfinder`,
`person.and.background.dotted`, `eraser`,
`arrow.up.backward.and.arrow.down.forward.rectangle`, `house.fill`.

Provider logos are taken as-is from
`Cuate/Assets.xcassets/Provider-*.imageset/*.svg`.

Hotkeys are the defaults from `Cuate/App/HotkeyCombo.swift`.

## The animation model (this is what to port to SwiftUI)

**One beat per scene.** A scene has a normalized phase `0…1`; every layer knows
its own window inside that phase and derives its progress from it. In the mockup
that is percentages in `@keyframes` plus a single `--delay` variable for the
whole scene — which is why the scene can be scrubbed: shifting the phase shifts
everything at once, in sync.

In SwiftUI the same thing comes from `TimelineView(.animation)`: take `t` from
it, and each layer computes `progress(in: from...to)`.

Important differences between the mockup and the app:

* here the scene **loops** so it can be inspected; in the tour it plays a single
  pass and freezes on the result frame, with a button to replay;
* under `accessibilityReduceMotion` the phase jumps straight to the result frame
  (the cards do the same: the page opens paused).

## The scenes

| # | Scene | Beat | What it shows |
|---|---|---|---|
| 1 | Chat | 9.0 s | ⇧⌘Space → panel → a weather question → web search → answer with a link |
| 2 | Area screenshot | 12.0 s | ⇧⌘D → frame over a table → "Extract text" → the table in the chat → a question about the numbers |
| 3 | Dictation | 9.5 s | ⌥⇧Space → pill under the camera → English speech, Spanish text in someone else's field |
| 4 | World Time | 8.5 s | menu → the day grid → a column is one moment → a meeting in Calendar |
| 5 | Images | 11.0 s | remove background (curtain) → upscale ×4 (loupe) → remove object (brush) |

The timings of the key moments live in `SCENES[*]["beats"]` and are shown in the
player under the scene — that is the storyboard for the implementation.

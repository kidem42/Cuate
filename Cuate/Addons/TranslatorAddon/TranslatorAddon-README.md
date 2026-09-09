# Translator addon

Translates the text selected in any app into a bubble next to it.

**Flow.** ⌃⌥T (configurable) → `SelectionLocator` reads the selection's
screen rectangle through Accessibility: web content (Safari, Chrome) through
the WebKit text-marker range (`AXSelectedTextMarkerRange` →
`AXBoundsForTextMarkerRange`; the plain range answers a zero rectangle
there), native text views through `AXSelectedTextRange` +
`AXBoundsForRange`, the focused element asked system-wide and then from the
app, Safari's web area found under the focused window when nothing is
focused; the mouse position when nothing answers →
`SelectionGrabber` (host) reads the text (AX, then a ⌘C round-trip) →
`TranslatorService` streams it through the resolved provider, in paragraph
chunks for long selections → `TranslatorOverlayController` shows the bubble
in a non-activating panel (the frontmost app keeps its focus and selection)
and frames the panel from AppKit text metrics as the text grows.

**Prompt.** `TranslatorPrompt`: a sibling of `DictationTextShaping` — the
instruction in the system slot, the text alone in `<text>` tags, the answer
asked for in `<result>` tags, the reply shaped mechanically (lead-ins,
labels, quotes, fences, em dashes; a bold wrapper around the whole reply).
The model detects the language; the settings only give the target and
where a text already in the target goes.

**Placement.** `TranslatorGeometry`: a popover pinned to the selection —
above it, left-aligned; below it with no room above; hanging from its first
visible line when it fills the screen; right-aligned with no room on the
right. Width ≤ 400 pt, height ≤ 320 pt and two fifths of the screen; the
pinned corner never moves while the text streams.

**Bubble.** SwiftUI in the dictation island's material. Header: the target
language chip (a menu; picking re-translates), chunk progress, copy, open
in chat (the original lands quoted in the composer), and the linger ring
that closes on click. Body: an AppKit text view that scrolls past the cap
and lets the translation be selected and copied in pieces; a click inside
makes the panel key (like a popover) without activating Cuate. The bubble
leaves after the linger time (Settings, default 30 s; hovering holds the
clock), on Esc, on a click anywhere else, or when the hotkey brings a new one.

**Model.** By default the dictation cleanup choice (Settings → Voice), a
small fast model; overridable per provider in the tab. Nothing is recorded
in the spend ledger, like the dictation pass.

**Files.** `TranslatorAddon` (singleton, hotkey 903, the flow),
`TranslatorSettings` (`translator.*` defaults), `TranslatorLocalization`
(`TRL`), `TranslatorPrompt` + `TranslatorGeometry` (pure, contract-tested
by `scripts/TranslatorContractTest.swift`), `SelectionLocator`,
`TranslatorService`, `TranslatorOverlay` (model, metrics, controller,
panel), `TranslatorBubbleView`, `TranslatorSettingsView` (+ the General
toggle). Diagnostics category `translator`; events only, never text.

# Theme implementation checklist

The complete adaptation surface for adding a theme. The code is the source of
truth; this file records WHERE to look so nothing gets forgotten. Verified on the
Yule/Aurora cycle (4.8). When a new token or a `themeID` branch is added — update
this file too.

## 1. Implementation steps (in order)

| # | Step | Where |
|---|-----|-----|
| 1 | A `case` in the enum + `displayName` | `Cuate/Views/AppTheme.swift` (AppTheme) |
| 2 | Two presets, `<theme>Dark` / `<theme>Light` (~40 tokens) | AppTheme.swift (ThemePalette) |
| 3 | A `case` in `resolve()` + panelTint in `tinted(...)` | AppTheme.swift |
| 4 | World Time tokens, dark+light (~25) | `Cuate/Addons/WorldTimeAddon/WorldTimeTheme.swift` (a switch with no default — the compiler will remind you) |
| 5 | Decorations: a `<Theme>Theme.swift` file + a `case` in `ThemeDecorations` — both variants: `.chat` and `.worldTime` (the calm one, along the edges) | AppTheme.swift ~L1000 ⚠️ there is a `default: Color.clear` there — the compiler will NOT catch a forgotten theme |
| 6 | Signature branches on `themeID` (see §4) — decide for each: the default or something bespoke | per the §4 list |
| 7 | Holiday auto-activation (if the theme is seasonal) | `Cuate/App/HolidayThemeManager.swift` (the Holiday enum, occurrence, userPicked) + the `appearance.holidayThemes.caption` caption in `Localization.swift` |
| 8 | The theme picker — automatic (CaseIterable), just check the thumbnail | `Cuate/Views/ThemeGridPicker.swift` |

## 2. ThemePalette tokens (AppTheme.swift)

- **The panel**: `backgroundStyle` `panelTint` `pattern` `panelBorder` `panelGlow` `glassSurface` `cornerMarkColor`
- **The bubbles**: `userFill/Text/Stroke/Corners` `userGlow` `assistantFill/Text/Stroke/Corners` `assistantGlyph` `glyphColor`
- **Text**: `accent` `accentInk` (→`ink`) `primaryText` `secondaryText` `timestampColor` `timestamp` (the format!) `timestampMono` `fontDesign`
- **The composer**: `inputFill/Stroke/Radius` `placeholderColor` `placeholderCaret` `divider` `composerButtonRadius` `micColor/Stroke/Fill/GlyphColor/Dashed` `sendFill/GlyphColor/Glow/Rim`
- **Content**: `codeFill/Text` `inlineCodeFill/Text` `bulletGlyph` `bulletColor` `quoteColor` `dictationColors` `recordingAccent` `voiceProgress`

## 3. WorldTimeTheme tokens

`midnight night shoulder work cellDarkText midnightStroke` · `text secondary` ·
`sep bandStroke bandRadius` · `selStroke/Fill/Dash/Glow hoverStroke` ·
`now nowDash` · `weekend capsule chip daySel rail link`

## 4. Signature branches on `themeID` (the compiler does NOT check these — walk them by hand)

| Spot | File | Precedents |
|---|---|---|
| The send button | `ChatWindow.swift` ~L956 | Día=marigolds, Halloween=a pumpkin, `sendRim` (Yule/…), everything else — a `sendFill` circle + paperplane |
| The "Thinking…" spinner | `ThinkingIndicator.swift` | Yule=CandyCaneSpinner, everything else — the `dictationColors` equalizer |
| The assistant glyph | `MessageRow.swift` ~L303 | Día=SugarSkull, Halloween=PumpkinIcon, everything else — `assistantGlyph` as text |
| Decorations + the WT variant | `AppTheme.swift` ThemeDecorations | Halloween/Día/Sakura/Pastel=chat only; Yule/Aurora=both contexts |
| The image action pills | `AttachmentActionsBar.swift` `pillColors` | Día=three colors by role, Halloween=a solid outline, everything else — the generic accent |
| The mic button | `EnhancedVoiceButton.swift` ~L150 | the shape from `composerButtonRadius`, dashed from `micDashed` |
| ANSI in code blocks | `MarkdownBlocksView.swift` ~L337 | the `placeholderCaret` family paints green with the accent |
| The background pattern | `AppTheme.swift` ThemePatternOverlay | Blueprint=a grid (+PatternFadeMask in WT), Terminal=scanlines |
| The timestamp format | `MessageRow.swift` `formatTime` | a new format = a new `ThemeTimestamp` case |

## 5. Palette consumers (what to check with your eyes)

| File | Elements |
|---|---|
| ChatWindow | the panel surface, the header, the status pill (+ the `inputStroke` outline), the pinned bar, the "down" button, retry, the attachment card, the whole composer |
| MessageRow | bubbles, timestamps, the glyph, inline code, links |
| MarkdownBlocksView | headings, lists (the bullet glyph!), the code block + ANSI + copy, inline code, quotes (including inside a user bubble — `isInUserBubble`), tables, dividers |
| VoiceMessagePlayer / EnhancedVoiceButton / RecordingStatusView / DictationService | voice, the mic, the recording pill, the dictation capsules (148/182×34, 14 bars) |
| ThinkingIndicator | the spinner everywhere (status, backfill, image decode placeholders) |
| ArtifactView / MermaidBlockView / AgentInlineImageView | the artifact card, mermaid, inline images |
| AttachmentActionsBar / ImageResultActionsBar | the pills under an attachment and under a result |
| AgentGatewayViews / AgentFileChips / AgentSidebar / AgentTerminalText / HermesSidebarView | the approval card, the step log, the role chip, the file pills, the sidebar (the active session's highlight = `ink` 0.12), terminal text |
| WorldTimeView (+Theme) | the whole grid, the top bar with the date strip, busy blocks, selection/"now", the `.worldTime` decorations |
| ThemeGridPicker | the theme thumbnail |

## 6. The pass before handing it over

Both schemes (light/dark) × [the chat in all its states → the markdown set →
voice+dictation+recording → an attachment with pills → the agent surfaces → World
Time → the theme picker] + switching themes back and forth on macOS 26 (the glass
node is resident — see `themedPanelSurface`, never recreate it inside if branches).

## 7. Rules paid for in blood

- Mockups come only from transcribing the view's code (sizes/icons/strings from
  the sources; SF Symbols rendered into PNG masks), never "from memory".
- A new element of the scaffolding = every theme automatically; a theme = tokens only.
- TODO: remove the `default:` from `ThemeDecorations` — it is the only switch over
  themes where the compiler doesn't catch a forgotten one.

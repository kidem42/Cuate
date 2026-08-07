# Cuate — an architectural review of chats, sessions, history and autoscroll

**Code version:** 2.13
**Review date:** 2026-07-18
**Status:** a historical document. Everything from §3/§6 (except P1-3, "the conversation list") shipped in 3.3 — see §8 at the bottom.
**Occasion:** a hang on a user's machine (14+ min, 99.7% CPU on main, ~6 GB footprint) + a request for a full audit of the chat subsystem.

---

## 0. The main conclusion about the hang (a correction to README-hang-investigation)

The external briefing (`README - Cuate-hang-investigation.md`) identified the mechanism correctly (a quadratic re-placement of `LazyVStack` in SwiftUI). Its claim of "no windowing" was **true for the shipped 2.13, which is what hung** — there `ForEach(chatStore.messages)` rendered the entire history.

**An important version nuance:** windowing (`visibleCount`, `historyPageSize=30`, backfill) is **uncommitted WIP in the working tree (2.14)** and is not in the release yet. Which means:
- Recommendation #1 from the README ("window the data") is already implemented in 2.14: [ChatWindow.swift:55-63](../Cuate/Views/ChatWindow.swift#L55-L63), [ChatWindow.swift:165](../Cuate/Views/ChatWindow.swift#L165).
- **But windowing on its own does not remove the hang** — because the window bounds the *number* of messages, not their *size* (megabyte inline images), and it doesn't touch the two real amplifiers below. That is exactly why P0-1 and P0-3 are needed.

**Why it actually hung** — two real amplifiers the README doesn't mention:

1. **The window bounds the number of messages, not their size.** A 30-message window can contain several megabyte-sized messages. One huge markdown expands into a gigantic SwiftUI subtree (see §4).
2. **`GeometryReader` wraps the whole scroll view and pushes the width into every row.** [ChatWindow.swift:146-168](../Cuate/Views/ChatWindow.swift#L146-L168): `maxBubbleWidth: max(320, geo.size.width * 0.75)` reaches **every** `MessageRow`. When the external monitor woke up, the window geometry changed → `geo.size.width` changed → the bodies of **all** visible rows were invalidated → a full re-layout of an already gigantic tree. That is the bridge between the trigger (a display reconfigure) and the amplifier.

Confirmation from the memory dump: `MALLOC_SMALL = 5.9 GB` with `ImageIO = 16 MB` (`footprint.txt`). So the memory was eaten by **millions of small refcounted view-tree/AttributeGraph objects**, not by images. That is exactly the signature of "a huge number of subviews/DisplayList.Items", not of "heavy attachments".

Conclusion: the right fix is not "history windowing" (it exists) but **removing `GeometryReader` from the scroll root** + **stopping image decoding inside `body`** (see §6, P0).

### 0.1 A clarification from local data (the developer's machine, 2026-07-18)

Analysis of `chat.json` on the developer's machine (6.5 MB):
- **15 messages, ~1 KB of text in total** (381 characters max). There is no long text at all.
- **6.5 MB = the inline base64 of two images** (user 3.6 MB + assistant 2.87 MB of base64). File-backed attachments: 0.

Conclusion: the dominant bloat vector is **inline images, not long markdown**. Therefore:
- **P0-2 (a text size limit) is reclassified as optional** — it doesn't trigger on real data and was the only *visible* change; dropped.
- **P0-3 surfaces: an image is decoded on every `body` re-evaluation** — `attachment.data` (computed, base64-decoded on every access: [ChatModels.swift:30-34](../Cuate/Models/ChatModels.swift#L30)) is touched in `AttachmentPreviewBubble.body` together with `NSImage(data:)` and no cache: [MessageRow.swift:373-390](../Cuate/Views/MessageRow.swift#L373). In a re-layout storm (GeometryReader) every iteration re-decodes a multi-megabyte image; even a hover (`isHovering` → re-render) decodes it again.

---

## 1. The architecture map (how it actually works)

### 1.1 The data model
- `ChatMessage` — a `struct`, `Codable`, `Identifiable` with a **stable** `UUID id` (good): [ChatModels.swift:44-67](../Cuate/Models/ChatModels.swift#L44).
- `ChatAttachment` — an inline `base64: String` **or** a file-based `fileURLString`: [ChatModels.swift:7-41](../Cuate/Models/ChatModels.swift#L7).
- `ChatStore: ObservableObject`, `@Published var messages: [ChatMessage]` — the single source of truth for the UI and the API context.

### 1.2 Persistence
- The format: **a monolithic JSON per conversation** (`PersistedChat { messages, conversationSummary, summaryCoversCount }`): [ChatModels.swift:196-200](../Cuate/Models/ChatModels.swift#L196).
- Files: `chat.json` (the shared one) + `chat-<sha256(name).prefix16>.json` per isolated preset: [ChatModels.swift:112-131](../Cuate/Models/ChatModels.swift#L112).
- All disk I/O runs on a single serial `diskQueue` (qos .utility): [ChatModels.swift:159](../Cuate/Models/ChatModels.swift#L159). **Good** (the flush→load order is preserved).
- Saving is debounced by 1.0 s, and the snapshot is taken at scheduling time: [ChatModels.swift:455-469](../Cuate/Models/ChatModels.swift#L455). Encoding/writing happens in the background. **Good**, but every save serializes the **whole** history (see §5, P1).
- Loading is asynchronous from disk, with media retention (dropping attachments/records older than N days) and a `loadGeneration` guard against switching races: [ChatModels.swift:319-390](../Cuate/Models/ChatModels.swift#L319). **Good.**

### 1.3 "Sessions" / histories
- There is **no** concept of "a list of past conversations". There is exactly: the shared chat + one chat per *isolated* preset.
- "New chat" = `clearMessages()` + a greeting: [ChatWindow.swift:632-635](../Cuate/Views/ChatWindow.swift#L632). `clearMessages()` **irreversibly** deletes the messages **and the media files**: [ChatModels.swift:547-567](../Cuate/Models/ChatModels.swift#L547).
- Switching conversations happens "in place" (the same `ChatStore` object, the observers stay alive), and a reply in flight is not interrupted — it finishes streaming in the background and is delivered into its own conversation: [ChatModels.swift:215-253](../Cuate/Models/ChatModels.swift#L215), [ChatWindow.swift:804-921](../Cuate/Views/ChatWindow.swift#L804). This is a **strong**, carefully built part.

### 1.4 The context for the model (compression)
- A sliding window + a rolling summary: past the threshold, older turns are folded into a summary by the same model: [ChatService.swift:188-257](../Cuate/Providers/ChatService.swift#L188).
- The threshold `compressionTokenThreshold = 6000`, `keepRecentCount = 8`, token estimation = `chars/4`: [ChatService.swift:191-198](../Cuate/Providers/ChatService.swift#L191).
- Images are attached only to the last user message (token control): [ChatService.swift:145-186](../Cuate/Providers/ChatService.swift#L145). **Matches best practice.**

### 1.5 Reply streaming
- Chunks are **coalesced** before being written into the store (a flush at ~8 Hz / 120 ms) so that `messages` isn't republished and markdown isn't re-parsed on every token: [ChatWindow.swift:816-874](../Cuate/Views/ChatWindow.swift#L816). The comment itself admits the `O(answer²)` risk. **Coalescing is good**, but the quadratic behavior remains within a second (see §4).
- The web-search agent tool loop (up to 4 iterations): [ChatService.swift:67-135](../Cuate/Providers/ChatService.swift#L67).

### 1.6 Autoscroll
- `.defaultScrollAnchor(.bottom)` — the layout starts "at the bottom": [ChatWindow.swift:203](../Cuate/Views/ChatWindow.swift#L203).
- "At the bottom" tracking through `onScrollGeometryChange` (macOS 15+), with a fallback for macOS 14: [ChatWindow.swift:1234-1254](../Cuate/Views/ChatWindow.swift#L1234).
- A scroll-intent monitor (wheel up = "I'm reading history", which suppresses auto-follow): [ChatWindow.swift:1081-1096](../Cuate/Views/ChatWindow.swift#L1081).
- Three scroll modes (`glide`/`follow`/`instant`): [ChatWindow.swift:706-745](../Cuate/Views/ChatWindow.swift#L706).
- Backfill upwards while holding the anchor row: [ChatWindow.swift:689-704](../Cuate/Views/ChatWindow.swift#L689).

Autoscroll is a **well thought-out and generally high-quality** subsystem; it needs almost no substantive changes (minor things in §5).

---

## 2. What follows best practice (the strengths)

- ✅ Stable `UUID` identity on messages (cheap `ForEach` diffing).
- ✅ History windowing by pages + backfill that holds position.
- ✅ All disk I/O in the background, on a single serial queue, with debouncing and snapshots.
- ✅ A `loadGeneration` guard against races on fast conversation switches.
- ✅ Background completion of a reply's stream when the preset changes, delivered into its "home" conversation.
- ✅ Stream chunk coalescing (the store isn't republished per token).
- ✅ A rolling summary + a sliding window for the context; images only on the last user message.
- ✅ A shared `NSDataDetector` (not recreated on every render): [MessageRow.swift:341-344](../Cuate/Views/MessageRow.swift#L341).

That is noticeably above average for a pet/indie project. The problems are concentrated in **two places**: rendering a single message, and the storage/session model.

---

## 3. Dysfunctions and gaps — prioritized

### P0 — the direct causes of the hang

**P0-1. `GeometryReader` at the scroll root pushes the width into every row.**
[ChatWindow.swift:146-171](../Cuate/Views/ChatWindow.swift#L146). Any geometry change (a monitor waking up or being connected, a window resize, entering fullscreen, Mission Control) → `maxBubbleWidth` is recomputed → the bodies of **all** visible rows are invalidated → a full re-layout. This is the confirmed bridge from "display reconfigure" to "a 14-minute spin".
*Fix:* remove `GeometryReader` from the scroll wrapper. Set the bubble width through `.containerRelativeFrame(.horizontal)` on the row, or measure the container's width once into `@State` via `onGeometryChange` and stop threading it into every `MessageRow` as a parameter that changes on every geometry tick.

**P0-3. An image is decoded on every `body` re-evaluation (no cache).** *(confirmed by local data — §0.1)*
`attachment.data` base64-decodes the entire string on every access ([ChatModels.swift:30-34](../Cuate/Models/ChatModels.swift#L30)), and `AttachmentPreviewBubble.body` touches `attachment.data` + `NSImage(data:)` with no cache: [MessageRow.swift:373-390](../Cuate/Views/MessageRow.swift#L373). Every re-layout/hover of a multi-megabyte image is a full re-decode. In the re-layout storm from P0-1, that is precisely the expensive loop iteration.
*Fix (invisible to UX):* cache the decoded `NSImage` in `@State`/by `attachment.id`; never call `attachment.data` inside `body`.

**P0-2 (optional / dropped). A render size limit for a single message.**
`MarkdownBlocksView.parse` splits text into blocks with no upper bound: [MarkdownBlocksView.swift:181-305](../Cuate/Views/MarkdownBlocksView.swift#L181). This only matters if the user really has megabyte-sized *text* messages — there are none on the developer's machine (§0.1). It is the only *visible* change ("Show all"), so by default we **do not implement it**; if it is ever needed, the threshold is high enough (~50 KB) never to fire in normal use.

### P1 — architectural gaps (data and sessions)

**P1-1. User attachments are always written as inline base64 into the same JSON.**
`attach()` stores `base64: data.base64EncodedString()` with no file backing: [ChatWindow.swift:993-999](../Cuate/Views/ChatWindow.swift#L993). The file-backed path (`fileURLString`) is supported by the model but used **only** by ImageAddon: [ImageOperations.swift:252](../Cuate/Addons/ImageAddon/Core/ImageOperations.swift#L252). Inline images are exactly what bloats the user's `chat.json` to 22 MB. Every load decodes the whole file; every save re-encodes all that base64.
*Fix:* write user/pasted images to disk too (`images/<uuid>`) and keep only `fileURLString` in the JSON. That solves both the bloat and the cost of save/load.

**P1-2. Every save/merge rewrites the whole conversation.**
`scheduleSave`/`flushPendingSave` encode all of `messages`: [ChatModels.swift:455-494](../Cuate/Models/ChatModels.swift#L455). `mergeMessage`/`deleteConversationData` **read and rewrite the entire file** for the sake of one message: [ChatModels.swift:269-312](../Cuate/Models/ChatModels.swift#L269). For a 22 MB conversation, delivering a single background reply means reading + writing 22 MB. O(history) per mutation.
*Fix (strategic):* move to SQLite/SwiftData/Core Data with per-row storage and windowed fetching; keep media outside the database. That also removes "22 MB parsed into objects at startup".

**P1-3. There is no conversation list; "New chat" is destructive and irreversible.**
`startNewChat → clearMessages` immediately deletes the messages **and the media files**, with no archive/undo/confirmation: [ChatWindow.swift:632](../Cuate/Views/ChatWindow.swift#L632), [ChatModels.swift:547-567](../Cuate/Models/ChatModels.swift#L547). The code even contains "padding so a misclick doesn't wipe the chat" ([ChatWindow.swift:135](../Cuate/Views/ChatWindow.swift#L135)) — an admission of the risk. Against the industry (ChatGPT/Claude/Telegram all keep past conversations) this is a notable UX/architecture gap.
*Fix:* on "new chat", archive the current conversation as a separate session (a conversation list in the sidebar) instead of wiping it. At minimum: a confirmation/undo, and don't delete the media immediately.

### P2 — render performance and small things

**P2-1. `parse()`/`renderMarkdown()` are called inside `body`.**
[MarkdownBlocksView.swift:23-24](../Cuate/Views/MarkdownBlocksView.swift#L23), [MessageRow.swift:293-339](../Cuate/Views/MessageRow.swift#L293) — a re-parse on every body re-evaluation (every geometry tick, every stream flush of a growing bubble). For a stream that is `O(answer²)`/sec (coalescing only bounds it, it doesn't remove it).
*Fix:* memoize the parse by an `id+text` key (a cache outside body / precomputed in the row's model).

**P2-2. `Block.id { UUID() }` — a fresh UUID on every access.**
[MarkdownBlocksView.swift:20](../Cuate/Views/MarkdownBlocksView.swift#L20). It is harmless today only because `ForEach` uses `id: \.offset`. A latent footgun — any switch to `id: \.id` would mean total identity loss on every frame.
*Fix:* remove the computed `UUID()` (a stable index/content hash).

**P2-3. `.fixedSize(horizontal:false, vertical:true)` on every `MarkdownText`.**
[MessageRow.swift:295](../Cuate/Views/MessageRow.swift#L295). It forces a full height measurement — during a full re-layout that multiplies the cost on tall blocks.
*Fix:* estimate height lazily where possible; for very long content it goes hand in hand with P0-2.

**P2-4. An autoscroll nitpick.** A number of timings on `DispatchQueue.main.asyncAfter(0.05/0.1)` for scrolling after layout ([ChatWindow.swift:244](../Cuate/Views/ChatWindow.swift#L244), [262](../Cuate/Views/ChatWindow.swift#L262)) — pragmatic but fragile. Not a defect, but a candidate for moving to explicit layout signals. `visibleCount` isn't reset on `startNewChat` (cosmetic: `suffix` bounds it anyway).

---

## 4. The hang mechanism — the final cause-and-effect chain

```
A conversation with 1+ very large messages (inline images + long markdown → a 22 MB chat.json)
  └─ the large messages fall into the window of the last 30 (or the user scrolled up)
      └─ each such message = a huge subtree: parse() → thousands of blocks,
         each a Text with .fixedSize + .textSelection  →  tens/hundreds of thousands of DisplayList.Items
          └─ the external monitor woke up (unified_log 22:23:28, displaySetChanges=3)
              └─ the window geometry changed → GeometryReader recomputed geo.size.width
                  └─ maxBubbleWidth changed → the bodies of ALL visible rows were invalidated
                      └─ SwiftUI re-places LazySubviewPlacements / updatePrefetchPhases
                         over _ContiguousArrayStorage<DisplayList.Item> with growth reallocation
                          └─ O(n²) copying + ARC retain/release  →  5.9 GB MALLOC_SMALL,
                             the main thread at 99.7% for 14 minutes, never finishing
```

The mechanism (quadratic re-placement) is as in the README; the **cause** is the size of a single message + `GeometryReader`, not the absence of windowing.

---

## 5. An "industry" assessment (scorecard)

| Subsystem | Grade | Comment |
|---|---|---|
| Autoscroll / follow / near-bottom | 🟢 Good | Well thought out, with an intent monitor and a fallback |
| Streaming / chunk coalescing | 🟢 Good | The store isn't republished per token |
| Context (summary + sliding window) | 🟢 Good | In line with practice |
| I/O concurrency (serial queue, generations) | 🟢 Good | The races are closed |
| Background reply delivery on switch | 🟢 Strong | Non-trivial and correct |
| Rendering a single message | 🔴 Weak | No size bound; the GeometryReader amplifier (P0) |
| Storage (monolithic JSON, inline base64, full rewrite) | 🟠 Below practice | Doesn't scale (P1) |
| The session model / conversation history | 🟠 A gap | No conversation list; a destructive "new chat" (P1) |

---

## 6. The recommended plan (by impact/cost)

**Urgent (removes the hang):**
1. **P0-1** take `GeometryReader` off the scroll root; set the bubble width through `containerRelativeFrame`/a one-time measurement. *(small changes, large effect)*
2. **P0-2** fold over-long messages and code blocks behind "Show all". *(medium changes)*

**Medium term (robustness and scale):**
3. **P1-1** user attachments onto disk, only a reference in the JSON. *(removes the chat.json bloat)*
4. **P2-1** memoize markdown parsing by `id+text`.
5. **P1-3** a conversation list + a non-destructive "new chat" (archiving, confirmation/undo).

**Strategic:**
6. **P1-2** migrate storage to SQLite/SwiftData with windowed fetching; finish the "one file per conversation" scheme and kill the monolith.

**Don't spend time on:** "history windowing" — it already exists; micro-optimizing app code in the hot path — there is barely any of it there (the spin is entirely inside SwiftUI/AttributeGraph).

---

## 7. What is worth verifying empirically (repro)

1. Take the user's `chat.json` (or synthesize a conversation with 1–2 messages of ~2–5 MB of markdown/inline images).
2. Open the panel and wait for layout.
3. Change the geometry: connect/wake an external monitor, or resize the window / go fullscreen / Mission Control.
4. `sample Cuate 5` during the freeze — expect the same stack (`LazySubviewPlacements` / `updatePrefetchPhases` / `_consumeAndCreateNew`).
5. Repeat after the P0-1 fix (removing GeometryReader) — a geometry change should stop touching every row.

---

## 8. Implementation status (version 3.3, 2026-07-18)

Storage moved from monolithic JSON to SwiftData (`ChatPersistence.swift`); on top of that a
second audit round found and closed 12 more defects. Item by item:

### From the original plan (§6)
- ✅ **P0-1** GeometryReader is off the scroll root — the width comes from a background probe (`bubbleContainerWidth`), persisted across launches.
- ✅ **P0-3** image decoding: a cache by id (`AttachmentImageCache`) + **async decoding off main + downsampling through ImageIO** (previews ≤1600 px) + a 128 MB cost limit.
- ✅ **P1-1** all attachments are file-backed (`ChatAttachment.fileBacked`); the paths in the database are **relative** (legacy absolute ones are resolved).
- ✅ **P1-2** SwiftData: a per-row reconcile save instead of a full rewrite; **windowed loading** (the last 120 + everything after the summary boundary, `fetchOffset`), with pages loaded from the database as you scroll up.
- ✅ **P2-1** markdown: the block parse is cached + **inline render memoization** (`MarkdownText.renderCache`).
- ⏸ **P1-3** the conversation list — not done (deliberately deferred); the risk is partly closed: "new chat" now cancels the in-flight stream (the reply no longer resurrects).

### The second round (found during the 3.3 audit)
1. ✅ Saves are gated until history loading completes (a stale snapshot can no longer wipe the conversation on disk); early messages during a switch are merged in.
2. ✅ An origin guard on the rolling summary — a summary that finishes generating after a switch goes into its own conversation (`updateSummary` into the dormant store) rather than someone else's.
3. ✅ A max latency on the save debounce (5 s) — streaming no longer starves persistence; flush + queue drain on `willTerminate`.
4. ✅ `@StateObject` instead of `@ObservedObject` for `ChatStore` in `ChatWindow`.
5. ✅ ImageAddon delivery through `deliver(_:to: origin)` — an operation's result arrives in the chat that started it.
6. ✅ "New chat" cancels its own chat's stream; `syncToStore` doesn't write a partial after cancellation.
7. ✅ Migration v2: inline base64 out of SwiftData strings → `images/` files (one-shot, with a retry on write failure).
8. ✅ Windowed loading from the database (see P1-2) — `windowStart`, `loadOlderPage`, window-aware `sync`/`clearMessages`/compression.
9. ✅ Async decode/downsample (see P0-3), with a placeholder while decoding.
10. ✅ NSCache with a real cost limit.
11. ✅ Wheel-up over non-scrollable content no longer disables auto-follow (`trackContentFits`).
12. ✅ The initial bubble width is persisted — no double layout on first appearance.

Smaller things: a cached DateFormatter in `MessageRow`; `merge` carries attachments/audio; a fallback for `ModelContainer`
(retry → in-memory) instead of `try!`; hardcoded panel strings localized; monitors removed in `onDisappear`;
dead code deleted (`appendChunk`, `handledAutoStopToken`); media retention executed on the store side
(covering rows outside the window too); the `CUATE_DATA_DIR` test hook for the e2e sandbox.

**The text retention policy:** messages are never deleted (media follows `mediaRetentionDays`);
the window is only about what is loaded into memory.

**E2E:** a harness on the real `ChatModels`/`ChatPersistence` (46 checks: migrations, windowed load/sync,
merge, retention, early send, switches, the origin guard, max latency) + an app-level smoke test of the upgrade
from 2.13 (JSON → SwiftData → external files) — all green.

## 9. In development — version 3.4 (2026-07-19, unreleased)

### A new provider: Kimi (Moonshot)
- `case kimi` in `ProviderID` + an `OpenAICompatibleProvider.kimi` instance (`https://api.moonshot.ai/v1`) — no
  new class, modelled on Mistral/DeepSeek; registered in `ProviderRegistry`.
- The model list is a live `GET /v1/models` (a dropdown, as with OpenAI); vision is on, the reasoning selector is
  off (Kimi's thinking is built into the model). The current models: `kimi-k3`, `kimi-k2.6`, `kimi-k2.7-code`.
- The `Provider-kimi.imageset` logo (a monochrome SVG, template); a link to the keys at
  `platform.moonshot.ai/console/api-keys`; a line in the onboarding.

### Artifacts (HTML + Markdown) — `Views/ArtifactView.swift`
- The Anthropic path (a prompt convention, NOT a function tool): the rules live in `AppSettings.mandatoryPromptRules` —
  interactive → one self-contained HTML document in an ```html fence; a document deliverable (README, article…) →
  the full document in a ````markdown fence (4 backticks, so inner ```-blocks don't break the outer fence).
  It works with any provider, including OpenRouter's non-tool models; the content streams.
- The parser (`MarkdownBlocksView.parse`): the fence language; CommonMark fence closing (a closing line is
  backticks only and no shorter than the opening one → nested ``` inside ````markdown stay content); the
  `.artifact(kind:content:complete:)` block, with `complete=false` while the fence is still streaming.
- The `ArtifactCardView` card: an icon (globe/document), a title from `<title>` / the first `#` heading, and the
  size; while streaming, a spinner reading "Building the page…". A real `Button(.plain)` with
  `.textSelection(.disabled)` inside — otherwise clicks over the text were intercepted by the bubble's selection.
  Styled through `ThemePalette` (the glass branch + codeFill/accent/primaryText/fontDesign).
- The preview window (`ArtifactPreview`): a single reusable floating window, always ⅔ of the screen and centered.
  HTML gets a WKWebView (JS enabled, a non-persistent store, `loadHTMLString`); Markdown gets our own
  `MarkdownBlocksView(style: .document)` render in a notion-style column (≤720pt). Preview/Code tabs; the
  Copy / Open in browser (HTML only, through a temp file) / Save… (NSSavePanel) buttons.
- Editing a document: the model must resend the FULL document as a new card (a rule in the prompt;
  fragments/diffs are forbidden — pinpoint find/replace is fragile on weaker models). Version history comes free:
  older cards in the feed remain openable.
- Retention: HTML/MD are part of the message text in SwiftData, with no separate storage; only an explicit
  export (NSSavePanel) and the temp copy for the browser (cleaned by the system) ever hit disk.

### Markdown rendering — extending the block parser
- New blocks: checkboxes `- [ ]`/`- [x]` (SF Symbols, checked ones dimmed), ordered lists
  `1.`/`1)`, and dividers `---`/`***`/`___`.
- Two typography styles: `.chat` (as before) and `.document` for the preview (H1 23pt / H2 18pt / H3 15.5pt,
  14pt text, larger margins).

### A themed activity indicator — `Views/ThinkingIndicator.swift`
- `ThinkingEqualizer` (the "mini equalizer" variant): 5 bars in a wave, colored from `palette.dictationColors`
  (cycled) or the accent — one visual language with the dictation window.
- It replaced the system `NSProgressIndicator` in all 4 places in the chat panel: the "Thinking…" pill, the artifact
  card while generating, loading older messages, and the image-decode placeholders. Settings and utility
  windows kept the native spinner.

### Model context and agent memory — an audit and 5 fixes (2026-07-19)

An audit of the "system prompt → history → compression → caching" chain found an imbalance: savings
were achieved with a small window (6k tokens) while caching effectively didn't work, which made the
grounding losses worse. What was implemented:

1. **Prompt caching for Anthropic** (`AnthropicProvider.swift`). At Anthropic the cache is explicit only —
   previously `cache_control` was only set on a system prompt longer than 8000 characters (a typical preset is
   shorter → there was no cache at all), and messages were never cached. Now there are two breakpoints: system
   (stable through the day — a date without the time) and the last messages content block, which caches the whole
   conversation prefix so the next turn re-reads it at ~10% of the input price. The threshold is gone: a prompt
   shorter than the cacheable minimum simply isn't cached, which is not an error. A nuance: a cache write costs +25%,
   the TTL is 5 min — one-off questions with >5 min pauses get slightly pricier, a live dialogue much cheaper.
2. **Script-aware token estimation** (`ChatService.estimatedTokens`). A flat `chars/4` underestimated
   Cyrillic by ~half (it is really ≈2.5 chars/token) — compression fired at 9–12k instead of 6k.
   Now it is ASCII/4 + non-ASCII/2.5; the estimate also includes attachment OCR content, which does go into the request.
3. **The compression threshold 6,000 → 24,000 tokens**, the verbatim tail 8 → 12 messages. Deliberately
   generous: with caching (explicit at Anthropic, implicit at OpenAI/Gemini/DeepSeek) a long
   verbatim prefix is cheap, and verbatim always beats a retelling.
4. **Grounding: `ocrText` + `toolContext`** (new optional columns `SDAttachment.ocrText`,
   `SDMessage.toolContext` — a lightweight SwiftData migration, with the fields also added to the Codable `ChatMessage`/
   `ChatAttachment` with JSON backward compatibility).
   - OCR is computed once and persisted on the attachment; older images enter the context as
     extracted text (capped at 4000 chars) instead of an empty "attached earlier" note; lazy
     back-OCR of old attachments is limited to ≤3 calls per turn; a retry no longer pays for OCR twice.
   - A digest of `web_search` results (capped at 6000 chars) is stored on the reply (`toolContext`,
     not rendered in the UI) and injected into the context for the most recent reply that has one — a follow-up
     about the sources is no longer blind. The `ChatEvent.toolContext` event fires at the end of a turn.
   - `reconcileAttachments` also compares `ocrText`, not just IDs — otherwise lazy OCR would never
     reach the disk; `merge` carries `toolContext` across.
   - OCR content also goes into the summarization transcript — image contents don't vanish
     when they cross the summary boundary.
5. **Compression without degradation** (`compressHistoryIfNeeded`). A merge prompt instead of "retell it
   from scratch": Facts / Decisions / User preferences / Open tasks sections, an explicit ban on losing
   unsuperseded items from the previous summary, the cap raised 300 → 600 words, maxTokens 1024 → 2048.
   Previously a summary-of-summary washed early facts out with each compression.

The `ChatService.streamReply` signature gained a `store:` parameter (write-back of lazy OCR).
Deferred (see TECH-DEBT): a cheap model for summarization, the tool loop breaking on the 4th iteration,
dedup of repeated searches, cross-chat memory about the user.

**E2E (2026-07-19):** the harness was rebuilt (the real `ChatModels`/`ChatPersistence`, the
`CUATE_DATA_DIR` sandbox): seed the store with the 3.3 schema code from HEAD → open it with the new schema.
25 checks: the lightweight migration (message/summary/attachment integrity, new columns = nil),
an `ocrText` round trip with unchanged attachment IDs, `toolContext` through sync and merge (insert +
update with no duplicates), JSON compatibility (the old format decodes, new keys are omitted when
nil), `updateSummary`, and stability on reopening — all green. The 3.4 DMG build is fine.

### Miscellaneous
- The versioning revision rule: one bump per release cycle (3.3 released → all development goes under 3.4).
- E2E before release: artifacts (an interactive HTML, an MD document with checkboxes/code blocks, editing a document),
  the Kimi provider (key → model list → chat/vision), the equalizer on glass and on a multicolored theme.

## §10. The transcript engine (3.20, 2026-07-25)

The SwiftUI chat container (ScrollView + LazyVStack + ScrollViewReader) was replaced with an AppKit engine in
`Views/Transcript/` — modelled on production chat clients:

1. **Pinpoint updates.** `TranscriptEngineView.apply(items:)` reconciles rows by id/revision
   (`CollectionDifference`): a changed row only swaps its own `NSHostingView.rootView`,
   and insertions/removals don't touch the neighbours. The bubbles stayed SwiftUI (themes and markdown unchanged).
2. **Our own offset.** Scrolling is a number, set synchronously after `layoutSubtreeIfNeeded`;
   the whole class of "scrollTo on an unrendered id silently no-ops" bugs and the five `asyncAfter` retries are gone.
3. **Pin-to-bottom as an invariant** (not an animation): every document-height change while the pin is
   active returns to the bottom instantly. Hysteresis 44/8 pt; a wheel-up is a reading gesture and
   detaches until the next explicit return. Backfill is compensated by an anchor row.
4. **Streaming outside the list.** The live reply goes into `StreamingReplyModel` (frozen segments
   parsed exactly once + a short tail) — a flush became O(chunk) instead of O(answer²), and the rate
   went from 8 to 30 Hz; smoothness comes from small steps, without animations. The store gets checkpoints
   at ~1 Hz (crash resilience) and a final upsert; a mask hides the store copy while the
   live row exists.
5. **Switching conversations mid-stream**: the live bubble reattaches on return, the Thinking pill is
   restored (a switch clears isLoading/statusText — ChatWindow remembers and restores them), and delivery
   into a dormant conversation works as before, through a merge into the file.

E2E (2026-07-25, the `CUATE_DATA_DIR` sandbox, Ollama gemma4): rendering/persistence/restart,
the send path, the local model's confirm bubble, a live stream with markdown and a code block, summon cycles.
Rollback point: snapshot `18e5f47`.

## §11. Cycles 4.2–4.4.2 (2026-07-26…28) — agent chats and scrolling at full FPS

The chronicle after 4.0 (the Hermes addon, see the release notes of the respective versions):
4.2 — files to the agent (a courier through the dashboard for a remote gateway), second-level
step details, pinned messages; 4.2.1 — summoning WorldTime over
fullscreen apps; 4.3 — a one-click launchd service for the local gateway; 4.4 —
images to the agent across devices, the context gauge, and the victory over duplicate
bubbles (three causes: syncing during a turn, `[screenshot]` placeholders,
the split of interim segments; the gateway's text was declared authoritative —
`.replaceText`).

The chat engine in 4.4.2 (profiled on live agent chats):

1. **Per-row render caches.** Heavy agent rows (ANSI output, diffs, chips)
   are parsed and laid out once; history pages are loaded in small
   portions ahead of time — a prepend never happens "under your finger".
2. **A live-row window of ~120 + a pool.** Rows that fall out of the window are parked and, on
   scrolling back, return ready-made (Telegram-style mechanics) — with no
   NSHostingView recreation.
3. **The system panel shadow is disabled** — a transparent window made macOS
   recompute the shadow on every scroll frame (the compositor halved the FPS).
   To bring it back: `defaults write com.getcuate.Cuate CuateDebugPanelShadow -bool YES`.
4. **The session sidebar is a separate child window**, docked on the left: the chat window
   doesn't resize when the column opens, and the transcript isn't re-laid out.

## §12. Cycle 4.5–4.5.1 (2026-07-28) — Plaud, chat files, and the stream-freeze fix

1. **The `.attachments([ChatAttachment])` event** in `ChatService.ChatEvent`:
   tools can attach file chips to a reply. ChatWindow buffers them
   until `deliver` (the bubble isn't materialized yet at tool-call time) with dedup
   by `fileURLString`. The first consumer is PlaudAddon (docs/plaud-addon.md).
2. **The live-bubble freeze while generating artifacts — eliminated.**
   `StreamingReplyModel.freezeIfPossible` on an unclosed fence iterated over ALL
   the tail's blank lines and, for each, copied and scanned the whole tail: O(n²)
   on main on every flush — an 11 KB HTML artifact froze the UI until the stream
   ended (neither the text nor the "generating" card was drawn, while chunks
   kept arriving — 3.4k chunks in the log). The fix: a single linear pass finds the start
   of the first unclosed fence, and the freeze-boundary search is clamped to it.
   Diagnostics in case it recurs: `live.unarmed …` in flush() — a live row that
   wasn't armed at materialization renders on the ~1 Hz checkpoints.
3. **A "Chat files" panel for ordinary chats** (`LocalChatFilesView`): artifacts
   from fences (through the parser cache — a rescan is free), Plaud recordings,
   and the user's attachments; open / reveal in Finder.
4. **Preview windows** (artifacts and Plaud): `.canJoinAllSpaces, .fullScreenAuxiliary`
   — they open on the current screen/space instead of invisibly on the desktop.
5. **The type-checker limit on ChatWindow's body**: the root body's modifier chain is
   at its limit — one more `.onReceive` fails compilation with a timeout
   ("unable to type-check in reasonable time"). New listeners must be hung on
   inner, always-mounted views (example: `RecordingStatusView`).
6. **4.5.1 — self-healing the Hermes model lock**: model slugs go stale
   (OpenRouter rotates its free tier), and a session with a dead lock 404'd on every
   send. Validation: the global default — during the gateway probe and in
   `resolveLockPair`; the per-session lock — `healSessionLockIfStale` before
   sending into an existing session (a re-lock onto the agent's current default +
   a system row in the chat).

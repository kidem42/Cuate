# Cuate — architecture map

**Code version:** 5.0 · **Date:** 2026-09-04
**Purpose:** the index of what already exists. Read it before planning any
change, so a new feature reuses the seams the app already has instead of
re-inventing them. The code is the source of truth; this file says WHERE to
look and WHICH rule applies. When a subsystem is added or a rule changes,
update this file in the same commit (see `AGENTS.md`).

Companion documents: `docs/provider-integration-playbook.md` (a new LLM
provider), `docs/addon-tool-playbook.md` (a new client-side tool),
`docs/THEMING-CHECKLIST.md` (a new theme), `docs/documents-in-chat.md`,
`docs/plaud-addon.md`, `docs/hermes-vps-setup.md`, the in-folder READMEs of
`Addons/LayoutFix` and `Addons/ImageAddon`, and
`docs/chat-architecture-review.md` (historical: the 2.13 audit plus per-cycle
notes up to 4.5).

All paths are relative to the repository root; Swift sources live under
`Cuate/`.

---

## 1. Process model and startup

Cuate is a status-bar app (`NSApplication` activation policy `.accessory`)
with floating panels, not a document app with windows:

- **Entry:** `App/CuateApp.swift`. `AppLauncher.main` runs
  `LegacyRenameMigration` (the AISpotlight → Cuate carry-over of the data
  folder, preferences domain and Keychain service) BEFORE any settings are
  touched, then starts the SwiftUI `App`. `AppDelegate` owns the status-bar
  menu, the panels, hotkeys and the app-level lifecycle.
- **Panels:** `App/FloatingPanelWindow.swift` hosts the chat (`Views/ChatWindow.swift`)
  and the World Time grid. Panels are created at launch while the policy is
  `.accessory`; a window created after the Settings window switched the app
  to `.regular` loses the ability to join all Spaces (comment at
  `makeWorldTimePanel`). The panel hides on focus loss unless pinned.
- **Startup order** (`applicationDidFinishLaunching`): remote-file janitor
  drain → diagnostics → holiday theme manager → `PermissionHealer` →
  Keychain warm + model-list warm (off the main thread) → World Time panel →
  hotkeys → `LayoutFixAddon.start()` → `ImageAddon.start()` → Plaud session
  upkeep → `NotificationService.activate()` → (after the key warm) notification
  permission and `HermesAddon.startBackgroundPolling()`. Persistence migrations
  and the media-retention pass run from `ChatStore.init`.
- **Status-bar menu:** open panel, full/area screenshot, World Time (when the
  addon is on), dictation and translated dictation (when enabled), LayoutFix
  auto-switch toggle and settings (when enabled), a Local models submenu (when
  enabled), Settings, "follow mouse", Appearance.
- **Hotkeys:** `App/HotkeyManager.swift` + `App/HotkeyCombo.swift` (Carbon
  key codes). App hotkey ids 1–5: toggle panel ⌘⇧Space, full screenshot ⌘⇧S,
  area screenshot ⌘⇧D, dictation ⌥Space, translated dictation ⌥⇧Space. The
  addons own their own combos: World Time ⌥⇧T (`WorldTimeSettings`),
  LayoutFix ⌃⌥F / ⌃⌥G on ids 901/902 (`LayoutFixSettings`). Recorded through
  `Views/ShortcutRecorderView.swift`.
- **Onboarding:** `Views/OnboardingView.swift` + `OnboardingScenes.swift` —
  five animated scenes, shown on first launch, reopenable from Settings →
  General. `Views/OnboardingShotExport.swift` is a DEBUG-only CLI flag
  (`--onboarding-shots <dir>`) that renders the scenes to PNGs. The mockups
  live in `design/onboarding/`.

## 2. Directory map

```text
Cuate/
├── App/            entry + delegate, panels, hotkeys, dictation, selection capture,
│                   screenshots, terminal runner, notifications, TCC healing,
│                   localization table, rename migration, Config constants
├── Diagnostics/    opt-in log + breadcrumbs + hang/CPU watchdog
├── Models/         ChatModels (ChatAttachment, ChatMessage, ChatStore),
│                   ChatPersistence (SwiftData), SpendLedger
├── Providers/      LLM providers, STT, OCR, web search/fetch, OpenAI Files,
│                   documents (pre-flight, extraction, read_document tool),
│                   AppSettings, APIKeyStore, PricingCatalog, ChatService
├── Views/          chat window, message rows, markdown, artifacts, mermaid,
│                   themes, settings, onboarding, voice UI, costs
│   └── Transcript/ AppKit transcript engine (scroll, streaming row, live pill)
├── Addons/         LayoutFix, ImageAddon, CalendarAddon, WorldTimeAddon,
│                   PlaudAddon, HermesAddon, AgentGateway/Core (shared agent UI)
├── Resources/      mermaid.min.js (bundled renderer)
└── Assets.xcassets provider glyphs (Provider-<name>), app icon, Plaud wordmark
android/            Kotlin/Compose companion app (own README + make-apk.sh)
hermes-plugins/     Python tools installed INTO a Hermes agent (plaud/)
shared/fixtures/    JSON fixtures for cross-platform text contracts
design/             brand system (design/brand) and onboarding mockups
docs/               what is implemented: maps, playbooks, feature docs, guides
scripts/            make-dmg.sh, contract tests, n-gram table generator
private/            gitignored internal notes; never referenced from public docs
```

## 3. Data and storage

**Data directory:** `~/Library/Application Support/Cuate/` (`ChatStore.baseDirectory`).
The `CUATE_DATA_DIR` environment variable redirects the whole persistence
layer to another directory (an e2e-harness hook; a `HOME` override does NOT
move `applicationSupportDirectory`). Inside:

| Item | What |
|---|---|
| `CuateChats.store` | SwiftData: `SDConversation` → `SDMessage` → `SDAttachment` (`Models/ChatPersistence.swift`) |
| `CuateSpend.store` | SwiftData spend ledger (`Models/SpendLedger.swift`) |
| `images/` | every file-backed attachment payload: images AND documents (`ChatAttachment.fileBacked`) |
| `Recordings/` | voice-message audio |
| `PlaudNotes/` | Plaud recording cache (meta JSON + Markdown per tab) |
| `pricing-cache.json` | weekly LiteLLM price refresh (`PricingCatalog`) |
| `Logs/` | diagnostics: rotating `app.log`, `app.log.1`, hang reports (this path ignores `CUATE_DATA_DIR`) |
| `chat*.json.migrated` | backups of the pre-SwiftData JSON history |

**Conversations.** `ChatStore.ConversationID`: `.general`, `.preset(name)`
(an isolated preset keeps its own history), `.agent(addon, agent, session)`
(one store per gateway session). Storage keys are SHA-256 stems of the name.

**Windowed loading.** `ChatPersistence.load` materializes the newest
`initialWindowCount` (120) rows plus everything the rolling summary does not
cover; `ChatWindow` renders `historyPageSize` (30) at a time and pages older
rows in on scroll (`ChatStore.loadOlderPage`). `ChatStore.messages` is a
contiguous SUFFIX of the conversation; `windowStart` is its absolute offset.
Anything that walks `messages` (search, inventories, chips) sees only the
loaded window.

**Saving.** `ChatStore.scheduleSave` debounces into `ChatPersistence.sync`,
a reconcile of the loaded window against the store (upsert present, delete
absent, scoped to `sortIndex >= windowStart`). Attachments are compared by
id plus their lazily written fields (`reconcileAttachments`); a new
lazily-written column must be added to that key or it never persists.
`flushPendingSave` + `waitUntilDrained` run on quit.

**Retention.** `Config.mediaRetentionDays` (15): at launch,
`applyRetentionToAllConversations` deletes attachment files and recordings
older than the window from EVERY conversation (rows keep their text; an
image-only message gets the "media expired" stub), then `sweepOrphanedMedia`
removes files under `images/` and `Recordings/` that no row references
(1-hour grace). Provider-side document copies are released through
`RemoteFileJanitor` at the same points (§5).

**Migrations** (all one-shot, flagged in UserDefaults):
`migrateFromJSONIfNeeded` (JSON → SwiftData, JSON kept as `.migrated`),
`externalizeInlineMediaIfNeeded` (inline base64 → files),
`LegacyRenameMigration` (app rename), and per-setting migrations inside
`AppSettings.init` (a new setting with a new default must not silently change
existing users' behavior — migrate from indirect evidence).

Schema changes: `SDMessage`/`SDAttachment` gain OPTIONAL columns only
(lightweight migration); mirror them in `toSDMessage`/`toStruct`, in the
`ChatMessage`/`ChatAttachment` Codable keys, and in the Android Room schema
when the field crosses devices.

## 4. A chat turn, end to end

1. `ChatWindow.sendMessage` — ImageAddon slash commands (`/upscale`, `/bg`,
   `/cleanup`) act on the pending attachment instead of sending; the
   captured selection becomes a `>` blockquote (`SelectionGrabber.message`);
   agent roles route files through `HermesFileCourier`; a local model that is
   not loaded asks for confirmation first; then `performSend`.
2. `ChatWindow.streamAssistantReply` — one code path for provider and agent
   turns. Owns `streamSlots` (one in-flight stream per conversation, so a
   switch mid-turn keeps streaming), the round loop for the `<continue/>`
   marker (a hidden "Continue." user turn is appended to the REQUEST only),
   `StreamingReplyModel` flushes at 30 Hz (8 Hz inside a long open fence),
   persistence checkpoints, delivery to the store, and finally
   `ChatService.compressHistoryIfNeeded`.
3. `ChatService.streamReply` (`Providers/ChatService.swift`):
   - key from the warmed `APIKeyStore`; model from `AppSettings.selectedModel`;
   - system prompt = the active preset text + `AppSettings.mandatoryPromptRules`
     (copy formats, artifact/mermaid/markdown-document fences, the `<continue/>`
     contract) + the rolling summary + today's date (date only, so the prefix
     stays cacheable);
   - tools, each behind `AppSettings.modelSupportsTools`: web (`BraveSearchService`
     when a Brave key exists, `WebFetchService` always), calendar, Plaud,
     `read_document` — specs and prompt hints under ONE condition each, so an
     unavailable tool costs zero prompt bytes (`docs/addon-tool-playbook.md`);
   - the agent loop: up to `AppSettings.maxToolIterations` (default 4) tool
     rounds; on exhaustion the model gets a budget notice and one final turn;
     web results feed `toolDigest` → `.toolContext` (stored on the reply,
     re-attached to the request for the most recent reply only);
   - `.usage` from the provider → `recordSpend` (estimate flagged when the
     stream broke).
4. `ChatService.buildMessages` turns `ChatMessage` history into `LLMMessage`s:
   images ride as pixels only on the last user message (downscaled copy,
   `LLMImage.forModel`); older images contribute their cached OCR text
   (`ChatAttachment.ocrText`, lazily computed with a budget of 3 per turn);
   a non-vision model gets OCR text instead of pixels; documents ride in full
   on the attach turn and as a one-line placeholder afterwards
   (`docs/documents-in-chat.md`); the last reply's `toolContext` is
   re-attached.
5. **Rolling summary** (`compressHistoryIfNeeded`): when the verbatim history
   exceeds `compressionTokenThreshold` (24,000 estimated tokens, script-aware
   estimate: ASCII ÷ 4, other scripts × 2/5) and more than `keepRecentCount`
   (12) + 4 messages are active, older turns are merged into running notes
   (Facts / Decisions / User preferences / Open tasks) by the current chat
   model and billed as `SpendKind.summary`. UI messages stay; only the API
   context shrinks (`summaryCoversCount` is an absolute index).

**`ChatService.ChatEvent`** (service → window): `.text`, `.status` (the
thinking pill), `.toolContext`, `.attachments` (tool-produced chips),
`.replaceText`, `.agentSteps`, `.agentStepsLive`, `.agentApproval` (the last
four are agent turns). Adding a case touches `ChatWindow.streamAssistantReply`
and `AgentChatService`.

**`LLMStreamEvent`** (provider → service): `.text`, `.reasoning` (DeepSeek
thinking text, kept only to echo back inside a tool loop), `.toolCalls`
(once, at the end), `.usage` (once, before finish). `ChatService` is the
only consumer.

## 5. Attachments

`ChatAttachment` (`Models/ChatModels.swift`): id, filename, mimeType, either
inline `base64` or a `fileURLString` RELATIVE to the data directory, `ocrText`
(cached text of the payload: OCR for images, extraction for documents),
`remoteFileID`/`remoteProvider`/`remoteExpiresAt` (provider-side copy),
`pageCount` (PDF). `isDocument` classifies by MIME through
`DocumentPreflight`.

| Kind | Enters through | Stored | Reaches the model as |
|---|---|---|---|
| Image | paperclip (`presentAttachOpenPanel`, a sheet of the panel), ⌘V (`handleImagePaste`: file URL, raster, NSImage), drag & drop onto the panel (`handleFileDrop` → `acceptPickedFile`), screenshot hotkeys (`ScreenshotCapturer` → `AppState.pendingAttachment`), ImageAddon results | `images/` | pixels on the last user message; OCR text otherwise |
| Document (pdf, docx, doc, pptx, xlsx, xls, txt, md, csv, json, rtf) | paperclip, drag & drop (ordinary chats only), "attach again" from the chat-files popover; a byte-identical file (`contentHash`, SHA-256 at attach time) inherits the twin's provider-side id and cached text | `images/` | OpenAI: `input_file` reference; others: extracted text; later turns: `read_document` |
| Voice message | mic button (`AudioRecorder`, `Config.maxVoiceRecordingDuration` 20 min) → `TranscriptionService` | `Recordings/` | the transcript text |
| Plaud chip | produced by `PlaudToolService` on the reply | `PlaudNotes/` | not sent; a preview card |
| Agent file (agent chats) | paperclip / drop → `pendingAgentFilePaths` | not stored | a path note delivered by `HermesFileCourier` (`AgentAttachNote` contract) |

Limits: `ChatWindow.maxPendingAttachments` (5 per message, every route);
`DocumentPreflight`: 3 documents, 50 MB per file and per message, no empty or
password-protected files. Refusals post a system line in the chat, never a
silent drop. HEIC/TIFF are converted to PNG before attaching.

Every payload goes through `ChatAttachment.fileBacked` (inline base64 only if
the write fails). Bubbles render through `AttachmentPreviewBubble`
(`Views/MessageRow.swift`): image → `AttachmentImageCache`, Plaud →
`PlaudNoteChipView`, document → `DocumentChipView`, else a generic file row;
clicks go through `AttachmentOpener`. `Views/LocalChatFilesView.swift` is the
header folder popover of ordinary chats (attached files with their retention
countdown and an "attach again" action for documents, produced artifacts,
Plaud recordings).

## 6. Providers

| `ProviderID` | Implementation | Notes |
|---|---|---|
| `anthropic` | `AnthropicProvider` | Messages API, SSE, tool use, explicit cache breakpoints, `maxTokensCap` |
| `openai` | `OpenAICompatibleProvider.openAI` | Responses API (`/v1/responses`, `store: false`), function tools + reasoning, `input_file` documents |
| `mistral`, `deepseek`, `openrouter`, `kimi` | `OpenAICompatibleProvider.*` | chat/completions; DeepSeek echoes `reasoning_content` inside tool loops; OpenRouter uses manual slugs + a live model catalog with prices |
| `gemini` | `GeminiProvider` | streaming `generateContent`, key in a header |
| `ollama` | `OpenAICompatibleProvider` on the user's endpoint + `OllamaAdminService` (`/api/*`: list, capabilities, pull, delete, load, unload) | no key; `Views/LocalModelsSettingsView.swift` is the console; master switches for local and cloud providers |
| `hermes` | not a chat provider: the agent gateway (`Addons/HermesAddon`) | never in the provider switcher |

Registration: `ProviderRegistry.provider(for:)` in `Providers/AppSettings.swift`.
Capabilities: `ProviderID.supportsVision` (coarse), `AppSettings.modelSupportsVision/Tools/ReasoningControl`
(per model for OpenRouter and Ollama), `ModelCapabilities` (reasoning
heuristics), `ProviderCapabilityHints` (the localized "what this provider
takes" summary shown as tooltips on the key rows and under the chat provider
picker). Per-provider clamps live in `ChatService.streamReply`
(`providerTokenCap`). Errors go through `ProviderError.fromHTTP` (sanitized,
truncated); SSE through `HTTPClient.sseStream`.

Other provider-side services:

| Service | File | Role |
|---|---|---|
| Speech-to-text | `TranscriptionService` (Mistral Voxtral, OpenAI, Deepgram batch), `DeepgramLiveTranscriber` (WebSocket streaming for dictation) | `STTProviderID` |
| OCR | `OCRService` routes to `AppleOCRService` (Vision, on-device, default) or `MistralOCRService` (layout-aware Markdown) | `OCRProviderID`; images only |
| Web | `BraveSearchService` (`web_search`, Brave aux key), `WebFetchService` (`web_fetch`, keyless, client-side) | tools |
| Files | `OpenAIFilesService` (upload/delete), `RemoteFileJanitor` (persisted deletion queue) | documents |
| Documents | `DocumentPreflight`, `DocumentTextService` (PDFKit + Vision OCR + AppKit readers), `DocumentTextQuery`, `DocumentToolService` | `docs/documents-in-chat.md` |
| Pricing | `PricingCatalog` (bundled snapshot + weekly LiteLLM refresh + OpenRouter live) | spend |
| Keys | `APIKeyStore` (one Keychain bundle, in-memory cache warmed off main; `AuxKey`: brave, deepgram, fal, hermes, hermesDashboard, plaud), `App/KeychainHelper.swift` | never in defaults or logs |

Adding a provider: `docs/provider-integration-playbook.md`.

## 7. Settings

`Providers/AppSettings.swift` (`AppSettings.shared`, `@MainActor`,
UserDefaults-backed `@Published` properties): provider/model selection per
provider, reasoning mode, max tokens (cloud and local), tool budget, web
search, hotkeys, dictation (enabled, cleanup on/off, cleanup provider+model,
target language, chunked, streaming, warm minutes, mic), STT/OCR providers,
launch at login, terminal run mode, language, appearance, theme, holiday
themes, prompt presets (built-in + custom, per-preset emoji, switcher
visibility, isolated history, switcher style), agent role.

Addons keep their own settings objects with their own UserDefaults prefixes
(`layoutFix.`, `imageAddon.`, `calendarAddon.`, `worldTime.`, `plaudAddon.`,
`hermes.`) and store nothing in `AppSettings`. Secrets (fal key, Hermes
tokens, Plaud OAuth) go to `APIKeyStore.AuxKey`.

Settings window: `Views/SettingsView.swift`, tabs `SettingsTab`: chat, keys,
voice, general, appearance, prompts, costs, localModels, and one tab per
addon shown only while the addon is enabled (the master switches live in
General).

## 8. UI

- **Chat panel** (`Views/ChatWindow.swift`, ~3.6k lines; its root body is at
  the type-checker limit — hang new listeners on inner views): header with
  the preset/role switcher and the files popover, the transcript, a pinned-
  messages bar (agent chats), the retry button, the attachment card,
  the composer (`CustomTextEditor` with a
  styled quote region, `EnhancedVoiceButton`, agent model/effort control,
  slash autocomplete of agent skills), the thinking pill, drop zone,
  keyboard control (Space / double-Space / Esc).
- **Transcript engine** (`Views/Transcript/`): `TranscriptEngineView`
  (NSScrollView, row-level updates, auto-follow that never yanks a reader
  back), `ChatTranscriptView` (thin SwiftUI bridge), `StreamingReplyModel`
  (the live reply outside the list), `LiveTurnPill` (status + agent step
  journal). Details and the recycling traps: `docs/chat-architecture-review.md` §10–§11.
- **Message rows** (`Views/MessageRow.swift`): bubbles, `CopyableBubble`
  (tap-to-copy formats), `MarkdownText`, attachment bubbles, the ImageAddon
  result bar, timestamps per theme.
- **Markdown** (`Views/MarkdownBlocksView.swift`): block renderer (headings,
  lists, quotes, code cards with ANSI and a ▶ button → `App/TerminalCommandRunner.swift`
  insert/autorun modes, pipe tables as real grids).
- **Artifacts** (`Views/ArtifactView.swift`): a complete ```html page,
  ````markdown document or ```mermaid block becomes a card; the preview
  window has a live `WKWebView`, a Code tab, copy, save, open in browser.
  Mermaid renders offscreen through `Views/MermaidRenderer.swift` with the
  bundled `Resources/mermaid.min.js` and shows as a retina snapshot
  (`MermaidBlockView`).
- **Themes** (`Views/AppTheme.swift`): `AppTheme` cases current (Liquid
  Glass, default), blueprint, terminal, synthwave, sakura, pastel, halloween,
  diaDeMuertos, yule, aurora; `ThemePalette` tokens, `ThemePattern`,
  `ThemeDecorations` with per-theme files (`HalloweenTheme`, `DiaDeMuertosTheme`,
  `SakuraPastelDecorations`, `YuleTheme`, `AuroraTheme`), `WorldTimeTheme`
  for the grid, `ThemeGridPicker`, `AdaptiveGlass` (macOS 26 glass with a
  material fallback on 14+). `App/HolidayThemeManager.swift` auto-switches for
  Halloween, Día de Muertos and Yule. Checklist: `docs/THEMING-CHECKLIST.md`.
- **Voice UI:** `AudioRecorder`, `VoiceMessagePlayer` (real waveform),
  `RecordingStatusView`; system-wide dictation is `App/DictationService.swift`
  (the island: a black tab at the housing's width whose black runs from the
  screen's top edge through the housing's column — the API's width runs a
  hair wide of the cutout, and covering the whole column turns that into "a
  pixel wider", never a step, as the notch utilities do — or a dark floating
  capsule 4 pt under the menu bar on displays without one; docked, its black grows
  from the screen's top edge through the housing's column and out of the
  seam on show, as opaque as its edge is far down the column and fully so at
  the seam, and retracts the same way on hide, the content fading in only once the tab has
  landed; floating it appears in place; theme ornaments by `themeID` — Yule's
  processing line is the candy cane, Día hangs the banner's pennants from
  the edge, warms up with marigolds, runs a tricolor line and floats petals
  through the glow (`DiaIsland*` in `DiaDeMuertosTheme.swift`); the theme's DARK palette in both appearances, a glow in the
  recording color that breathes on a 1.6 s clock as the recording indicator
  and never crosses the seam with the housing or the menu bar — design study
  `design/dictation/pill-studies.html`; phrase-by-phrase insertion via
  `TextInserter`,
  optional cleanup/translation by a small model resolved in
  `AppSettings.resolvedDictationCleanup`, Deepgram streaming mode).
  `App/DictationTextShaping.swift` is that pass's contract with the model:
  the instruction rides in the system slot with the bare transcript as the
  user turn, and the reply is shaped mechanically before insertion (lead-ins,
  labels, quotes, Markdown, code fences, em dashes) — pure Foundation,
  covered by `scripts/DictationShapingContractTest.swift`.
  `MicCapture` (in `DictationService.swift`) captures on an input-only HAL
  output unit bound to the chosen microphone — not on `AVAudioEngine`, whose
  input node is born on the default-input/default-output aggregate and keeps
  that aggregate's format (a Bluetooth headset as the default input made
  every start on a 48 kHz USB mic fail with -10868). The HAL IO thread only
  accumulates 2048-frame chunks; file writes, FFT and the streaming side-tap
  run on a serial processing queue. Device listeners (alive, rate, streams,
  default input) drive the died/recovered semantics.
  `App/BluetoothInputHold.swift` raises and holds a Bluetooth headset's
  hands-free link BEFORE the unit binds, so the A2DP→HFP profile switch
  cannot restart the capture in a loop; restarts use a backoff with a single
  pending retry per session and re-arm on the same microphone. A stop waits
  at most 3 s for the capture queue to release the segment file (a device
  mid-reconfiguration can hold it inside CoreAudio for minutes), and the
  hotkey cancels a session that is still processing.
- **Costs:** `Views/CostsSettingsView.swift` (session/today/month, charts by
  provider or model, soft monthly budget `SpendStore.monthlyBudgetUSD`).
- **Provider glyphs:** `Views/ProviderBadge.swift`, assets `Provider-<name>`.

## 9. Addons

Pattern (first set by LayoutFix, followed by every addon since): a
self-contained folder; a singleton with `start()` when it needs the launch
hook; a `SettingsTab` case plus an enable toggle in General; its own
settings object; its own localization function; an `APIKeyStore.AuxKey` for
secrets; a `Diagnostics` category; host mount points kept to one line each.

| Addon | Folder | Host mount points | Tools | Docs |
|---|---|---|---|---|
| LayoutFix | `Addons/LayoutFix` (+ `Resources/` tables) | `start()`, tab, status-menu items | none (hotkeys + `CGEventTap` auto mode) | `Addons/LayoutFix/README.md`, `scripts/gen-ngram-tables.py` |
| ImageAddon | `Addons/ImageAddon` | `start()`, tab, `AttachmentActionsBar` under the pending image, `ImageResultActionsBar` under results, slash commands in `sendMessage`, `ChatWindowBridge` | none (UI operations; Apple on-device or fal.ai) | `Addons/ImageAddon/ImageAddon-README.md`, `docs/ImageAddon-TZ.md`, `docs/ImageAddon-Model-Research.md` |
| CalendarAddon | `Addons/CalendarAddon` | tab, `CalendarToolService` in `ChatService`, EventKit access request on enable; `CalendarEventSnapshot` (a value copy of an occurrence) and `ConferenceLinkDetector` (the call link by host, out of url/location/notes — EventKit has no conference field) serve both the tool listing (`join:` line) and World Time | calendar/reminder tools | this map + `docs/addon-tool-playbook.md`, `scripts/ConferenceLinkContractTest.swift` |
| WorldTimeAddon | `Addons/WorldTimeAddon` | own panel + hotkey + status-menu item, tab; uses CalendarAddon for the busy lane (blocks are snapshots; blocks that touch share one capsule split into equal segments by start order with a count badge — the segment under the cursor is the target; a click opens `WorldTimeEventPopover`: chips for the capsule's other meetings, the meeting in every row's zone, join/copy link, place, people, notes) and `WorldTimeSlotService` (EventKit, no LLM) for slot events | none | this map |
| PlaudAddon | `Addons/PlaudAddon` | tab, `PlaudToolService` in `ChatService`, chips in `MessageRow`, preview window, `/plaud` command, session upkeep at launch; the Hermes agent reads Plaud through its own plugin and its own sign-in (`hermes-plugins/plaud`), nothing is handed over | Plaud tools | `docs/plaud-addon.md`, `hermes-plugins/plaud/README.md` |
| HermesAddon | `Addons/HermesAddon` + `Addons/AgentGateway/Core` | tab, a role in the preset switcher, `AgentChatService` in `streamAssistantReply`, the detached sidebar, notifications, background polling, courier | the agent's own | `docs/hermes-vps-setup.md`, `Addons/HermesAddon/Hermes-API-Fixtures.md` |

## 10. Agent chats versus ordinary chats

An agent role (`AgentRole`) is a conversation whose history and tools live on
the gateway. `AgentChatService.streamReply` maps `AgentTurnEvent`s onto the
same `ChatEvent` stream; the window's loop is unchanged. What differs:

- no app tools, no system prompt, no OCR fallback, no image features (an
  opt-in toggle brings the ImageAddon and OCR in on the app's keys);
- attachments travel as paths: `HermesFileCourier` (local gateway = paths
  as-is; remote gateway = upload through the dashboard files API), the
  `AgentAttachNote` text contract, `AgentFileChips`/`AgentPathResolver`/`AgentToolPaths`
  for files coming back, `AgentPlaudNote` (`plaud://<id>`) for recordings;
- a message typed while a turn runs steers INTO it (`POST /v1/runs/{id}/steer`,
  the patched session route as fallback) as an addition to the cycle in
  progress: `HermesSteer.framed` puts a tagged `<cuate-addendum>` block ahead
  of the words (Hermes alone tells the model to "adjust course", and it
  dropped the original task). The frame names only the cycle the addition
  belongs to — the addition itself may redirect the work — and its wording
  lives in `shared/fixtures/steer-frame.json`, nowhere else. Hermes stores
  the framed text inside a tool row, so it shows only in the raw transcript
  (dashboard, CLI tool output), never as a chat message on Telegram; the
  bubble shows the words, and the mirror strips the block from the tool row
  the marker comes back in. A steer the agent never read (`pending_steer` on
  `run.completed` — accepted after the last tool batch) travels up as
  `AgentTurnEvent.undeliveredFollowUp` → `ChatEvent.agentFollowUp` and the
  window sends it again as the next turn, frame removed, moving the bubble
  below the reply it missed. Off the stream (a dropped socket, the phone in
  Doze, a re-attach on open) the same field is read from `GET /v1/runs/{id}`:
  Android in `recoverTurn`/`maybeResumeHermesTurn` (replayed once per run,
  `hermesSteerReplayed`), the desktop in the orphan-run check after a broken
  stream. Android also remembers what it steered (`hermesSteered`) and, once
  a run is over for sure, re-sends the texts no transcript row carries — the
  road for a run a restarted gateway forgot, which has no `pending_steer`
  left to ask for;
- every user message bound for an agent conversation — typed, dictated, a
  slash command, a held send — goes through one door (`ChatWindow.post`):
  hold while a Stop settles, steer into a turn in flight (ours or one the
  gateway shows), else open a turn with only that message on the wire. The
  dictation path takes the same courier road as a typed send (upload +
  path note for staged images/files on a remote gateway); until 5.1 it
  bypassed both, so a dictated screenshot reached the model inline and
  nothing else, and a dictated follow-up raced the running turn;
- Stop stops the run ON THE GATEWAY: `HermesAddon.requestStop` sends
  `POST /v1/runs/{id}/stop` (the run id is read before the local stream is
  cancelled — the session clears it as it unwinds), then polls
  `GET /v1/runs/{id}` up to `stopConfirmWindow` and reports stopped / gone
  / unconfirmed / failed as a system line; the pill reads "Stopping…"
  meanwhile and sends typed during the wait are held (`heldSends`: the
  first opens the next turn, the rest steer into it). The session's own
  cancellation path fires the same request for new chat and a deleted
  role — cancellation ends an `AsyncThrowingStream` with nil, never a
  throw, so a stop parked in a `catch` was never sent; with the
  detached-runs gateway patch the closed socket no longer interrupts
  either, and "Stopped." used to be a lie (2026-09-07). One request per run
  (`stopTasks`), whoever asks. What survives the process: the run id is
  persisted per session at `run.started` (`hermes.activeRunBySession`,
  cleared when the run is known to be over), so after a relaunch the Stop
  button also covers OUR run the mirror now shows as "started elsewhere",
  and a follow-up steers into it; held sends are persisted by message id
  (`hermes.heldSends`, the bubbles are in the store) and go out after the
  next catch-up of that conversation (`recoverHeldSends`: idle → a turn,
  live → steer). Quitting the app cancels no stream, so it never stops the
  agent's run — a detached run keeps working and the mirror shows it. A
  turn started from the phone or CLI never reaches us with a run id and
  cannot be stopped from here (Hermes has no run listing). Android keeps
  the same contract in `ChatViewModel.stopStreaming`/`confirmStop`: the
  run id stays persisted until the gateway confirms, the conversation
  counts as busy meanwhile (`_stoppingIds`), sends are held into its
  persisted follow-up queue, and a message with attachments that no turn
  can take right now — dictation over a staged screenshot mid-turn used to
  be dropped — is remembered by id (`hermesHeldMessages`) and opens a turn
  of its own once the session is verified idle;
- one session, one conversation: a session started from a role's default
  thread is bound to that thread's key and opens THERE from the sessions
  list (`continueHermesSession`; `targetConversation` resolves a stale
  per-role session memory the same way). Older builds opened it as its own
  `.agent(role, session:)` conversation on top — a twin mirrored from the
  transcript, which carries no pixels and no audio — and
  `HermesAddon.mergeTwinConversations` folds those into the default thread
  at every launch (`ChatPersistence.mergeConversation`: rows keyed by
  `externalID`, the copy holding media wins, the twin's welcome line stays
  behind, pins carried over). The store step is enqueued whether or not the
  settings still show the twin — a launch that dies between the settings
  rewrite and the store merge must not orphan the twin's rows;
- `HermesMirrorSync` reconciles the local store with the gateway transcript
  (`ChatMessage.externalID`/`seq`), `HermesLiveTurn` detects turns started
  elsewhere, `HermesCompaction` renders the gateway's context summaries,
  `HermesModelContext` drives the context gauge, `HermesBriefing` and
  `HermesServiceNotice` render service messages, `HermesLocalGateway` is the
  one-click local install, `GatewayProbe` gives structured connection errors;
- the transport is written against `Hermes-API-Fixtures.md`, never against
  prose; capability flags from `/v1/capabilities` gate UI sections.

## 11. Cross-cutting

- **Localization:** `L()` (`App/Localization.swift`, en/es/ru, English
  fallback) plus per-addon tables `LFL`, `IAL`, `CAL`, `WTL`, `PLL`, `HL`,
  `AGL`. Every key needs all three languages. Views re-render through
  `AppSettings.language`.
- **Diagnostics** (`Diagnostics/`): opt-in in Settings → General; rotating
  `app.log`; breadcrumbs; `HangWatchdog` (main-thread ping, 2 s threshold,
  plus a CPU-spin detector; reports with `/usr/bin/sample`); "Export Logs"
  zips to Downloads. Categories in use: app, agent, artifact, calendar, chat,
  dictation, files, hermes, imageaddon, keys, layoutfix, mermaid, migration,
  notif, plaud, pricing, spend, store, tcc, terminal, transcript, ui,
  watchdog, worldtime. Rule: events and metadata only, never chat text,
  prompts, transcripts or keys.
- **Spend:** every provider emits `.usage`; `SpendStore.record` prices it
  through `PricingCatalog` (OpenRouter live prices win); OCR, STT, search and
  image operations write their own records; the Costs tab reads the ledger.
- **Notifications:** `App/NotificationService.swift` — built for agent
  turns; permission requested when the addon is enabled, never at launch.
- **Permissions (TCC):** Microphone, Screen Recording, Accessibility,
  Calendar/Reminders, Notifications, Automation (terminal autorun). Requested
  by the feature that needs them. `PermissionHealer` resets a grant that
  stopped matching the binary (once per app version); the stable "Cuate
  Signing" certificate in `scripts/make-dmg.sh` is what keeps grants across
  updates.
- **Concurrency:** the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  in Swift 5 language mode with approachable concurrency. Types that must run
  off the main actor are declared `nonisolated` (Diagnostics, APIKeyStore,
  ChatPersistence, ChatAttachment/ChatMessage, the Document* helpers,
  RemoteFileJanitor) and confine their state to private queues.
- **Selection and screen:** `App/SelectionGrabber.swift` (AX selected text,
  clipboard fallback), `App/ScreenshotCapturer.swift` (full/area).

## 12. Tests and scripts

- `scripts/test-attach-note.sh` runs every contract test: the attach note
  (Swift + Kotlin against `shared/fixtures/attach-note.json`), the Plaud
  marker (`shared/fixtures/plaud-note.json`), markdown lists, the document
  pre-flight and `read_document` queries, and the Hermes Plaud plugin
  (Python, stdlib only). The Swift suites compile standalone with `swiftc`
  from pure files — a file under test must stay free of AppKit/SwiftUI/app
  types.
- `scripts/make-dmg.sh` — the only way to build a distributable (universal
  Release, signed with "Cuate Signing", DMG in `build/`).
- `scripts/gen-ngram-tables.py` — regenerates the LayoutFix statistical tables.
- `design/onboarding/build_cards.py` — onboarding mockups.
- CI: `.github/workflows/cla.yml` (CLA assistant) only; there is no build CI.

## 13. Android

`android/` is a Kotlin/Compose port of the same product with the same
provider layer, ChatService rules, storage windowing, spend tracking,
artifacts, image tools, voice, themes, the Hermes agent and, since Android
2.9.2, documents in chat (`docs/documents-in-chat.md` §12: PdfBox text
layer and docx XML, no OCR on the phone). Its own README lists the
per-version parity. Not on Android: system-wide dictation (planned as an
IME). Voice messages share the desktop's cancel contract: ■ stops the
recording at once, the transcription waits out a short window
(`VOICE_CANCEL_WINDOW_MS`), and a second tap on the same button inside it
discards the clip — nothing is transcribed before the window closes, so
the length of the recording never shortens the chance to cancel.
Cross-platform text contracts are tested on both sides (`shared/fixtures/`);
twins to keep in sync are named in the code (`HermesSteer.swift` ↔
`hermes/HermesSteer.kt`, pinned by `steer-frame.json`).

## 14. Extension seams — what a change touches

| Adding… | Touch | Reference |
|---|---|---|
| a chat provider | `ProviderID` switches, `LLMProvider`, `.usage`, `PricingCatalog`, `ProviderRegistry`, capabilities, glyph asset, strings | `docs/provider-integration-playbook.md` |
| a client-side tool | a `*ToolService`, the gate in `ChatService.streamReply`, dispatch in the loop, `toolDigest` decision, status strings, tests | `docs/addon-tool-playbook.md` |
| an addon | folder, `start()`, `SettingsTab` + toggle, own settings/localization/aux key, diagnostics category, README in the folder, a row in §9 | §9 |
| an attachment kind | `ChatAttachment` classification, picker types + drop + paste routes, pre-flight, `buildMessages`, the summary line and `estimatedTokens`, pending + bubble chips, retention/lifecycle hooks, `LocalChatFilesView`, a contract test | §5, `docs/documents-in-chat.md` |
| a theme | enum case, palettes, `resolve`, World Time tokens, decorations, the `themeID` branches, holiday rule | `docs/THEMING-CHECKLIST.md` |
| a setting | `AppSettings` property + defaults key + migration for existing users, a Settings row with a `.help` tooltip, strings ×3 | §7 |
| a hotkey | `HotkeyCombo` default, settings property, recorder row, status-menu item, README table | §1 |
| a `ChatEvent` | `ChatWindow.streamAssistantReply`, `AgentChatService` | §4 |
| a persisted column | SwiftData optional column, `toStruct`/`toSDMessage`, reconcile key, Codable keys, Android Room when cross-device | §3 |
| a string | all three languages in the right table | §11 |
| a cross-device text format | a fixture in `shared/fixtures/`, Swift and Kotlin tests, `test-attach-note.sh` | §12 |

## 15. Invariants

- Every attachment payload goes through `ChatAttachment.fileBacked`; the
  chat store never holds large inline blobs.
- Every tool is offered only behind `modelSupportsTools`, and its prompt hint
  ships only together with its spec.
- Every provider emits `.usage` before finishing, and every paid call is
  recorded in the spend ledger.
- API keys and tokens live in the Keychain; diagnostics never log content.
- A new setting migrates existing users instead of changing their behavior.
- The transport of an external service is written against captured fixtures
  or the service's sources, never against remembered API shapes.
- Panels are created at launch; a `glassEffect` node is never re-created
  inside a conditional branch.
- Docs and code comments are English; only UI strings and test data are
  localized. `docs/` describes what is implemented; `private/` is gitignored
  and never referenced from public files.

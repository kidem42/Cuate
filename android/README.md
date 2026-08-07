# Cuate for Android

The Android port of Cuate: the same multi-provider AI chat, but in the shape of
an ordinary mobile app (on macOS it is a hotkey panel for quick access; on a
phone it is an assistant chat with the same features).

## Status: 2.2.0 — Cuate + Hermes Agent; functionally a complete port (except system dictation)

A ready-to-install APK: `dist/Cuate-2.2.0.apk` (release, minified, signed with
the key from `release.keystore`; the keystore and `keystore.properties` are kept
out of git — store them locally, they are required for updates carrying the same
signature). Release builds go **only** through `scripts/make-apk.sh` (version
bump, signing, publishing into `dist/`).

Added in 2.2 (Hermes Agent — a port of desktop 4.0–4.2):

- **The session sidebar** — a left drawer (an edge swipe, the hamburger or the
  role row in the switcher): creating, renaming, pinning, coloring and deleting
  sessions, unread dots — the full set from the desktop sidebar.
- **A model and effort switcher in the composer** — chips above the input field:
  re-locking the session's model with a provider·model pair from
  `/api/model/options`, and per-request reasoning effort (minimal…ultra) through
  `model_options.reasoning_effort`.

- **A role in the switcher**: a connected self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent)
  appears in the presets menu (🪽) with its own session threads; a thread behaves
  like an ordinary conversation (a Room mirror, two-pane, offline reading). The
  phone is always a remote client: a local gateway and one-click setup (4.3) are
  impossible by definition, and settings offer an SSH block with a copy button
  instead.
- **A transport built from live fixtures** (`hermes/HermesTransport.kt`):
  capability gating, session CRUD + PATCH rename, the mandatory model lock after
  creation (without it every turn 404s), the transcript, the SSE turn stream
  dispatched on the data line (the `.lines` trap), skills, toolsets, run stop.
- **The turn stream**: deltas + the authoritative `assistant.completed` (interim
  messages are glued with a blank line, not replaced), a tool status pill, and
  `_thinking` is never shown as a tool; the stop button kills the run on the
  gateway too.
- **The step log** — collapsible under the reply (tool · status · duration),
  built both live and from the transcript; tapping a step lazily loads the
  command/output/exit code from the gateway (the 4.2 drill-down).
- **Files to the agent**: a SAF picker for "any files, several at a time" in the
  ⋮ menu; images go inline (OpenAI parts, verified against the fixtures), and
  everything else goes through the Hermes dashboard's file API into
  `~/cuate-uploads/` (its own URL + token); with no dashboard configured there is
  an honest system warning.
- **Files from the agent — the reverse courier** (a port of desktop 4.4): paths
  mentioned in a reply are downloaded from the agent's host through the same
  dashboard file API. HTML/Markdown are quietly auto-fetched into the cache and
  materialize as a preview card (a fresh mention of the path re-downloads the
  copy, so an edit by the agent is visible); tapping HTML opens the **system
  browser** (WebView starved CDN-backed pages — Leaflet maps and the like), and
  Markdown gets the built-in preview; other files are sent to Downloads on tap.
  The paths are clickable right in the reply text; directories are not shown as
  chips (there is nothing to download). Without a dashboard the old fallback
  applies: "tap = copy the path". ⋮ → "Files in this chat" collects every path in
  the conversation plus a "Sent by you" group.
- **Pinned messages** (all chats, the desktop mechanics 1:1): pin by long tap, a
  bar with a snippet and k/n, a tap goes to the pin being shown and only then
  cycles, ✕ unpins; the order is the order of pinning; pins outside the window
  load themselves.
- **Sessions**: titles from the first message (on the gateway too), the list is
  mirrored (including sessions created from Telegram/CLI), unread dots on threads
  with external activity, and the `hermesSyncedSeq` watermark keeps our own turns
  from duplicating. Opening the drawer reconciles the list with the gateway:
  sessions deleted from another surface (desktop, CLI) disappear here too; an
  opened thread always lands on the last message.
- **The session's model and reasoning level** — in the top bar's ⋮ menu (nested
  pages showing the current value) rather than as chips under the composer: a row
  by the keyboard no longer eats the screen.
- **Notifications**: a banner when a run finishes while the app is backgrounded
  or another thread is open (the "Agent" channel, with permission requested on
  first entry into the role).
- `/` autocompletion of the agent's skills with descriptions; keys live in the
  Android Keystore; Room migration 3→4 (history is preserved).

Added in 2.1 (the chat engine contract — a port of desktop 3.20):

- **Pin-to-bottom as an invariant** — the feed follows the stream only while the
  reader is at the bottom; scrolling up during a reply no longer drags you back
  down on every chunk, and a "to the latest" button brings you back. Your own
  message still always jumps to the bottom.
- **Incremental markdown** — for a streaming reply only the live tail is
  re-parsed (the current paragraph / an open fence), while the stable prefix is
  cached on block boundaries; blocks are skipped in recomposition by value
  equality. The chunk flush was sped up from ~8 to 30 Hz — long replies no longer
  get heavier as they grow.
- **A tool budget in settings** (1–12, the web-search section) — how many tool
  rounds a single reply may spend. On exhaustion the model gets a budget notice
  instead of a silent cutoff and must write a final answer from what it gathered
  (the end of "(empty reply)").
- **Continuation rounds** — the model can end a round with a `<continue/>` marker
  and get up to 3 more working rounds with a fresh budget; the reply keeps
  growing in the same bubble, and the hidden "Continue." only goes into the
  request.

Added in 2.0.0:

- **The AISpotlight → Cuate rebrand**, following the desktop (3.21). Only what is
  visible changes: the app name, the theme, the monochrome icon and the Quick
  Settings glyph — now the Cuate brand mark. The technical identifiers
  (`applicationId com.aispotlight.android`, the Keystore alias, the Room database
  name) are **deliberately preserved**: changing them would break the update
  chain and lose the keys and chat history of existing installs. The update
  installs over the old one, all data is inherited, and no reinstall is needed.

Added in 1.8.x:

- **web_fetch** — keyless web-page reading for the model (a port of the Mac
  tool): the model requests a URL, the page is downloaded on the device and
  returned as readable text. It works with any provider and without a Brave key
  (in which case the model only gets web_fetch, no search); private/local
  addresses are blocked.
- **Extended share targets** — it is no longer only text that can be shared into
  the app: images (including several at once, `SEND_MULTIPLE`) become
  attachments, and audio (voice messages from WhatsApp/Telegram) is transcribed
  into the input field.
- **Recording in Opus** — dictation and voice messages are recorded as OGG/Opus
  48 kHz on Android 10+ (a smaller file means faster STT), with a fallback to m4a
  on older systems.
- **The transcription pill** — while a long voice message is being recognized the
  status is visible in the chat (a port of the Mac fix: without an indicator the
  message seemed to "vanish").
- **ImageAlpha** — transparency handled as on the Mac: a transparent input is
  flattened onto white before fal processing (the models ignore alpha and see the
  original background under the mask), a background-removal result gets the RGB
  under the transparency wiped (the original leaks in the file otherwise), and
  upscaling a cutout restores its transparency locally from the original alpha
  mask.

Added in 1.6.x–1.7.0:

- **Spend tracking** — the macOS version ported whole: usage capture on every
  provider, the pricing catalog, the spend ledger (Room migration 2→3, chat
  history preserved), a Costs screen with Canvas charts by day and a soft monthly
  budget; adaptive for tablets/foldables.
- **Voice messages, UX** — seeking by tap/drag on the waveform (a live fill, a
  position timecode); one shared transport per chat: starting a new message stops
  and rewinds the previous one, with auto-advance to the next voice message; the
  transcript folds under the player (a Show/Hide text toggle) and is available
  during synthesis and after a TTS failure; replies to voice questions are marked
  VOICE from the first token — a pulsing player silhouette instead of streaming
  text.

Added in 1.1.0 on top of the basic chat:

- **Themes** — 8 themes: Material You (dynamic) + Blueprint, Terminal, Synthwave,
  Sakura, Pastel, Halloween, Día de Muertos (light/dark palettes, background
  gradients, grid/scanlines, gradient bubbles and send button, a monospaced
  Terminal); a System/Light/Dark appearance mode; **holiday auto-switching**
  (Oct 31 → Halloween, Nov 1–2 → Día de Muertos, remembering and restoring the
  theme — a port of HolidayThemeManager).
- **Image tools (fal.ai)** — a long press on an image in the chat: upscale
  (Recraft Crisp), background removal (Bria RMBG-2.0), object removal by text
  description (Object Removal); Queue API submit→poll→fetch; the result drops
  into the chat as its own card; "Save to gallery" for any image.
- **Voice messages** — as on the Mac: record → transcribe → a chat message with a
  player (the audio is stored) and a transcript that goes to the model.
- **A preset switcher** in the chat's top bar (the active preset's emoji).
- **A Quick Settings tile** — the tile in the shade opens the assistant (the
  counterpart of the global hotkey).
- **Max tokens** in settings.

Ported from the macOS version (`../Cuate`, Swift → Kotlin):

- **The provider layer** — Anthropic (Messages API + explicit prompt caching),
  OpenAI (Responses API), Mistral / DeepSeek / OpenRouter / Kimi
  (chat/completions), Gemini (streamGenerateContent). SSE streaming through
  OkHttp, function calling, reasoning modes (auto/fast/deep) — a 1:1 port of
  `Providers/*.swift`.
- **ChatService** — the web_search agent loop (Brave, up to 4 iterations),
  context compression (a rolling summary: a 24k-token threshold, script-aware
  estimation, the last 12 messages verbatim, a merge-style prompt), and
  tool-context grounding on the last reply.
- **Storage** — Room (conversations + messages, windowed loading 120 at a time),
  API keys in the Android Keystore (AES/GCM), settings in SharedPreferences.
- **UI** — Jetpack Compose + Material 3 (dynamic color), Markdown rendering
  (code, tables, lists, quotes, links), streaming with an indicator, the
  conversation list, the settings screen, system-prompt presets.
- **Attachments** — the gallery through the system Photo Picker (no permissions)
  and the camera (`TakePicture` + FileProvider); images are downscaled to 2048px
  and stored as files; vision models get the pixels (the last message), non-vision
  ones (DeepSeek) get OCR text through Mistral OCR; older attachments carry an
  OCR cache on the attachment (lazy extraction, a budget of 3 per turn) — the
  macOS policy 1:1.
- **Voice input** — the microphone button: record (AAC/m4a) → STT (Mistral
  Voxtral / OpenAI / Deepgram, falling back to whichever is configured) → a voice
  message in the chat.
- **Artifacts** — complete ```html pages and ````markdown documents from a reply
  are shown as a card; opening gives a live WebView (JS enabled) or rendered
  Markdown, a Code tab, share, and saving to Downloads.
- **Foldables / tablets** — at a window width ≥ 600dp the conversation list is
  pinned to the left of the chat (two-pane); on a folded screen there is a single
  pane.
- **System integration** — a share target (text from other apps) and
  `ACTION_PROCESS_TEXT` (an entry in the text-selection menu) → the text lands in
  the input field as a quote (the counterpart of selection capture on macOS).
- **Localization** — en / ru / es (following the system language).

## What's next (planned)

The only thing deferred is the **voice IME keyboard**: system dictation into any
app plus on-the-fly translation (a port of DictationService; on Android that is
an InputMethodService with `commitText()` instead of synthesizing ⌘V).

## Building

Requires the Android SDK (compileSdk 36) and JDK 17+ (the JBR from Android Studio
will do):

```bash
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug
```

The APK: `app/build/outputs/apk/debug/app-debug.apk`. Or open the `android/`
folder in Android Studio.

The release APK is built **only** through `scripts/make-apk.sh` — the script
bumps the version, signs with the key from `release.keystore` and puts the result
into `dist/`.

## Structure

```text
app/src/main/kotlin/com/aispotlight/android/
  core/        ProviderCore: types, LLMProvider, HttpClient (SSE)     ← ProviderCore.swift
  providers/   Anthropic, OpenAICompatible, Gemini, Brave, Registry   ← Providers/*.swift
  chat/        ChatService (agent loop, compression), ChatViewModel   ← ChatService.swift
  data/        Room (Db, ChatModels)                                  ← ChatModels/ChatPersistence.swift
  settings/    AppSettings, ApiKeyStore (Keystore), Presets           ← AppSettings/APIKeyStore.swift
  ui/          MainActivity (adaptive), ChatScreen, Markdown, Settings ← Views/*.swift
```

License: AGPL-3.0 (see `../LICENSE`).

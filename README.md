# AISpotlight

A Spotlight-style AI assistant for macOS. Press a hotkey anywhere, get a floating chat panel with your favorite LLM — plus voice dictation, screenshots-to-chat, OCR and web search.

## Features

- **Spotlight-style floating panel** — summoned with a global hotkey from any app, opens on the screen where your cursor is, remembers its position
- **Multi-provider chat** — OpenAI, Anthropic (Claude), Google Gemini, Mistral, DeepSeek, Kimi (Moonshot) and OpenRouter (any model by slug, with a live capability catalog); model lists are fetched live from each provider's API
- **Local models (Ollama)** — run models on your Mac, **free and offline, no API key**: enable in Settings → General, then pick the local provider in the chat like any other. Points at Ollama by default (editable endpoint, so LM Studio / llama.cpp / vLLM / LocalAI work too via the OpenAI-compatible API). For Ollama, a built-in console manages models without the terminal: browse installed models with their capabilities (vision/tools) and live memory footprint, **download** new ones with a progress bar, **delete**, and **start/stop** (load into / unload from memory) from Settings → Local models or a status-bar submenu. A master switch can disable cloud providers entirely for a fully offline setup
- **Voice input**
  - Speech-to-text via **Mistral (Voxtral)**, **OpenAI** or **Deepgram** — pick the provider in Settings → Voice
  - Voice messages in chat with playback
  - System-wide **dictation**: press a hotkey in any text field, speak, and the transcribed text is typed for you phrase by phrase as you talk (chunked mode, on by default)
  - **Dictation with translation** into a target language on the fly — the pill under the notch shows the language's ISO badge; click it to switch the language mid-dictation
  - Optional LLM cleanup of transcribed text (punctuation, filler words)
- **Selection capture** — select text in any app (including WhatsApp/Telegram/Slack), press the panel hotkey, and it lands in the input field as an editable quote
- **LayoutFix addon** — fixes text typed in the wrong keyboard layout (`ghbdtn` → `привет`, EN/RU/ES): automatically as you type or by hotkey; off by default
- **Image tools addon** — process an attached image in one click. **Background removal** and **upscale** run **on-device for free** by default (Apple Vision / Core Image — no key), with higher-quality cloud models optional (one fal.ai key): upscale (Recraft Crisp / Topaz / SeedVR2 / Real-ESRGAN), background removal (Bria RMBG-2.0 / BiRefNet v2). **Object removal** uses fal.ai (Bria Eraser / Object Removal) via an inline brush-mask editor or a text description. Slash commands `/upscale`, `/bg`, `/cleanup`; one-click Save to Downloads or a custom folder; per-session/month spend counter; on by default
- **Attach images** — paperclip button or paste with ⌘V (files, screenshots, browser images; HEIC/TIFF converted automatically); an image can be sent with no text at all — the active preset's prompt drives the handling
- **Screenshots to chat** — capture the full screen or a selected area straight into the conversation
- **OCR** — extract text from images **on-device for free** by default (Apple Vision; many languages incl. Cyrillic), or via **Mistral OCR** for layout-aware Markdown (tables/columns)
- **Web search** — augment answers with live results (Brave Search API)
- **Cost tracking** — token usage is captured from every provider (including cache hits/misses and reasoning tokens) and priced via a bundled per-token catalog with weekly refresh; Settings → Costs shows session/today/month totals, daily stacked charts by provider or model, per-provider breakdowns and a soft monthly budget with 80%/100% warnings (informative, never blocks)
- **Run terminal commands** — shell commands in answers get a ▶ button next to Copy: by default it opens Terminal with the command already typed in and you press Enter yourself; an opt-in mode runs it immediately (macOS asks for the Automation permission once). Consecutive commands land in the same Terminal window, so multi-step flows read like one session
- **Prompt presets** — built-in and custom system prompts, switchable per conversation; any preset can keep its **own isolated chat** (separate history, context and rolling summary) via the "Own chat" toggle in Settings → Prompts — switching presets swaps the conversation, and a reply that is still generating keeps streaming into its home chat in the background
- **Artifacts** — ask for an interactive demo, visualization or a document, and the model returns a complete HTML page or Markdown document shown as a compact card in the chat (streaming progress included). Click the card for a preview window (⅔ of the screen): live interactive WKWebView for HTML, Notion-style rendered view for Markdown, a Code tab, copy, save to file and open-in-browser. Ask for changes and the revised document arrives as a new card — earlier versions stay openable in the history
- **Diagrams** — ask for an architecture scheme, flow, sequence, state machine or pie breakdown and the model answers with a mermaid diagram rendered **natively inline in the chat**: offline (bundled mermaid, no CDN), retina-crisp snapshots, themed to the app (accent color, light/dark, colorblind-validated series palette). Click for a live preview with pinch-zoom and export to SVG (always light, document-ready) or PNG @3x. Invalid diagram source degrades gracefully to a code block with an error badge — never an error graphic in the chat
- **Markdown rendering** with code blocks, tables, task lists (`- [ ]`), numbered lists and dividers in responses; copying a message with a table also puts a spreadsheet flavor on the clipboard, so a paste into Google Sheets / Excel / Numbers lands in real cells
- **Launch at login**, light/dark/system theme, UI in English, Spanish and Russian
- **Android companion app** — the same multi-provider chat as a native Android app (Kotlin/Compose): providers, web search, voice messages, OCR, image tools, artifacts, themes and cost tracking; lives in [`android/`](android/README.md)

## Default hotkeys

| Action | Hotkey |
| --- | --- |
| Toggle panel | ⌘⇧Space |
| Full-screen screenshot to chat | ⌘⇧S |
| Area screenshot to chat | ⌘⇧D |
| Dictation (type where the cursor is) | ⌥Space |
| Dictation with translation | ⌥⇧Space |

All hotkeys are configurable in Settings → General.

## Installation

Requires **macOS 14 (Sonoma) or newer**; the binary is universal (Apple Silicon + Intel). On macOS 26+ the panel renders with Liquid Glass; on older systems it falls back to the standard translucent material.

1. Download `AISpotlight-<version>.dmg` from [Releases](https://github.com/kidem42/AISpotlight/releases)
2. Drag **AISpotlight** to the **Applications** folder
3. The build is signed with a self-signed certificate (not notarized), so before the first launch remove the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/AISpotlight.app
   ```

   This is needed once. If the DMG arrived without a browser download (AirDrop, USB drive, `curl`), there is no quarantine flag and the app opens right away.

## Setup

On first run the onboarding walks you through the essentials:

- **API keys** — add a key for at least one provider in Settings → API Keys. Keys are stored in the **macOS Keychain**, never in plain files
- **Permissions** — macOS will ask for Microphone (voice input), Screen Recording (screenshots) and Accessibility (dictation typing, inserting commands into Terminal) when the corresponding feature is first used; the "Run immediately" mode for terminal commands additionally asks for Automation (controlling Terminal) once
- Optional: a [Brave Search API](https://brave.com/search/api/) key for web search

## Building from source

Requirements: Xcode 26+ (for the macOS 26 SDK); the app itself runs on macOS 14+.

```bash
git clone https://github.com/kidem42/AISpotlight.git
cd AISpotlight
open AISpotlight.xcodeproj   # build & run the AISpotlight scheme
```

### Packaging a DMG

```bash
./scripts/make-dmg.sh              # full Release build + DMG
SKIP_BUILD=1 ./scripts/make-dmg.sh # repackage without rebuilding
```

The script builds a universal Release (arm64 + x86_64), signs the app with the "AISpotlight Signing" self-signed certificate (falls back to ad-hoc if absent; the stable identity keeps TCC permissions across updates), generates a Retina drag-to-Applications window and produces `build/AISpotlight-<version>.dmg`. No external tools required.

## Project structure

```text
AISpotlight/
├── App/          # app entry, floating panel, hotkeys, dictation, selection capture, screenshots, terminal runner
├── Addons/       # self-contained addons (LayoutFix keyboard-layout fixer, ImageAddon image tools)
├── Diagnostics/  # in-app logging and hang watchdog
├── Providers/    # LLM/STT/OCR/search clients, settings, Keychain key store
├── Models/       # chat data models
└── Views/        # SwiftUI: chat window, settings, onboarding, voice UI
android/          # Android companion app (Kotlin/Compose) — own README and build script
docs/             # architecture reviews, research notes, tech debt
scripts/
└── make-dmg.sh   # Release + DMG packaging (universal binary)
```

## Privacy

- API keys live in the macOS Keychain
- Conversations go directly from your Mac to the provider you selected — there is no intermediate server
- Audio recordings are used only for transcription and are not persisted

## License

AISpotlight is licensed under the **[GNU AGPL-3.0](LICENSE)** © 2026 Pavel Kravets.

You may use, study, modify and share it — **including commercially — only if** any
distributed or network-deployed version is also released as open source under the
AGPL-3.0, with full corresponding source. This keeps the app and every
improvement to it open.

- **Contributions** are welcome under the [Contributor License Agreement](CLA.md);
  see [CONTRIBUTING](CONTRIBUTING.md).
- **Commercial / proprietary license** — to use AISpotlight without the AGPL's
  source-disclosure obligations, a commercial license is available from the
  author: kravec42@gmail.com.

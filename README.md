# Cuate

**A Spotlight-style AI assistant for macOS.** Press a hotkey anywhere, get a floating chat panel with the model of your choice — plus dictation, screenshots, OCR, web access and image tools. Your keys, your machine, no middleman server.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)](#install)
[![Releases](https://img.shields.io/github/v/release/kidem42/Cuate)](https://github.com/kidem42/Cuate/releases)
[![Android](https://img.shields.io/badge/Android-companion%20app-green.svg)](android/README.md)

---

## Why

Chat apps live in a browser tab you have to find, and they hold your conversations on someone else's server. Cuate is the opposite: a panel that appears over whatever you are doing, talks straight to the provider you picked with the key you own, and disappears with Esc. Everything that can run on-device — OCR, background removal, upscaling — does, for free.

## Install

Requires **macOS 14 (Sonoma) or newer**; the binary is universal (Apple Silicon + Intel). On macOS 26+ the panel renders with Liquid Glass, older systems fall back to the standard translucent material.

1. Download `Cuate-<version>.dmg` from [Releases](https://github.com/kidem42/Cuate/releases)
2. Drag **Cuate** into **Applications**
3. Builds are signed with a self-signed certificate (not notarized), so clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Cuate.app
   ```

   Not needed when the DMG arrived without a browser download (AirDrop, USB, `curl`).

Then add a key for at least one provider in **Settings → API Keys** and press **⌘⇧Space**. Keys are stored in the macOS Keychain, never in plain files. Permissions (Microphone, Screen Recording, Accessibility) are requested the first time you use the feature that needs them.

## Hotkeys

| Action | Hotkey |
| --- | --- |
| Toggle panel | ⌘⇧Space |
| Full-screen screenshot to chat | ⌘⇧S |
| Area screenshot to chat | ⌘⇧D |
| Dictation (types where the cursor is) | ⌥Space |
| Dictation with translation | ⌥⇧Space |
| World Time panel | ⌥⇧T |
| Close the panel | Esc |

All of them are configurable in Settings → General.

## What it does

**Chat with any model.** OpenAI, Anthropic, Google Gemini, Mistral, DeepSeek, Kimi and OpenRouter (any model by slug); model lists come live from each provider's API. Or run models locally through **Ollama** — free, offline, no key — with a built-in console to download, delete, load and unload them without the terminal. A master switch can disable cloud providers entirely.

**Talk instead of typing.** Speech-to-text via Mistral (Voxtral), OpenAI or Deepgram. System-wide dictation types your words into any text field as you speak, and can translate on the fly.

**Feed it your screen.** Screenshots (full or area) go straight into the conversation, selected text arrives as an editable quote, and OCR extracts text from any image — on-device and free by default (Apple Vision), or through Mistral OCR for layout-aware Markdown.

**Get real documents back.** Interactive HTML pages and Markdown documents render as cards with an in-app preview; mermaid diagrams render natively inline, offline, themed to the app; tables copy into spreadsheets as real cells.

**Reach the live web.** Brave Search plus a keyless page reader, with inline citations and a configurable tool budget per reply.

**Know what it costs.** Token usage is captured from every provider and priced from a bundled catalog: session/today/month totals, charts by provider or model, and a soft monthly budget.

<details>
<summary><b>Addons</b> — image tools, calendar, world time, layout fixer</summary>

- **Image tools** — background removal and upscaling run **on-device for free** (Apple Vision / Core Image), with higher-quality cloud models optional through a single fal.ai key. Object removal uses an inline brush-mask editor or a text description. Slash commands `/upscale`, `/bg`, `/cleanup`. Transparency is handled end to end.
- **Calendar & Reminders** — the assistant reads your schedule and creates events through macOS EventKit (iCloud, Google, Exchange — whatever is already synced). Per-calendar checkboxes decide what it can see. Off by default.
- **World Time** — a timezone grid in a floating glass panel: cities as rows, the home city's 24 hours as columns, DST-aware, every IANA zone plus ~240 major cities, searchable in English, Russian and Spanish at once. With the Calendar addon on, it also shows your busy lane and creates 30-minute events by clicking a slot.
- **LayoutFix** — fixes text typed in the wrong keyboard layout (`ghbdtn` → `привет`, EN/RU/ES), statistically rather than by dictionary lookup, so names and typos convert too.

Two addons are large enough to have their own sections: [Hermes Agent](#hermes-agent--your-own-agent-gets-a-desktop) and [Plaud](#plaud--your-recorded-meetings-become-answerable).

</details>

<details>
<summary><b>The details</b> — attachments, presets, artifacts, the transcript engine</summary>

- **Attachments** — up to 5 images per message by any route: paperclip, ⌘V, drag & drop, screenshot hotkeys; HEIC/TIFF converted automatically. Models without vision get each image OCR'd into text.
- **Prompt presets** — built-in and custom system prompts, switchable per conversation; any preset can keep its own isolated chat with separate history and context.
- **Artifacts** — a complete HTML page or Markdown document arrives as a compact card; the preview window gives a live WKWebView, a Code tab, copy, save and open-in-browser. Ask for changes and the revision arrives as a new card while earlier versions stay openable.
- **Terminal commands** — shell commands in answers get a ▶ button: by default it opens Terminal with the command typed in and you press Enter; an opt-in mode runs it immediately.
- **Transcript engine** — the message list is an AppKit scroll engine with row-level updates: streamed replies grow smoothly without re-rendering the list, auto-follow sticks to the bottom, and scrolling up to read never gets yanked back.
- **Interface** — light/dark/system themes, English, Spanish and Russian, launch at login.

</details>

## Hermes Agent — your own agent gets a desktop

A [Hermes agent](https://github.com/NousResearch/hermes-agent) (Nous Research) is a self-hosted assistant with its own long-term memory, skills, cron jobs and terminal — running on your Mac, a home server or a VPS. It normally answers through Telegram or a CLI. Cuate becomes another surface of that same agent: a conversation you started on your phone continues here, and what you do here shows up there.

The agent stays a black box with its own configuration — Cuate never injects prompts, tools or model settings into it.

**In the chat.** The agent appears as a role in the prompt switcher, next to your presets. Every gateway session opens as **its own conversation** with its own history and streaming, so a long task in one session keeps running while you talk in another. Typing `/` autocompletes the agent's **skills**; a composer control switches the session's **model and reasoning effort**; a message typed mid-turn reaches the working agent instead of waiting for it to finish.

**While it works.** Tool runs appear live in the status pill and stay as a collapsible step journal — expand a step for the command, its output, exit code and touched paths. A context gauge shows how full the model's window actually is, and clicking it compacts the conversation on the agent's side.

**The sidebar.** Sessions (create, rename, pin, color, delete, unread badges), the agent's skills and toolsets, and its runtime passport: which model it is on and which host actually executes its commands.

**Files both ways.** Anything you attach is couriered onto the agent's host, so a file you added on the phone is real for the agent too. Files it creates come back the same way: HTML and Markdown arrive as artifact cards with in-app preview, other files download on click, and paths in its replies are clickable. A folder button lists everything exchanged in the conversation.

**When you are away.** A background watch notifies you about finished turns — including runs that completed while the app was closed, or work started from another surface entirely.

**Setup.** For an agent on this Mac, Settings → Hermes Agent sets up and starts the gateway service in one click. For an agent on a VPS reachable from anywhere without a VPN, follow [docs/hermes-vps-setup.md](docs/hermes-vps-setup.md) — it is self-sufficient: do it yourself, or paste it into any capable LLM and it will walk you through with your values. The token lives in the Keychain; the endpoint works over loopback, LAN or Tailscale.

The app's own image tools and OCR **stay out of agent chats by default** — the agent owns its sessions end to end. An opt-in toggle brings them in, running on the app's own keys, with results kept local to Cuate.

## Plaud — your recorded meetings become answerable

A [Plaud](https://www.plaud.ai) recorder captures meetings and calls; its app turns them into summaries and transcripts. Cuate connects your account so the assistant can **search that library and read from it in an ordinary chat** — "what did we decide on Monday's call?" stops being a question you answer by scrolling. It works with whichever provider that chat is on; conversations with a Hermes agent are the exception — there the tools belong to the agent, and Cuate adds none of its own.

**Sign-in is OAuth in the browser** — the app never sees your password, tokens live in the Keychain, and access is revocable any time. Access is **read-only**: Cuate can find and read, never modify.

**Recordings arrive as cards.** When the assistant finds or reads one, it attaches to the reply. Open a card for a preview with every summary tab (Summary, Highlights, …), the **full transcript with clickable timecodes**, and **inline audio streamed straight from Plaud** — seek anywhere, control it from Now Playing and the media keys, or click a timestamp to play from that moment.

**Unprocessed recordings are flagged** rather than silently skipped, and deep-link into Plaud's web app where processing starts (their API cannot start it — hence no surprise charges).

`/plaud <question>` pins a turn to your notes, and a privacy mode makes recordings reachable **only** through that command. Note content leaves your Mac only as part of a chat request to the provider you chose, and only when the assistant actually reads a recording. Off by default.

## Android

A native Kotlin/Compose companion app shares the same multi-provider chat, voice, OCR, image tools, artifacts and cost tracking, and connects to the same Hermes agent — see [`android/`](android/README.md).

## Build from source

Requirements: Xcode 26+ (for the macOS 26 SDK); the app itself runs on macOS 14+.

```bash
git clone https://github.com/kidem42/Cuate.git
cd Cuate
open Cuate.xcodeproj   # build & run the Cuate scheme
```

Packaging a DMG:

```bash
./scripts/make-dmg.sh              # full Release build + DMG
SKIP_BUILD=1 ./scripts/make-dmg.sh # repackage without rebuilding
```

The script builds a universal Release (arm64 + x86_64), signs with the "Cuate Signing" self-signed certificate (ad-hoc if absent — the stable identity keeps TCC permissions across updates), and produces `build/Cuate-<version>.dmg`. No external tools required.

<details>
<summary>Project layout</summary>

```text
Cuate/
├── App/          # app entry, floating panel, hotkeys, dictation, selection capture, screenshots, terminal runner
├── Addons/       # self-contained addons (LayoutFix, ImageAddon, CalendarAddon, WorldTimeAddon, HermesAddon, PlaudAddon, AgentGateway core)
├── Diagnostics/  # in-app logging and hang watchdog
├── Providers/    # LLM/STT/OCR/search clients, settings, Keychain key store
├── Models/       # chat data models
└── Views/        # SwiftUI: chat window, settings, onboarding, voice UI
    └── Transcript/  # AppKit transcript engine
android/          # Android companion app (Kotlin/Compose) — own README and build script
docs/             # architecture reviews, setup guides, tech debt
scripts/          # make-dmg.sh and helpers
```

</details>

## Privacy

- API keys and OAuth tokens live in the macOS Keychain
- Conversations go from your Mac straight to the provider you selected — there is no intermediate server
- Audio is used for transcription and is not persisted
- On-device features (OCR, background removal, upscaling) send nothing anywhere

## Contributing

Issues and pull requests are welcome — start with [CONTRIBUTING.md](CONTRIBUTING.md). Contributions are accepted under the [Contributor License Agreement](CLA.md), which lets the project keep its dual-license model. Bundled third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## License

Cuate is free and open source under the **[GNU AGPL-3.0](LICENSE)** © 2026 Pavel Kravets.

- **Use, study, modify, fork** — freely, for any purpose.
- **Distribute or deploy your version** (including as a network service) — only if it is also released as open source under the AGPL-3.0, with full corresponding source.
- **Closed-source / commercial license** — available separately from the author: [kravec42@gmail.com](mailto:kravec42@gmail.com).

Official builds (GitHub Releases, and app stores in the future) are distributed by the author under the author's own terms and may include commercial features on top of this source.

**Trademark.** The name "Cuate" and the app icon are trademarks of Pavel Kravets and are **not** covered by the AGPL. Forks and modified versions must use a different name and icon; unmodified builds of this repository that clearly link back here may keep the name.

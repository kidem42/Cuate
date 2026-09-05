# Cuate — working notes for coding agents

Cuate is a macOS status-bar AI assistant (Swift, SwiftUI + AppKit, Xcode 26,
deployment target macOS 14) with an Android companion under `android/`. The
repository is public (AGPL-3.0).

## Before planning anything

1. Read `docs/ARCHITECTURE.md` — the index of subsystems, seams and
   invariants. Most "new" features already have a seam (tools, attachments,
   addons, themes, settings, persistence hooks); §14 says what a change of
   each kind touches.
2. Grep the tree for the existing pattern before designing one: `*ToolService`
   for tools, `Addons/*` for the addon shape, `AppTheme` for themes,
   `AppSettings` for settings and their migrations.
3. Never write a transport or a request shape from memory. Read the service's
   sources or captured fixtures (`Addons/HermesAddon/Hermes-API-Fixtures.md`,
   `docs/plaud-addon.md`) or probe it live; three consecutive plugin bugs
   came from guessed signatures.
4. Mockups are transcribed from the view code (sizes, glyphs, strings), never
   drawn from memory.

## Conventions

- **Language.** Code, comments, commit messages and everything in `docs/` are
  English. Only UI strings (`L()` and the addon tables, en/es/ru, every key in
  all three) and test data may be localized.
- **Isolation.** The project defaults to `MainActor`; anything used off the
  main actor is `nonisolated` and confines its state to a private queue.
- **Settings.** A new setting with a new default must not silently change
  existing users' behavior — migrate from indirect evidence in
  `AppSettings.init`.
- **Controls.** Every new control gets a `.help` tooltip.
- **Themes.** Switches over `AppTheme` have no `default:`; a forgotten theme
  must fail to compile. Never re-create a `glassEffect` node inside an
  `if` branch.
- **Diagnostics.** `Diagnostics.log(category, event)` with events and
  metadata only — never chat text, prompts, transcripts or keys.
- **Addons** are self-contained folders: own settings prefix, own
  localization function, own aux key, one-line host mount points.
- **Docs.** `docs/` describes only what is implemented. `private/` is
  gitignored internal material and is never referenced from public files.
  When a subsystem, seam or rule changes, update `docs/ARCHITECTURE.md` in the
  same change; a new theme token updates `docs/THEMING-CHECKLIST.md`; a
  user-visible feature updates the README feature list.

## Build, test, release

- Compile check: `xcodebuild -project Cuate.xcodeproj -scheme Cuate -configuration Debug build`
  (with `CODE_SIGNING_ALLOWED=NO` when the signing certificate is absent).
- Contract tests: `scripts/test-attach-note.sh` (Swift suites compile
  standalone from pure files; keep files under test free of AppKit/SwiftUI).
- Distributable builds ONLY through `scripts/make-dmg.sh`; Android release
  APKs only through `android/scripts/make-apk.sh` (the keystore lives outside
  git).
- Versioning: one bump per release cycle; `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` change together (two occurrences each in
  `Cuate.xcodeproj/project.pbxproj`). Check the published releases and the
  latest commits before choosing a number.
- Flow: build for testing → verify on a real install → commit → the
  `Release: Cuate X.Y` commit → tag → GitHub release with the DMG.
- Commit messages: one descriptive English sentence about the behavior, no
  prefixes, no tool attribution.
- The app itself is exercised by a person on an installed build; automated
  runs of the app (smoke or sandbox) are not part of the workflow because
  they interfere with the user's TCC grants.

## Where things are

| Need | Look at |
|---|---|
| A chat turn, tools, summary | `Providers/ChatService.swift`, `docs/ARCHITECTURE.md` §4 |
| Attachments and their limits | `Models/ChatModels.swift`, `Providers/DocumentPreflight.swift`, `docs/documents-in-chat.md` |
| Persistence, windowing, retention | `Models/ChatPersistence.swift`, `docs/ARCHITECTURE.md` §3 |
| Adding a provider | `docs/provider-integration-playbook.md` |
| Adding a tool | `docs/addon-tool-playbook.md` |
| Adding a theme | `docs/THEMING-CHECKLIST.md` |
| The transcript engine | `Views/Transcript/`, `docs/chat-architecture-review.md` §10–§11 |
| Hermes agent | `Addons/HermesAddon`, `Addons/AgentGateway/Core`, `docs/hermes-vps-setup.md` |
| Plaud | `Addons/PlaudAddon`, `docs/plaud-addon.md`, `hermes-plugins/plaud` |
| Image tools | `Addons/ImageAddon/ImageAddon-README.md` |
| LayoutFix | `Addons/LayoutFix/README.md` |

# ImageAddon — addon

Image operations on chat attachments through cloud AI APIs (fal.ai).
P1 (implemented): upscale · background removal · object removal (mask/text).
P2 (not implemented): prompt-based generation/editing (fal / OpenAI / Gemini).

Based on: `docs/ImageAddon-TZ.md` (+ `docs/ImageAddon-Model-Research.md`).

## Design

Everything lives in this folder (pattern: `Addons/LayoutFix`). The addon
reuses host building blocks (`APIKeyStore`, `HTTPClient`, `ChatStore` /
`ChatAttachment`, `ProviderGlyph`, `Diagnostics`) but stores no state in
`AppSettings` and adds nothing to the global `L()` table.

| File | Responsibility |
|------|----------------|
| `ImageAddon.swift` | Singleton, `start()` (boot hook). |
| `ImageAddonSettings.swift` | `UserDefaults` (`imageAddon.*`): enable, per-function models, output format, auto-copy, input limit, save folder (nil = Downloads), spend counters. |
| `ImageAddonSettingsView.swift` | Settings tab: the fal.ai key (glyph + validation + errors, the Keys-tab pattern), rich model pickers (class badge + caption + price, spec §3.1a), options, folder, spend + `ImageAddonEnableToggle`. |
| `ImageAddonLocalization.swift` | Self-contained `IAL()` strings (EN/ES/RU). |
| `Core/ImageOperationProvider.swift` | The protocol + `ImageFunction`/`ImageRequest`/`ImageResult`/`ImageModelInfo` (factors, face-enhance, MP ceilings) + the registry. |
| `Core/ImageOperations.swift` | The operation pipeline (shared by buttons/slashes/retries): input normalization, status, result into the chat, the result registry, auto-copy, restoring the attachment on error. + `ChatWindowBridge`, `ImageResultStore` (>8 MB → file), `ImageOperationCancelButton`, `ImageSlashCommands`. |
| `Core/ImageTaskRunner.swift` | Single-flight executor: cancel(), 1 auto-retry on timeout/5xx, Diagnostics logging, spend accounting. |
| `Core/ImageAddonError.swift` | Errors with localized descriptions, HTTP-body sanitizer. |
| `Core/ImageInputPreparer.swift` | PNG conversion (ImageIO), data-URI, GIF→first frame, auto-downscale 25 MP/20 MB, output-format conversion. |
| `Providers/FalProvider.swift` | REST client for the fal.ai Queue API (submit → poll → fetch, cancel_url) + a static catalog of every P1 model + a no-cost `validateKey`. |
| `Views/AttachmentActionsBar.swift` | [Upscale ▾(factors/faces)] [Remove background] [Remove objects] under the attachment preview + result naming. |
| `Views/MaskEditorView.swift` | Inline editor: brush 10–100 px (default 40), undo, reset, "by text" mode, Apply. |
| `Views/ImageResultActionsBar.swift` | Save (to the folder, no dialogs) / Finder / Copy / Retry with another model ▾ / Continue editing. |

## Models (the catalog is static, updated with releases)

| Function | Models (fal id) | Default |
| -------- | --------------- | ------- |
| Upscale | Recraft Crisp (`fal-ai/recraft/upscale/crisp`) · Topaz (`fal-ai/topaz/upscale/image`) · SeedVR2 (`fal-ai/seedvr/upscale/image`) · Real-ESRGAN (`fal-ai/esrgan`) | Recraft Crisp |
| Background | Bria RMBG-2.0 (`fal-ai/bria/background/remove`) · BiRefNet v2 (`fal-ai/birefnet/v2`) | Bria RMBG-2.0 |
| Objects | Bria Eraser (`fal-ai/bria/eraser`, mask) · Object Removal (`fal-ai/object-removal`, text) | Bria Eraser |

## Host mount points (outside this folder)

1. **Boot** — `App/CuateApp.swift`: `ImageAddon.shared.start()`.
2. **Settings** — `Views/SettingsView.swift`: `case imageAddon`, a conditional tab, `ImageAddonEnableToggle()` in General.
3. **Panel** — `Views/ChatWindow.swift`: `ImageAttachmentActionsBar` under the preview; `ImageSlashCommands.handle` at the start of `sendMessage`; `ImageOperationCancelButton()` in the thinking pill; `ChatWindowBridge.chatStore = chatStore` in onAppear; onReceive `.imageAddonAttachRequest`.
4. **Chat** — `Views/MessageRow.swift`: `ImageResultActionsBar(attachment:)` under assistant images.
5. **Key slot** — `Providers/APIKeyStore.swift`: `AuxKey.fal`.

Host improvements that are useful even without the addon: the paperclip button
+ system dialogs as panel sheets, ⌘V for images from the clipboard
(`ChatWindow`/`CustomTextEditor`), guarding `hideChatWindow` against an attached
sheet, the `.openSettingsWindow` notification, and a file-backed
`ChatAttachment` (`fileURLString` + `contentBase64`).

Removing the addon = delete this folder + revert the hooks above.

## How it works

1. An image reaches the panel: paperclip (NSOpenPanel sheet), ⌘V, screenshots.
   Drag & drop is deliberately NOT supported — it conflicts with auto-hiding
   the panel on focus loss.
2. Under the preview sits the actions row (when the addon is on). With no
   fal.ai key a click shows a popover linking to settings (spec §6).
3. The input is normalized: GIF → first frame (banner), over the limit →
   downscale (banner), PNG conversion where the model requires it.
4. `FalProvider`: base64 data-URI → `queue.fal.run/<model>`; polling
   `status_url` (1 s, 120 s deadline); cancel — the × on the pill → PUT
   `cancel_url`; 1 auto-retry on timeout/5xx; a 422 with policy text →
   "the model rejected the image".
5. The result: converted to the format from settings (background is always
   PNG), over 8 MB it goes to `Application Support/Cuate/images/` (a file
   reference in `ChatAttachment`), as an assistant message named
   `<name>-upscaled/-nobg/-cleaned`. Below it: Save (Downloads/a custom folder,
   no dialogs), Finder, Copy, Retry with another model, and for cleanup —
   Continue editing. On error: a system message + the source goes back into the
   composer for a one-click retry.
6. Slash commands: `/upscale [2|4|8]`, `/bg`, `/cleanup <what to remove>`.

## Requirements & limitations

- A fal.ai key (Keychain, `AuxKey.fal`); key validation is a free auth probe
  (the status of a non-existent job).
- Images are passed as data-URIs (no storage upload) — slower on very large
  files.
- "Retry with another model" / "Continue editing" live for the session only
  (the result registry is not persisted).

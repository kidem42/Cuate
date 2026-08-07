# Spec: image processing and generation addon (ImageAddon)

Version 1.0 · 2026-07-17 · Based on: `docs/ImageAddon-Model-Research.md`

---

## 1. Goal

Add an addon to Cuate for image operations through cloud AI APIs:

- **P1 (first release):** Upscale · Background removal · Object removal (object cleanup)
- **P2 (second release):** Prompt-based image generation and editing

The addon follows the existing LayoutFix pattern: a self-contained `Addons/ImageAddon/` folder with minimal hooks into the host.

## 2. Product constraints

- The app is a Spotlight panel: it opens on a hotkey and closes on focus loss. **No separate windows.** The whole UI lives inside the floating panel.
- The object-removal function is never called a "watermark remover" anywhere in the UI or marketing. The wording is: "Removes unwanted objects, text and defects." (Reason: DMCA §1202 + the providers' ToS, see research §5.)
- Keys live only in the Keychain through the existing `APIKeyStore`. Images are never stored on the app's servers (we have none) — only direct calls to the providers' APIs.

## 3. Providers and models

### 3.1. The "function → provider → model" matrix

On the settings tab the user picks a provider and a model **separately for each function** (as they do for voice today).

| Function | Provider (choice) | Models | Default |
|---|---|---|---|
| Upscale | fal.ai | Recraft Crisp · Topaz Upscale · SeedVR2 · Real-ESRGAN | Recraft Crisp ($0.004) |
| Background removal | fal.ai | Bria RMBG-2.0 · BiRefNet v2 | Bria RMBG-2.0 ($0.018) |
| Object removal | fal.ai | Bria Eraser (mask) · fal object-removal (by text) | Bria Eraser |
| Generation (P2) | **fal.ai / OpenAI / Gemini** | fal: Nano Banana 2, GPT Image 2, Seedream 4.5, FLUX.2; OpenAI direct: gpt-image-2, gpt-image-1.5; Gemini direct: gemini-3.1-flash-image (NB2), gemini-3-pro-image | fal.ai + Nano Banana 2 |

The principle for generation: **either through an aggregator or directly.** Cuate users already have OpenAI/Gemini keys in `APIKeyStore`, so the direct path works with no new key. fal.ai is one new key that covers everything (with no markup over the developers' pricing, see research §6).

### 3.1a. The model catalog with UI descriptions

Every model in the picker is shown with a class badge and a short one-line caption. The texts are localized (EN/ES/RU):

**Upscale**

| Model | Badge | UI caption | Price |
|---|---|---|---|
| Recraft Crisp | Standard | Fast and clean, with no invented detail. The best default | $0.004 |
| Topaz Upscale | Premium | Maximum photo quality, huge resolutions (up to 512 MP) | ~$0.08–0.15 |
| SeedVR2 | Quality | The community's top pick; slower, better for difficult photos | ~$0.02–0.05 |
| Real-ESRGAN | Budget | The cheapest, fine for simple images | ~$0.0025 |

**Background removal**

| Model | Badge | UI caption | Price |
|---|---|---|---|
| Bria RMBG-2.0 | Standard | Precise edges, safe for commercial use | $0.018 |
| BiRefNet v2 | Budget | The open SOTA model, almost free | ~$0.002 |

**Object removal**

| Model | Badge | UI caption | Price |
|---|---|---|---|
| Bria Eraser | Standard | Careful removal of what you select (a mask) | ~$0.04 |
| Recraft Erase | Budget | Cheap mask-based removal | $0.002 |
| fal object-removal | Smart | Describe what to remove in words — no selection needed | ~$0.01–0.04 |

**Generation (P2)**

| Model | Badge | UI caption | Price/img |
|---|---|---|---|
| Nano Banana 2 (Google) | Standard | The best balance of price and quality, strong at editing | ~$0.067 |
| GPT Image 2 (OpenAI) | Premium | Top quality and text inside images; pricier, strict filter | $0.05–0.21 |
| Seedream 4.5 | Freedom | Almost no censorship, strong at editing | ~$0.04 |
| FLUX.2 | Balance | Reliable, no random refusals, priced per megapixel | ~$0.03/MP |
| Nano Banana 2 Lite | Budget | The fast, cheap version of NB2 | ~$0.034 |

The badges are a fixed enum: `Budget / Standard / Quality / Premium / Smart / Freedom` (in code: `ImageModelTier`). The catalog (id, name, badge, caption, price) is part of the static catalog in `FalProvider.swift` (see §5).

### 3.2. API keys

- A new key: `AuxKey.fal` (extend `enum AuxKey` in `Providers/APIKeyStore.swift`; today it holds `brave, deepgram`).
- For direct generation the existing `ProviderID.openai` / `ProviderID.gemini` keys are reused.
- In the addon's settings UI: the fal.ai key field with masked display + a link to fal.ai/dashboard/keys (following the pattern of the existing Keys tab).

### 3.3. The call protocol

Everything lives inside `Addons/ImageAddon/`; the host is left alone:

```swift
enum ImageFunction { case upscale, removeBackground, objectCleanup, generate }

protocol ImageOperationProvider {
    var id: ImageProviderID { get }            // .fal, .openaiDirect, .geminiDirect
    func supports(_ f: ImageFunction) -> Bool
    func models(for f: ImageFunction) -> [ImageModelInfo]
    func run(_ request: ImageRequest) async throws -> ImageResult
}

struct ImageRequest {
    let function: ImageFunction
    let model: String
    let inputImage: Data?          // nil for generate
    let maskImage: Data?           // mask-based objectCleanup
    let prompt: String?            // generate / text-based object-removal
    let params: [String: Any]      // scale factor, output format, etc.
}

struct ImageResult { let image: Data; let mimeType: String; let costUSD: Double? }
```

- **The fal.ai client:** REST `https://queue.fal.run/{model_id}` (submit → poll status → fetch result). Images are passed as base64 data-URIs or uploaded to fal storage (`https://fal.run/storage/upload`). The header is `Authorization: Key <FAL_KEY>`. Timeout: 120 s, polling every 1 s.
- **OpenAI direct (P2):** `POST /v1/images/generations` and `/v1/images/edits` (gpt-image-2).
- **Gemini direct (P2):** `generateContent` with `responseModalities: ["IMAGE"]` (an SSE client to copy from — `GeminiProvider.swift`).
- Reuse `HTTPClient` from `ProviderCore.swift` where possible; errors get their own `ImageAddonError` (no key, rate limit, content filter, file too large, timeout, network).

## 4. UX

### 4.1. Entry points (P1)

An image reaches the panel by four routes (the first two are new and require work in `ChatWindow.swift`):

1. **An "Attach file" button** next to the input field → `NSOpenPanel` (jpg/png/webp/heic). ⚠️ Opening the system dialog must not close the panel — disable auto-hide on focus loss for the duration of the dialog (the dialog is a child window of the panel).
2. **Drag & drop** of a file onto the panel and **⌘V** of an image from the clipboard → `ChatAttachment` (both missing today — to be added).
3. The existing screenshots (full screen / area).
4. Context: an image is already attached as `pendingAttachment`.

> **Update (2026-07-26).** The composer accepts up to **5 images** as a batch
> (`pendingAttachments`, on every route: the multi-select dialog, ⌘V, drag & drop,
> screenshots). The actions toolbar below is shown **only for a single attachment** —
> several collapse into a row of thumbnails with per-item removal and go to the model
> as one message (vision providers get content parts, non-vision ones get OCR of each).
> In agent conversations (Hermes) the toolbar and OCR are additionally behind the
> "App features" opt-in (see private/AGENT-ADDONS-NOTES.md §12, internal notes).

### 4.2. Actions on an image

When an image attachment appears in the preview (`PendingAttachmentPreview`) — a row of action buttons (only if the addon is on and a key is present):

```
[Upscale ▾] [Remove background] [Remove objects] [Extract text (OCR — existing)]
```

- **Upscale**: a click runs the default ×2; ▾ offers ×2/×4/max (depending on the model).
- **Remove background**: one click, the result is a PNG with alpha.
- **Remove objects**: the preview expands into an inline editor inside the panel: a mask brush (size slider, undo, reset) plus, alternatively, a "what to remove" text field (the text-based object-removal mode). An "Apply" button.
- Slash commands in the input field as an alternative: `/upscale`, `/bg`, `/cleanup` (they act on the current attachment).

### 4.3. The result

- The result is added to the chat as an assistant message with a `ChatAttachment` (rendering already works through `AttachmentPreviewBubble`).
- Buttons under the result: **Save** (NSSavePanel, the same focus trick), **Copy** (NSPasteboard), **Retry with another model ▾**, and for cleanup — **Continue editing** (the result becomes the new input).
- While processing: a spinner + status in the existing `statusText` ("Upscale ×4, Topaz…"), cancelled with the ×.
- The result's file name: `<source>-upscaled.png` / `-nobg.png` / `-cleaned.png`.

### 4.4. Generation (P2)

- The `/img <prompt>` slash command right in the chat OR a mode switch in the panel (a "Chat | Image" segmented control next to the input field).
- In image mode: a prompt field, an aspect-ratio choice (1:1, 3:2, 2:3, 16:9*), a count (1–4), and the chosen model as a badge (a click switches it quickly).
- Editing: if an image is attached plus a prompt → edit mode (for models that support it: NB2, GPT Image 2, FLUX.2).
- Results go into the chat with the same actions (Save/Copy/Variations).
- *16:9 is unavailable on gpt-image-2 (1536×1024 max) — hide the option depending on the model.

### 4.4a. Operation parameters (quick ones, at call time)

The philosophy: one click with sensible defaults; the models' fine-grained knobs stay hidden. Available parameters per function:

| Function | Parameter | Values | Default |
|---|---|---|---|
| Upscale | Factor | ×2 / ×4 / the model's max | ×2 |
| Upscale | Enhance faces | on/off (Topaz and Real-ESRGAN only) | off |
| Background removal | — (no parameters) | | |
| Object removal | Mode | mask (brush) / text description | mask |
| Object removal | Brush size | slider 10–100 px | 40 |
| Generation (P2) | Aspect | 1:1, 3:2, 2:3, 16:9* | 1:1 |
| Generation (P2) | Count | 1–4 | 1 |

Constraint: the input × the upscale factor must not exceed the chosen model's ceiling (Recraft ~16 MP, SeedVR2 ~8K, Topaz up to 512 MP) — unavailable factors are disabled.

### 4.4b. Input formats and limits

| Format | Behavior |
|---|---|
| JPG, PNG, WebP | Sent to the provider as-is (no re-encoding — quality is preserved) |
| HEIC, TIFF | Converted locally to PNG (ImageIO) before sending, transparently to the user |
| GIF | The first frame is taken, with a warning banner |
| SVG, PDF, video | Not supported (for PDF there is the existing OCR path) |

Input limit: 25 MP / 20 MB → auto-downscale with a warning. Output: PNG (the default, and always PNG with alpha for background removal) / JPEG / WebP, per the setting.

### 4.5. Settings (the "Images" tab)

Following the LayoutFix pattern: `case imageAddon` in `SettingsTab`, the tab is visible when the addon is on, and there is a master toggle in General.

The tab's contents:
1. The fal.ai key (masked, with a link to get one).
2. Per-function sections: Upscale / Background / Objects / Generation — each with a provider picker (where applicable) and a model picker. Every model in the picker carries its class badge (Budget/Standard/Premium…) plus a short caption and the price per operation (see §3.1a). For generation the provider picker offers: fal.ai / OpenAI (direct) / Gemini (direct); the model list depends on the chosen provider.
3. Options: output format (PNG/JPEG/WebP), "copy the result to the clipboard automatically" (off), the input size limit (default 25 MP / 20 MB — downscale with a warning).
4. A spend counter for the session/month (the sum of `costUSD`, kept locally in UserDefaults).

## 5. Code architecture

```
Addons/ImageAddon/
├── ImageAddon.swift              // singleton, start(), registration in the UI hooks
├── ImageAddonSettings.swift      // ObservableObject, UserDefaults "imageAddon.*"
├── ImageAddonSettingsView.swift  // the settings tab + EnableToggle
├── ImageAddonLocalization.swift  // IAL("key"), EN/ES/RU
├── Core/
│   ├── ImageOperationProvider.swift  // the protocol + request/response models
│   ├── ImageTaskRunner.swift         // the task queue, statuses, cancellation, cost tracking
│   └── ImageAddonError.swift
├── Providers/
│   ├── FalProvider.swift             // the queue.fal.run client + the model catalog
│   ├── OpenAIImageProvider.swift     // P2
│   └── GeminiImageProvider.swift     // P2
└── Views/
    ├── AttachmentActionsBar.swift    // the buttons above the attachment preview
    ├── MaskEditorView.swift          // the brush/mask for cleanup
    └── GenerationModeView.swift      // P2
```

Hooks into the host (kept minimal, modelled on LayoutFix):
1. `CuateApp.applicationDidFinishLaunching` → `ImageAddon.shared.start()`.
2. `SettingsView.swift` → `case imageAddon` + the tab + a toggle in General.
3. `ChatWindow.swift` → `AttachmentActionsBar` under `PendingAttachmentPreview`; drag & drop/⌘V/the "Attach" button (these three are useful outside the addon too — treat them as host work).
4. `APIKeyStore.swift` → `AuxKey.fal`.

The fal model catalog is static, in `FalProvider.swift` (endpoint id, name, function, price, parameters), and updated with app releases.

## 6. Error handling and edge cases

| Case | Behavior |
|---|---|
| No fal key | The action buttons stay visible; a click shows a tooltip linking to settings |
| The provider's content filter | The message "The model rejected the image" + advice to switch models (Seedream is more lenient) |
| Input over the limit | Auto-downscale to 25 MP with a warning banner |
| HEIC/TIFF input | Converted to PNG locally (ImageIO) before sending |
| Timeout/5xx | 1 auto-retry, then an error with a "Retry" button |
| The panel closed mid-processing | The task continues in the background; the result appears in the chat on the next open (persisted through `ChatStore`) |
| A large result in chat.json | Results over 8 MB are written to `Application Support/Cuate/images/`, and `ChatAttachment` holds a file reference (a model extension: an optional `fileURL` field) |

## 7. Non-functional requirements

- EN/ES/RU localization from the first release (the `IAL` pattern).
- Logging through `Diagnostics.log("ImageAddon", …)`: operation start/finish, model, duration, size, cost; never image content.
- No telemetry leaves the machine.
- UI latency: the panel never blocks, every call is async, and cancelling cancels the request.

## 8. Stages and acceptance

**Stage 1 — infrastructure:** the addon folder, settings, the tab, the fal key, `FalProvider` + one call (Recraft Crisp upscale), the attach button/DnD/⌘V.
✔ Acceptance: attach a PNG → "Upscale" → the result appears in the chat → "Save" works.

**Stage 2 — all of P1:** background removal, cleanup (mask + text), model choice in settings, slash commands, the cost counter, errors/limits.
✔ Acceptance: all three functions on real keys, switching the model changes the result, the mask works in the panel without losing focus.

**Stage 3 — P2 generation:** the "Image" mode, `/img`, three providers (fal / OpenAI direct / Gemini direct), edit with a reference.
✔ Acceptance: generation through each of the three providers on its own key; editing an attached image; correct per-model aspect constraints.

## 9. Open questions

1. Do we need an operation history separate from the chat (a result gallery)? — not for now, the chat is the history.
2. Batch processing of several files — out of scope for v1.
3. Local models (SeedVR2/BiRefNet on Apple Silicon, no API) — a potential P3, not part of this spec.

# Playbook: integrating a new LLM provider

**Code version:** 3.5+ (after spend tracking landed)
**Purpose:** a step-by-step checklist for adding a new chat provider to Cuate — from the enum to the "Costs" tab. The order of the steps is the order of the dependencies; each block ends with what to verify it against.

All paths are relative to `Cuate/Cuate/`.

---

## 0. Choosing the implementation path

| Situation | Path | Reference |
|---|---|---|
| The API is OpenAI chat/completions compatible (most of them: DeepSeek, Kimi, Mistral…) | A new static instance of `OpenAICompatibleProvider` with its own base URL | `Providers/OpenAICompatibleProvider.swift:11-30` |
| A unique API of its own | A separate provider file | `Providers/GeminiProvider.swift` (simple), `Providers/AnthropicProvider.swift` (with cache breakpoints) |
| An aggregator with a model catalog and manual slug entry | Like OpenRouter: `usesManualModelEntry`, a `ModelInfo` catalog | `fetchModelCatalog`, `OpenAICompatibleProvider.swift:447` |

## 1. The provider identifier — `Providers/ProviderCore.swift`

Add a case to `enum ProviderID` and fill in **every** switch (the compiler will point them out):

- `displayName` — the name in the UI;
- `usesManualModelEntry` — true only for aggregators with no dropdown;
- `supportsVision` — a coarse per-provider default (per-model exceptions are step 6);
- `badgeLetter` + `brandColorHex` — the badge and the brand color (the color also tints the provider on the "Costs" charts);
- `apiKeyURL` — the key-creation page (opened from settings);
- `modelCatalogURL` — aggregators only;
- `preferredDefaultModels` — the preferred models, best first. Matching: an exact id match or the prefix of a dated snapshot ("claude-sonnet-5" → "claude-sonnet-5-20250929"). Prefer the rolling `-latest` aliases.

## 2. Implementing `LLMProvider`

The protocol (`ProviderCore.swift`): `streamChat` / `fetchModels` / `validateKey` (the default is "valid if it can list models"; for providers with a public `/models`, override it the way OpenRouter does → `/api/v1/key`).

`streamChat` must:
1. Stream through the shared `HTTPClient.sseStream` (it filters `data:` frames and cuts `[DONE]`).
2. Yield `.text(chunk)` as text arrives.
3. Accumulate fragmented tool calls and emit `.toolCalls([...])` as a single event at the end (web search works through function calling on all of them).
4. **Emit `.usage(TokenUsage)`** before `finish()` — see step 3.
5. Map errors through `ProviderError.fromHTTP` (raw response bodies must never reach the UI).

Don't forget: the `maxTokens` cap, if the provider has per-model limits (`AnthropicProvider.maxTokensCap`, the DeepSeek/Gemini clamps in `ChatService.streamReply`).

## 3. Capturing usage (spend tracking) — MANDATORY

Every provider must emit `.usage(TokenUsage)` — otherwise the user's spend on it will only ever be a rough estimate. Field normalization:

| `TokenUsage` field | Semantics |
|---|---|
| `inputTokens` | **NON-cached** input (if the API only gives a total — subtract cached) |
| `outputTokens` | The whole output, reasoning included |
| `cacheReadTokens` | Read from cache (billed cheaper: Anthropic ×0.1, DeepSeek ≈1/50) |
| `cacheWriteTokens` | Written to cache (Anthropic ×1.25; usually 0 elsewhere) |
| `reasoningTokens` | Informational; already included in `outputTokens` |

A checklist of traps (every one of them has already happened on an existing provider):

- [ ] **The usage frame arrives with an empty `choices`/no content** — parse `usage` BEFORE the content guards (OpenAI-compatible: the final chunk with `include_usage`; Gemini: a usage-only last chunk — read before the `candidates` guard).
- [ ] **Cumulativeness** — if a provider sends usage several times (Anthropic `message_delta`, Gemini on every chunk), keep the last value, don't sum them.
- [ ] **The request flag** — OpenAI-compatible providers need `stream_options: {"include_usage": true}`. Send it only to verified ones: an unverified parameter can return a 4xx. Check with a live request; if the provider sends usage on its own (Mistral, Kimi), the flag isn't needed.
- [ ] **The cache breakdown** — look for fields like `cache_read_input_tokens`, `prompt_cache_hit_tokens`/`miss`, `cached_tokens` in `prompt_tokens_details`, `cachedContentTokenCount`.
- [ ] `yield(.usage(...))` strictly before `continuation.finish()`, and only if `!usage.isEmpty`.

Aggregation across agent-loop iterations and writing to the ledger is done by `ChatService` — nothing more is needed in the provider. If the stream breaks, usage never arrives — `ChatService.recordSpend` writes an estimate flagged `isEstimate` on its own.

## 4. Pricing — `Providers/PricingCatalog.swift`

1. Add the provider's models to `snapshotJSON` (USD **per single token**, LiteLLM fields: `input_cost_per_token`, `output_cost_per_token`, `cache_read_input_token_cost`, `cache_creation_input_token_cost`).
2. The table key matches by "exact match → longest prefix", so a family can be covered by one key ("claude-sonnet-4" covers 4.5/4.6), but watch for collisions ("gpt-5" and "gpt-5.5" — the longer prefix wins).
3. In `mapLiteLLMKey` add a mapping from the LiteLLM catalog prefix to our `ProviderID` — then the weekly automatic price update will pick the provider up.
4. If the provider returns prices in its own model catalog (like OpenRouter's `pricing`) — forward them into `ModelInfo.promptPricePerToken`/`completionPricePerToken` and teach `ChatService.recordSpend` to prefer them.

No price is not a disaster: the ledger records the tokens with `costUSD = nil` and the UI shows "no price". Still, better to fill the snapshot in.

## 5. Registration — `Providers/AppSettings.swift`

`ProviderRegistry.provider(for:)` — return an instance for the new case (the only place, and the compiler will remind you).

## 6. Capabilities

- `ModelCapabilities.supportsReasoningControl` (`ProviderCore.swift`) — a slug heuristic, if the provider has reasoning models;
- per-model vision/tools quirks — `AppSettings.modelSupportsVision/Tools/ReasoningControl` (for aggregators, from the `ModelInfo` catalog);
- parameter clamps (for example `max_tokens ≤ 8192`) — in `ChatService.streamReply` (`providerTokenCap`).

## 7. UI and localization

- The API key: the slot appears automatically from `ProviderID.allCases` in the Keys section; check that `validateKey` gives a sensible error for a junk key.
- Strings: new keys go into `App/Localization.swift` — **all three languages** (en/es/ru), English is the fallback.
- `.help` tooltips on new controls — a project rule (see `docs/TECH-DEBT.md`, the 3.5 fix).
- The badge: the letter and color were already set in step 1; no separate assets are needed (`Views/ProviderBadge.swift`).

## 8. e2e checklist before committing

Builds — only `./scripts/make-dmg.sh` for a distributable; a raw `xcodebuild build` is enough to check that it compiles.

- [ ] `fetchModels` fills the dropdown; `preferredDefaultModels` picks a sensible default;
- [ ] an ordinary stream: text arrives in chunks, the finish is clean;
- [ ] the tool loop: web search is called and the result is fed back (if the model can do tools);
- [ ] vision: the image goes out (or a correct OCR fallback for non-vision);
- [ ] **usage**: the `Diagnostics` log has `spend.append … est=false` with non-zero tokens; a repeat request in the same chat shows `cacheRead > 0` (if the provider has a cache);
- [ ] **price**: a ledger record with `costUSD != nil`, and the number matches a manual calculation (tokens × price);
- [ ] cancelling generation: a record with `est=true`, and the app doesn't crash;
- [ ] an invalid key: a human-readable error in the chat;
- [ ] the "Costs" tab: the provider shows up on the charts in its brand color.

---

## Appendix: map of the spend-tracking files

| What | Where |
|---|---|
| `TokenUsage`, `LLMStreamEvent.usage` | `Providers/ProviderCore.swift` |
| Per-provider usage capture | `AnthropicProvider.swift` (message_start/delta), `OpenAICompatibleProvider.swift` (chat/completions + /responses), `GeminiProvider.swift` (usageMetadata) |
| Prices | `Providers/PricingCatalog.swift` (snapshot + LiteLLM update + OpenRouter live) |
| The ledger and aggregates | `Models/SpendLedger.swift` (`SDSpendRecord`, `SpendLedger`, `SpendStore`) |
| Writing chat/summary + the estimate on a break | `Providers/ChatService.swift` (`recordSpend`) |
| Writing OCR / STT / search / images | `MistralOCRService.swift`, `TranscriptionService.swift`, `BraveSearchService.swift` (search: $0.005/request on the Base AI plan, `isEstimate` — the free tier really is free), `Addons/ImageAddon/Core/ImageTaskRunner.swift` |
| UI | `Views/CostsSettingsView.swift`, the `costs` tab in `Views/SettingsView.swift` |

# Playbook: adding a client-side tool to the chat

**Code version:** 4.17
**Purpose:** the checklist for giving the model a new function tool that
executes on the user's Mac. Four tools already follow this shape —
`WebFetchService` (`web_fetch`), `CalendarToolService` (calendar and
reminders), `PlaudToolService` (recordings) and `DocumentToolService`
(`read_document`) — and `BraveSearchService` (`web_search`) is the keyed
variant. Copy the shape; do not invent a fifth.

Client-side tools are free, keyless unless the backing service needs a key,
and work with every provider whose model can call functions. They never
apply to agent chats: there the agent owns its tools (a Hermes counterpart is
a plugin in `hermes-plugins/`, see `hermes-plugins/plaud`).

## 1. The service (`Providers/` or the addon folder)

One `enum` (`@MainActor` when it touches the store or settings) with:

| Member | Contract |
|---|---|
| `toolName` / `canHandle(_ name:)` | the exact function names the model will call |
| `toolSpecs()` | `[ToolSpec]` (name, description, JSON-schema `parameters`). Returns EMPTY when there is nothing to offer (no calendars visible, no live documents, no grant) — the caller then adds neither the tool nor the hint. Put the live inventory into the description so the model knows what exists without a call (calendars, documents with pages and sizes). |
| `systemPromptHint()` | one short paragraph: when to call, what to prefer (a page range over the whole file, a query over a dump), what to tell the user when the tool cannot help |
| `statusLine(for: ToolCall)` | the localized line shown in the thinking pill while the call runs ("Reading name.pdf…") |
| `run(_ call: ToolCall, …) async -> String` | executes and RETURNS errors as plain strings (never throws): the model reads "No document named X. Available: …" and self-corrects |

Keep results bounded: Plaud and documents cap one result at 30,000
characters with a stated truncation note that tells the model how to narrow
the request. Anything pure (parsing, ranges, search, caps) goes into a
Foundation-only file so a standalone contract test can compile it (§6).

## 2. The gate (`ChatService.streamReply`)

Add one block next to the existing ones:

```swift
if SomeAddon.shared.isAvailable,
   settings.modelSupportsTools(provider: providerID, model: model) {
    let tools = SomeToolService.toolSpecs()
    if !tools.isEmpty {
        options.tools += tools
        systemPrompt += "\n\n" + SomeToolService.systemPromptHint()
    }
}
```

Rules encoded there:

- the specs AND the prompt hint live under ONE condition — an addon that is
  off, a missing grant or a tool-less model costs zero prompt bytes;
- `modelSupportsTools` is the only capability check (per model for
  OpenRouter and Ollama, true for the dedicated providers);
- agent conversations are skipped (`store.conversation.isAgent`) when the
  tool reads app state;
- an invocation-style exposure (Plaud's `/plaud`) is decided from the last
  user message before the gate.

## 3. Dispatch (the tool loop in `streamReply`)

```swift
} else if SomeToolService.canHandle(call.name) {
    continuation.yield(.status(SomeToolService.statusLine(for: call)))
    result = await SomeToolService.run(call, store: store)
}
```

Decide whether the result joins `toolDigest` (the compact grounding stored
on the reply as `toolContext` and re-attached to the next requests): web
results do; calendar, Plaud and document results do not (large, or
re-fetchable through the tool). Tool-produced files become chips through
`.attachments([ChatAttachment])` (see `PlaudToolService`).

Every call counts against `AppSettings.maxToolIterations`; nothing to add.

## 4. Diagnostics and strings

- One `Diagnostics.log` category per addon/tool (`calendar`, `plaud`,
  `files`), logging names, counts and sizes — never content.
- Status lines and refusal notes in all three languages, in the addon's own
  table (`CAL`, `PLL`, …) or in `L()` for core tools.

## 5. Settings and lifecycle

- Availability = the addon's master switch + whatever access it needs (an
  EventKit grant, an OAuth token in `APIKeyStore.AuxKey`, a live file).
- Access is requested when the addon is enabled, never at app start.
- If the tool creates or caches data (Plaud notes, document text), decide its
  retention and its deletion hooks (new chat, message removed, preset
  deleted, the 15-day prune) up front — see `docs/documents-in-chat.md` §7
  for the full set of hooks.

## 6. Tests

A standalone contract test in `scripts/` (`swiftc` over the pure files, run
from `scripts/test-attach-note.sh`) for parsing, matching, caps and error
texts. Fixtures shared with Android go to `shared/fixtures/`.

## 7. Checklist before hand-over

- [ ] `toolSpecs()` returns empty when there is nothing to offer;
- [ ] the hint ships only with the spec;
- [ ] `run` never throws; unknown names answer with the inventory;
- [ ] results are capped with a note that says how to narrow;
- [ ] the status line shows in the pill; the diagnostics line has no content;
- [ ] a model without tools still gets a sane placeholder (the feature
      degrades, it does not error);
- [ ] agent chats untouched;
- [ ] contract test green; `docs/ARCHITECTURE.md` §9/§14 updated.

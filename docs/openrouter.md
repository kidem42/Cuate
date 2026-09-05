# OpenRouter as a one-key provider

**Version:** Cuate 5.0 (macOS) · Android 3.0

With only an OpenRouter key the app can search the web, read pages, take
documents, pick a model from the whole catalog and keep exact costs — no
Brave key, no other services. This page describes what the app sends and
where the switches are.

## Server tools instead of Brave and the local fetch

Settings → Chat, visible only while the chat provider is OpenRouter, two
toggles (default on):

- **Web search via OpenRouter** — on OpenRouter turns the request declares
  `{"type":"openrouter:web_search","parameters":{"max_results":5,"max_uses":5}}`
  instead of the Brave `web_search` function. Engine `auto`: the provider's
  native search where it exists, else Exa at about $0.007 per search, charged
  to the OpenRouter balance.
- **Page reading via OpenRouter** — `{"type":"openrouter:web_fetch",
  "parameters":{"engine":"openrouter","max_uses":5}}` instead of the local
  fetch; the `openrouter` engine is free.

Both ride only when the global web-access toggle is on and the model can call
tools (the catalog's `supported_parameters`). OpenRouter runs them itself and
hands the model the results; our own function tools (calendar, Plaud,
`read_document`) travel in the same `tools` array. The model is asked to cite
inline exactly as with Brave; the sources OpenRouter reports as `url_citation`
annotations become the turn's grounding digest for follow-up questions. The
footnote under the toggles says what the settings page of OpenRouter also
says: search results and pages pass through third parties and sit outside its
zero-data-retention setting.

Turning a toggle off restores the old path (Brave when its key exists, the
local fetch otherwise).

## Documents

See docs/documents-in-chat.md §8: a PDF rides as a base64 `file` part on the
attach turn with the `native` engine on models whose catalog lists file
input, else the free `cloudflare-ai` extraction; every document turn is
routed with `provider.data_collection = "deny"`.

## Costs

OpenRouter returns `usage.cost` — the exact charge for the request, server
tools included — and `usage.server_tool_use.web_search_requests`. The app
books the chat turn at that exact cost minus the search share, and the search
share as its own "Web search, queries" line (requests × $0.007, marked as an
estimate because native search bills at the provider's rate), so the
provider's total in Settings → Costs equals what OpenRouter charged. Token
counts and cached-token splits are recorded as before.

## The model browser

Settings → Chat → Model, "Browse catalog…": the whole OpenRouter catalog from
the cached `/models` payload — search over name, slug and description, filter
chips (images, documents, tools, reasoning, free), sort by newest, cheapest or
name, and a detail pane with the description, prices per 1M tokens, context
length, max output, the date the model was added and a link to its page.
"Select" writes the slug into the model field. "Refresh" reloads the catalog
on demand; the caption shows when it was last updated. The catalog also
refreshes itself when it is a week old or predates the browser.

## Privacy and routing

Every OpenRouter turn that involves a document is sent with
`provider.data_collection = "deny"`; plain chat follows the account's privacy
settings on openrouter.ai. The upstream provider that served a request is
logged in the diagnostics (`served by …`).

**Only zero-data-retention endpoints** (Settings → Chat, OpenRouter only, off
by default) adds `provider.zdr = true` to every OpenRouter request —
enforced by OpenRouter regardless of the account page; a model without such
an endpoint fails instead of falling back to another provider.

**What the account allows.** With a key, the catalog refresh also calls
`GET /api/v1/models/user`, the list of models that still have an endpoint
under the account's privacy settings and guardrails (ZDR toggles, training
opt-outs, ignored providers). The catalog browser greys the others out and
hides them behind the "Available to me" filter (on by default), and the model
field warns before a request is sent. OpenRouter publishes no per-endpoint
data policy in its public API, so a ZDR flag independent of the account
cannot be shown; the account list and the ZDR switch are the two truthful
controls.

**When routing fails.** OpenRouter answers a request no endpoint can serve
(503 "no available model provider that meets your routing requirements") —
the app prefixes the message with what to do: pick another model in the
browser, or relax one of the three restrictions (account privacy page, the
document rule, the ZDR switch).

## Not used

OpenRouter's Files API (beta) only feeds its sandbox containers — no file id
can be referenced from chat messages — so documents keep riding base64 on the
attach turn. The paid `mistral-ocr` PDF engine is never requested.

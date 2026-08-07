# PlaudAddon — Plaud voice-recorder integration (shipped in 4.5)

The addon connects a personal Plaud account: in any chat the model can find
meeting recordings, read the AI summary tabs and the full transcripts;
recordings appear under the replies as chips with a full preview (tabs +
transcript + audio). It works with any provider — the tools execute on the
app's side.

## The protocol (verified against a live account, 2026-07-28)

The official `@plaud-ai/mcp` package is NOT an MCP proxy but a thin REST
client. We reproduce it directly in Swift, without Node:

- **API**: `https://platform.plaud.ai/developer/api`
  - `GET /open/third-party/users/current` — the profile
  - `POST /open/third-party/users/current/revoke` — revoke access
  - `GET /open/third-party/files/?page=&page_size=` — the recording list
  - `GET /open/third-party/files/{id}` — a whole recording
- **OAuth** (authorization code + PKCE S256):
  - authorization: `https://web.plaud.ai/platform/oauth`
  - exchange/refresh: `platform.plaud.ai/developer/api/oauth/third-party/access-token[/refresh]`
  - a public `client_id` (`client_9c50…`), an empty secret (Basic `id:`)
  - the redirect is **strictly** `http://localhost:8199/auth/callback` — the port
    is baked into the client registration; our one-shot NWListener listens on
    loopback only
- **Tokens** — in the Keychain (`APIKeyStore.AuxKey.plaud`, one JSON blob),
  auto-refreshed 60 s before expiry + one retry on a 401.

### Session lifetime (worked out 2026-08-05)

A Plaud refresh token lives roughly the same week the access token does: an
account connected on 07-28 16:20 got a **401** on refresh by 08-05 08:49 — the
grant was dead, and nothing but a new browser sign-in can bring it back.

- **Classifying a refresh failure** (as `@plaud-ai/mcp` does): a `5xx` is their
  outage, so the tokens are NOT touched (`.transient`); any other non-200 is
  `invalid_grant`, and `PlaudClient.invalidateSession()` wipes the blob and
  calls `PlaudAddon.handleSessionExpired()`. A network failure is `.transient`
  too. Branch only on `PlaudError.kind`, never on the message text.
- **The indicator**: `isConnected` means "a blob is in the Keychain", which is
  NOT a live session. The truth comes from `PlaudAddon.verifyConnection()` — a
  single profile call, made when the settings tab opens (`.task`). Before 4.7
  the checkmark stayed green over a dead grant forever, while the tools failed
  silently every turn.
- **Reconnecting**: `PlaudSettings.needsReauth` (persisted) switches the account
  card to "Session expired → Reconnect" with the account name — instead of the
  neutral "not connected" the user never asked for.
- **Prevention**: `PlaudAddon.startSessionUpkeep()` (from
  `applicationDidFinishLaunching`) rotates the token pair at startup and every
  6 h if less than a day of access lifetime is left. As long as the Mac is
  switched on at least once a week the session survives; a week of downtime
  still kills the grant — and then the honest UI above takes over.
- **Models** receive the failure as a directive
  (`PlaudToolService.sessionExpiredResult`): don't retry, tell the user to
  reconnect in Settings → Plaud.

### The recording data model

- `note_list[]` — the summary tabs: `data_type` (`auto_sum_note`, `high_light`, …),
  `data_tab_name` ("Summary", "Highlights"), Markdown content.
- `source_list[]` — three blocks, each of which may or may not be present
  (checked against `@plaud-ai/mcp@0.3.7`, 2026-08-05): `transaction` — the
  verbatim transcript (a JSON array of `{start_time, end_time, content, speaker,
  original_speaker}` segments, in ms), `transaction_polish` — the same format
  but with the speech cleaned up by AI (about a quarter shorter), `outline` — a
  structural overview (it may arrive as prose rather than segments). Our
  `PlaudSourceBlock` holds their slugs, the tab order and the names for the
  model (`verbatim`/`clean`/`outline`); the `transaction` slug is `transcript`
  for compatibility with the old cache.
- ⚠️ **Trap**: an empty `data_content` means the content is behind `data_link` —
  a presigned S3 URL that lives **~5 minutes**. The rule: `content =
  data_content || fetch(data_link)`, fetched in the same call, and the links are
  never stored.
- `presigned_url` — an mp3, alive for 24 h; S3 serves Range, so streaming and
  seeking work.
  ⚠️ An empty `presigned_url` on a synced recording (it has a `duration` or a
  `source_list`) is a temporary signing failure on their side, not "there is no
  audio": keep the player in place with a hint, and the next tap tries again.
- An unprocessed recording (the user hasn't spent the credits): empty
  `note_list` and `source_list`, no `presigned_url`. Processing **cannot** be
  started through the API — the whole API is read-only (assigning speakers isn't
  possible either).
- Deep link into the web interface: `https://web.plaud.ai/file/<id>` (the format
  from the address bar of the Plaud app itself).

## Architecture (Cuate/Addons/PlaudAddon/)

| File | Role |
|---|---|
| `PlaudClient.swift` | actor: OAuth (PKCE, loopback callback, cancellation), REST, `data_link` resolution |
| `PlaudAddon.swift` | singleton: connect/disconnect, `isAvailable`, deep link |
| `PlaudToolService.swift` | the model's tools + chips + prompt hints (the CalendarToolService pattern) |
| `PlaudNoteCache.swift` | disk cache + `PlaudFormat` (durations, timecodes, transcript markdown) |
| `PlaudNotePreview.swift` | the preview window: tabs, transcript with clickable timecodes, AVPlayer + Now Playing |
| `PlaudChipView.swift` | the chip in the bubble + `PlaudBadge` (a black glyph on a white plate — the original livery) |
| `PlaudSettings(+View)` | the toggle, Connect/Disconnect, the "/plaud only" mode, the account card |
| `PlaudLocalization.swift` | the `PLL()` strings (en/es/ru) |

### The model's tools

- `plaud_find(query?, date_from?, date_to?, limit?)` — there are no server-side
  filters: with filters it paginates up to 5×100 and filters on the client (as
  the official MCP does).
- `plaud_get_note(file_id, tab?)` — all tabs (or one), Markdown.
- `plaud_get_transcript(file_id, version?, from_min?, to_min?)` —
  `[MM:SS] Speaker: …`, sliced by minutes, capped at 60k characters. `version`:
  `verbatim` (the default, word for word — for quotes and "who exactly said"),
  `clean` (AI-cleaned, shorter — for retellings and long recordings), `outline`.
  A missing version is not an "empty recording": the answer lists what is
  available.

The prompt hint: note first, transcript only if the summary wasn't enough;
unprocessed ones go on a separate line; what is found is attached as cards — so
don't duplicate raw IDs into the text. The gate in ChatService: the addon is on,
the model can do tools, and (`alwaysAvailable` OR the message starts with
`/plaud`).

### Chips and preview

- A chip is a `ChatAttachment` with its metadata **in the file path**
  (`PlaudNotes/<fileID>__<kind>__meta.json`; kind: note|unprocessed; the old
  per-tab `.md` paths from the first build are recognized too) — the SwiftData
  schema never changed. One chip per recording per turn; `plaud_find` produces
  chips too (an "everything about X" list is clickable without reading the
  notes).
- Delivery: the tool collects the chips → ChatService sends an
  `.attachments([ChatAttachment])` event → ChatWindow buffers until `deliver`
  (there is no bubble yet at tool time) with dedup by path.
- The preview (`PlaudNotePreview`): opens from cache instantly plus a background
  live refresh of the whole recording (all tabs + transcript). The transcript is
  always the leftmost tab; by default the first note tab is selected. Audio: an
  AVPlayer streaming from the presigned URL (fresh for each session), Now
  Playing (media keys, seeking), clicking a segment's timecode is seek+play;
  playback stops when the window closes (the window is retained — we listen to
  `willCloseNotification`, since onDisappear doesn't fire). The window is
  floating + `.canJoinAllSpaces, .fullScreenAuxiliary`.
- Cache: `Application Support/Cuate/PlaudNotes/` — a meta JSON + one `.md` per
  tab + the transcript (`.md` for humans plus the raw segment `.json` for
  timecodes).

### The "Chat files" panel (LocalChatFilesView)

A folder button in the header of ordinary chats (the counterpart of the agent
CHAT FILES): the model's documents (HTML/MD artifacts from fences, via the
parser cache), Plaud recordings, and the user's attachments; the actions are
open / reveal in Finder.

## Legal and brand

The approach is the user's personal access to their own data through Plaud's
public API (the same mechanism their MCP uses for Claude/Cursor); the wording is
"works with Plaud", with no implied partnership. The badge is the brand "Λ·"
glyph in the original livery (black on white); the glyph was cut out of the
wordmark (the favicon is opaque — template rendering produced a white square).
The attribution lives in THIRD-PARTY-NOTICES.md.

## Left out / what's next

- **The Hermes agent can't see Plaud**: client-side tools are not injected into
  an agent loop on someone else's host. The options: Plaud MCP on the agent's
  host / intercepting `/plaud` with a local model / forwarding tools through
  `/v1` (untested).
- **Semantic search** — the API only offers a substring match on names; a local
  summary index (NLEmbedding) is a separate phase.
- **Mind maps** — the format has never shown up in the API; check on a real note.
- Write operations (starting processing, speakers) — waiting for Plaud to ship a
  write API.

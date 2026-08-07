# Hermes API — live fixtures (test rig localhost:8642, Hermes 0.19.0, 2026-07-25)

Captured with curl against a real instance. The transport (`HermesTransport`) is written against
THIS file, not against the prose in the docs. When Hermes is upgraded on the rig — re-check and update.

## Enabling the API server (onboarding instructions)

In `~/.hermes/.env`:
```
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_KEY=<secret>
```
The API server lives inside the **gateway** process: `hermes gateway run` (or `install` as a service).
The Hermes desktop app does NOT bring the gateway up (its `serve --port 0` is a different thing).

## Authentication

`Authorization: Bearer <API_SERVER_KEY>`. A wrong key AND a missing key both give **401** (with no WWW-Authenticate body).

## `/v1/capabilities` (UI gating)

```json
{"object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "hermes-agent",
 "auth": {"type": "bearer", "required": true},
 "runtime": {"mode": "server_agent", "tool_execution": "server", "split_runtime": false},
 "features": {
   "chat_completions": true, "chat_completions_streaming": true,
   "responses_api": true, "responses_streaming": true,
   "run_submission": true, "run_status": true, "run_events_sse": true, "run_stop": true,
   "run_approval_response": true, "tool_progress_events": true, "approval_events": true,
   "session_resources": true, "model_options": true,
   "session_chat": true, "session_chat_streaming": true, "session_fork": true, "session_model_lock": true,
   "admin_config_rw": false, "jobs_admin": false, "memory_write_api": false,
   "skills_api": true, "audio_api": false, "realtime_voice": false,
   "session_continuity_header": "X-Hermes-Session-Id", "session_key_header": "X-Hermes-Session-Key",
   "cors": false},
 "endpoints": { /* method+path for each feature, see the full per-endpoint dump below */ }}
```

⚠️ On a default server **`admin_config_rw=false`, `jobs_admin=false`, `memory_write_api=false`** —
the "Jobs"/config/memory sections are gated on these flags (off → hide the section).

## `/v1/models`

A single pseudo-model: `{"object":"list","data":[{"id":"hermes-agent","object":"model","owned_by":"hermes",...}]}`.
Profiles would show up as separate ids. **The role list is built from here** (usually 1 role).

## Sessions

### POST `/api/sessions` `{"title":"..."}` → 
```json
{"object":"hermes.session","session":{"id":"api_1785015297_041aa50e","source":"api_server",
 "model":"hermes-agent","title":"cuate-fixture","started_at":1785015297.63,
 "message_count":0,"tool_call_count":0,"input_tokens":0,"output_tokens":0,
 "cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,
 "estimated_cost_usd":null,"parent_session_id":null,...}}
```

### ⚠️ A model lock is MANDATORY right after creation
A fresh session inherits the literal `model:"hermes-agent"` and fails on EVERY turn:
`HTTP 404: Model 'hermes-agent' not found` (even with explicit `model`+`provider` in the turn request —
`route_source` shows the attempt, but the runtime stays on the literal).

The cure: `POST /api/sessions/{id}/model {"model":"tencent/hy3:free","provider":"nous"}` →
`{"object":"hermes.session.model_lock","runtime":{...,"model_lock":"accepted"}}`.
After the lock, turns carry `route_source:"session_model_lock"`.
The model/provider pairs come from `/api/model/options` (see below).

**Cross-provider re-locking WORKS** (captured live 2026-07-29, the VPS gateway):
a session locked to openai-codex switches to `{"model":"stepfun/step-3.7-flash:free",
"provider":"nous"}` → `model_lock:"accepted"`, and the next turn has `route_source:
"session_model_lock"`, `runtime.provider:"nous"`, `model_lock:"confirmed"`. Changing the
provider mid-session is a routine operation.

### ⚠️ A provider's quota cooldown (captured live 2026-07-29)
When a provider (Codex) has exhausted its quota, the gateway puts it on cooldown and rejects
turns of sessions locked to it INSTANTLY: HTTP 200, SSE, but the error arrives as an
`assistant.completed` with the text `"⚠️ Provider authentication failed: Codex provider
quota exhausted (429); retry after 2590205s. Credentials are still valid."` —
and the turn's user row is NOT WRITTEN TO HISTORY (unlike a routing failure
mid-run, where the user row survives). The cooldown is ~30 days (a monthly quota).
The client detects this text and appends a "switch provider" hint
(`HermesAgentSession.annotateGatewayFailure`).

### ⚠️ The `/api/model/options` catalog is live and changeable
During a cooldown a provider's model list can SHRINK (live: openai-codex went from the
full list down to 1 model — on the older gateway an exhausted provider degraded to a
single saved model; fixed on the Hermes side 2026-07-29, and after the plan was
updated all 9 came back). The gateway fetches the Codex model list with a live
request to OpenAI on the user's account; it caches its own catalog for ~1 hour, and the route has
`?refresh=true` (cache reset, like the "Refresh Models" button in their dashboard).
Conclusions for the client: show the catalog EXACTLY as the gateway gives it (it is the source of
truth), but re-read it when returning to the panel (`HermesAddon.refreshCatalogIfStale`),
not only on the launch probe; and NEVER "heal"/reset the lock because a pair is missing
from the catalog — the truth about availability is only revealed by a real turn.

### GET `/api/sessions?limit=&offset=` — the list
Each element is rich: `id, source, model, title, started_at, ended_at, end_reason, message_count,
tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
reasoning_tokens, estimated_cost_usd, api_call_count, parent_session_id, last_active, preview,
has_system_prompt` — enough for the "Sessions" section with no extra requests.

### GET `/api/sessions/{id}/messages`
```json
{"object":"list","session_id":"...","data":[
 {"id":3,"session_id":"...","role":"user","content":"...","tool_call_id":null,"tool_calls":null,
  "tool_name":null,"timestamp":1785015309.72,"token_count":null,"finish_reason":null,
  "reasoning":null,"reasoning_content":null},
 {"id":6,"role":"assistant","content":"pong","finish_reason":"stop","reasoning":"..."}]}
```
- **`id` is an integer, monotonic within the session → our `seq`.**
- Our `externalID` is `"<session_id>#<id>"`.
- The user messages of FAILED turns are recorded too (routing failed — the user row stayed);
  assistant errors are not written to history.
- Roles: user / assistant / tool (a tool's `content` is JSON `{"output","exit_code","error"}`).

## Chat stream: POST `/api/sessions/{id}/chat/stream` `{"input":"..."}`

SSE frames `event: <name>\ndata: <json>`; every `data` carries `session_id`, `run_id`, `seq` (numbering
the frames of THIS run, not the messages), and `ts`. The order of a real turn with a tool:

```
run.started        {"user_message":{"role":"user","content":"..."},"runtime":{...}}
message.started    {"message":{"id":"msg_<hex>","role":"assistant"}}
tool.started       {"message_id":"msg_...","tool_name":"terminal","preview":"echo cuate-test-123",
                    "args":{"command":"echo cuate-test-123"}}
tool.completed     {"message_id":"...","tool_name":"terminal","preview":null,"args":null}
assistant.delta    {"message_id":"...","delta":"\n\ncu"}     ← only when the model streams
tool.progress      {"message_id":"...","tool_name":"_thinking","delta":"..."}  ← internal, "_thinking" must not be shown as a tool
assistant.completed{"message_id":"...","content":"<FULL text>","completed":true,"partial":false,
                    "interrupted":false,"runtime":{...}}
run.completed      {"completed":true,"messages":[<the whole turn transcript: assistant+tool_calls,
                    tool results, the final assistant>],
                    "usage":{"input_tokens":35019,"output_tokens":31,"total_tokens":35050,...}}
done               {}
```

⚠️ **A client trap (a live bug, 2026-07-25):** `URLSession.AsyncBytes.lines`
SKIPS empty lines — an SSE parser waiting for the blank separator line never
assembles a single frame (every turn ended with zero events and "(empty
reply)", and the answer was found later by the mirror). A frame is dispatched on the
`data:` line (the Hermes payload is single-line JSON).

⚠️ **Interim messages:** a single run can emit SEVERAL assistant messages
("Let me check first…" → tools → the answer; `display.interim_assistant_messages`).
Each arrives with its own `message.started` → `assistant.completed` pair.
Glue them into one bubble with a blank line — replacing with the last one lost text.

Conclusions for the transport:
- The text may arrive ONLY in `assistant.completed` (without a single delta — e.g. a short answer
  or `streaming.enabled:false` in the agent's config). Render the deltas, then on completed
  verify/replace with the full text.
- A turn's error arrives NOT as an HTTP error but as an `assistant.completed` carrying the error text
  (`"HTTP 404: Model ... not found"`). The stream's HTTP status is 200. There is nothing to detect it by, so we show it as a reply.
- The `usage` in `run.completed` is the SUM OVER ALL API CALLS of the run, not the prompt size
  (captured live 2026-07-30: a turn without tools → `input_tokens:17915`; the same context with
  2 tool calls → `35990`). It is NOT suitable for a context gauge — a 26-step turn "used" 2188K
  against a 1050K window. There are no hidden fields: the full set is `input/output/total_tokens` + `runtime{...}`.
- `usage.context_tokens` is OUR carried gateway patch (api_server.py, both usage dicts in
  `_run_agent`): `agent.context_compressor.last_prompt_tokens` — the prompt of the LAST call,
  the same number the Hermes status bar shows. That is the actual context fill; a stock gateway
  (VPS) doesn't send the field → the client falls back to the summed value capped by the window.
- `tool.started.args` — the command body is there, which is enough for the approval card / step log.
- `_thinking` in `tool.progress` is the reasoning stream, not a tool.

## Approvals (captured live 2026-07-25 — THERE ARE NO MID-RUN APPROVALS IN 0.19.0)

Verified on the rig:
- `terminal` on the local backend is NOT gated: `echo`, `sudo -n whoami` run immediately.
- `skills.write_approval: true` → `skill_manage create` returns a staged result AS AN
  ORDINARY tool result: `{"success":true,"staged":true,"pending_id":"c2c24583",
  "message":"Staged for approval… review with /skills pending"}`. The run is NOT paused,
  no `approval.*` SSE events arrive; the review is asynchronous through the CLI `/skills pending`.
  There is no REST access to the pending queue in 0.19.0 (it is absent from capabilities.endpoints).
- ⚠️ Observation: the model BYPASSED the staged gate by writing SKILL.md directly via `write_file`
  (an argument for showing the backend/isolation in our UI and for `skills.guard_agent_created`).

`features.approval_events:true` and `run_approval_response:true` are nevertheless declared —
the `POST /v1/runs/{run_id}/approval` endpoint exists. Conclusion: event-based approvals belong
to a different path (or a future version). Our approval UI is wired to the `approval.*` frames of the
session stream and lies dormant until the gateway sends them; the resolve request's body
(`{"approval_id","approved"}`) is a best guess — re-check it on the first live frame.

## `/v1/skills` → `{"data":[{"name":"apple-notes","description":"...","category":"apple"},...]}`

## `/v1/toolsets` → rich:
```json
{"object":"list","platform":"api_server","data":[
 {"name":"web","label":"🔍 Web Search & Scraping","description":"web_search, web_extract",
  "enabled":true,"configured":true,"tools":["web_extract","web_search"]},
 {"name":"browser","label":"🌐 Browser Automation",...},
 {"name":"terminal","label":"💻 Terminal & Processes",...}]}
```
The label already carries the emoji — the "Skills/Toolsets" section is drawn from this as is.

## `/api/model/options` → providers and models for the "Agent" section
```json
{"providers":[{"slug":"nous","name":"Nous Portal","is_current":true,"is_user_defined":false,
  "models":["anthropic/claude-fable-5","anthropic/claude-opus-5",...]},...]}
```
The (provider, model) pairs from here go into the session's model lock.

## Image attachments in session chat (captured 2026-07-25)

`input` accepts NOT only a string but also an array of OpenAI parts:
```json
{"input":[{"type":"text","text":"..."},
          {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}]}
```
This works (the model sees the image). A flat `images:[...]` field does NOT break the request,
but the image never reaches the model — don't use it.

## GET `/api/model/info` — the context window of the agent's CURRENT model

⚠️ The route is newer than some deployments: it exists in the 0.19.0 checkout (2026.7.20)
(`hermes_cli/web_server.py`), but the VPS gateway is older — **404** (verified
2026-07-29 on agent.<domain>; `/api/model/options` is alive there → 401 without
a key). The client must survive a 404 as "no data". The response shape comes from the
sources (there was nothing to capture a live 200 dump from):

```json
{"model":"gpt-5.6-terra","provider":"...",
 "auto_context_length":272000,"config_context_length":0,
 "effective_context_length":272000,
 "capabilities":{"supports_tools":true,"supports_vision":true,
   "supports_reasoning":true,"context_window":272000,
   "max_output_tokens":128000,"model_family":"..."}}
```

`effective_context_length` is what the agent actually lives by (its own resolution
chain: config override → cache → provider probes → models.dev →
table → 256K). It covers the CURRENT configured model only (+`?profile=`);
an arbitrary model/provider pair cannot be queried. It is used by the context
gauge (`HermesModelContext`); on a miss → a port of its `DEFAULT_CONTEXT_LENGTHS`
table → the `hermes.contextLimitTokens` setting.

## Top level of `/api/model/options` (captured 2026-07-25)

Besides `providers[]`, the root also has **`model` and `provider`** — the agent's CURRENT pair.
That is exactly what we use for the model lock when the user picks "as configured on the agent".

## Audio (STT/TTS) — verified against the 0.19.0 sources

`"audio_api": False` is **hardcoded** in `gateway/platforms/api_server.py:2829` —
the API server has no audio endpoints and they cannot be enabled by config. The Hermes TTS/STT
(`tools/tts_tool.py`, `tools/transcription_tools.py`) are the AGENT's tools on
its host: "read it out and give me the path" already works today (our chip opens the file).
Voice messages in the composer are transcribed by OUR STT pipeline (deliberately: audio cannot be
sent through the API). Should audio_api appear in newer versions, the capability gate
will pick it up, and then an "STT/TTS on the agent's side" toggle becomes possible.

## Open / for later
- [ ] A live fixture of an approval event (stage 6).
- [ ] Pagination of `/api/sessions/{id}/messages` (limit/offset? check during cursor backfill, stage 5).
- [ ] `/v1/runs` + `/v1/runs/{id}/events` as an alternative channel (stop/approve are tied to run_id;
      run_id already arrives in every session-stream frame — stop should work as is).
- [ ] What turns `jobs_admin`/`admin_config_rw` on for the server (env flags?) — for the "Jobs" section.

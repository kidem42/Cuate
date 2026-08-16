# cuate-plaud — Plaud recordings for a Hermes agent

Three read-only tools over the [Plaud](https://www.plaud.ai) developer API, so a
self-hosted [Hermes agent](https://github.com/NousResearch/hermes-agent) can
answer from the user's recorded meetings — on every surface it has, not just
inside the app that holds the account.

| Tool | What it does |
|---|---|
| `plaud_find` | Locate recordings by name fragment and/or date range |
| `plaud_get_note` | Read a recording's AI summary — every tab Plaud produced |
| `plaud_get_transcript` | Read the verbatim transcript, timecoded, optionally windowed |

## Identifiers, not content

Every recording the tools name carries a `plaud://<file_id>` marker. The
[Cuate](https://github.com/kidem42/Cuate) client recognizes it and renders the
recording as a card — summary tabs, timecoded transcript, playable audio —
resolved with the user's own grant on the user's own device. Nothing of the
recording travels through the agent: Plaud's content links expire in about five
minutes, and a pasted transcript would burn the agent's context to draw
something worse. Any other client just sees a harmless token.

## Install

```bash
# 1. the plugin itself
scp -r cuate-plaud USER@AGENT-HOST:~/.hermes/plugins/
ssh USER@AGENT-HOST 'hermes plugins enable cuate-plaud'

# 2. the skill — this is what tells the agent WHEN to reach for the tools
#    (a plugin-registered skill is deliberately kept out of the system prompt's
#    skill index, so it goes into the normal skills tree instead)
ssh USER@AGENT-HOST 'mkdir -p ~/.hermes/skills/plaud'
scp cuate-plaud/skill/SKILL.md USER@AGENT-HOST:~/.hermes/skills/plaud/

# 3. restart the gateway FROM SSH, never from inside an agent turn —
#    the agent would be killing the process it is running in
ssh USER@AGENT-HOST 'export XDG_RUNTIME_DIR=/run/user/$(id -u) && \
  systemctl --user restart hermes-gateway'
```

Verify: `hermes tools | grep plaud` lists the three tools.

## Access

The tools read `~/.hermes/plaud.json` (chmod 600):

```json
{ "access_token": "…", "refresh_token": "…" }
```

Cuate writes it for you — **Settings → Plaud → "Give the agent access"** — for a
local gateway directly, for a remote one through the dashboard files API.
`PLAUD_ACCESS_TOKEN` / `PLAUD_REFRESH_TOKEN` work too. The plugin refreshes the
access token by itself and writes the new pair back, so a long-lived gateway
keeps working untouched.

Access is **read-only** — the developer API exposes no route that alters a
recording — and revocable at any time from the Plaud app. Note that this is a
real handover: the agent host holds a copy of the grant and can read the library
on every surface the agent has.

## Notes

- Recordings Plaud has not processed yet have no summary and no transcript, and
  processing **cannot** be started through the API. The tools flag them and hand
  back a deep link into Plaud's web app.
- User plugins import as `hermes_plugins.<name>`, so the modules use relative
  imports; the bundled-plugin form (`from plugins.x import y`) would not resolve.

MIT. Not affiliated with Plaud Inc.; "Plaud" is their trademark.

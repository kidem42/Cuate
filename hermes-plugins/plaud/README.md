# plaud — Plaud recordings for a Hermes agent

Three read-only tools over the [Plaud](https://www.plaud.ai) developer API, so a
self-hosted [Hermes agent](https://github.com/NousResearch/hermes-agent) can
answer from the user's recorded meetings — on every surface it has, not just
inside the app that holds the account.

Client-agnostic by design: the tools hand back identifiers, not content, so any
surface renders what it can. Built by the authors of
[Cuate](https://github.com/kidem42/Cuate), whose macOS and Android clients
render those identifiers as full recording cards (see
[Rendering the marker](#rendering-the-marker)).

| Tool | What it does |
|---|---|
| `plaud_find` | Locate recordings by name fragment and/or date range |
| `plaud_get_note` | Read a recording's AI summary — every tab Plaud produced |
| `plaud_get_transcript` | Read the verbatim transcript, timecoded, optionally windowed |

## Install

```bash
scp -r plaud USER@AGENT-HOST:~/.hermes/plugins/
ssh USER@AGENT-HOST 'hermes plugins enable plaud'
# restart FROM SSH, never from inside an agent turn — the agent would be
# killing the process it is running in
ssh USER@AGENT-HOST 'export XDG_RUNTIME_DIR=/run/user/$(id -u) && \
  systemctl --user restart hermes-gateway'
```

Verify with `hermes tools | grep plaud`.

## Connect an account

```bash
hermes plaud login              # opens a browser, stores the grant
hermes plaud login --no-browser # server: prints the URL, reads the code back
hermes plaud status             # who is connected, and from where
hermes plaud logout             # remove the grant from this host
```

`--no-browser` exists because a server has no browser *and* its localhost is not
the user's: the OAuth redirect can never arrive there. The flag prints the
authorization URL, the user approves it on their own machine, and pastes the
`code` from the address bar back into the terminal.

The grant is stored at `$HERMES_HOME/plaud/auth.json` (chmod 600) and refreshed
by the plugin itself. `PLAUD_ACCESS_TOKEN` / `PLAUD_REFRESH_TOKEN` work too, for
setups that provision agents from configuration.

Hermes' shared `auth.json` is core-only — its writers are private and its
provider registry is a fixed list — so, like other credential-holding plugins
(`google_meet` keeps its own store the same way), this plugin owns its file.

Access is **read-only**: the developer API exposes no route that alters a
recording. Revoke it any time from the Plaud app, or with `hermes plaud logout`
to remove it from this host only.

## How recordings come back

Every recording the tools name carries a reference — by default the marker
`plaud://<file_id>`. Content links from Plaud expire in about five minutes and a
pasted transcript would burn the agent's context, so the tools return an
identifier and let the client decide what to draw: a client that understands the
marker renders the recording with its summary tabs, timecoded transcript and
playable audio; anything else sees a short token.

Set `PLAUD_REFERENCE_STYLE` to change the shape — `marker` (default), `link` (a
deep link into Plaud's web app, friendlier in messengers), or `id`.

### Rendering the marker

Any client can act on `plaud://<file_id>`: strip the marker from the text it
shows, resolve the id against Plaud with the user's own grant, and draw whatever
it can. That keeps the recording out of the agent's context entirely and leaves
presentation to the surface that knows its own capabilities.

[Cuate](https://github.com/kidem42/Cuate) implements it end to end and is the
reference for what the format makes possible: the marker leaves the reply text,
and the recording arrives as a card with every summary tab, the timecoded
transcript and inline audio — the same card an ordinary chat produces there.
Its parser is deliberately forgiving (the writer is a language model): markers
count wherever they land — inline, inside a markdown link, wrapped in backticks,
listed under a heading.

## Tests

```bash
python3 tests/test_plugin.py     # or: pytest tests
```

Standard library only — no network, no grant, no third-party runner. Besides
the tool behaviour they pin the **seam with Hermes**: handlers are called with a
positional dict (`tools/registry.py`), `check_fn` is consumed as `bool(fn())`,
and registration must survive a host without the prompt-section API. Both bugs
this plugin shipped lived exactly there, where logic-only tests never look.

## Notes

- Recordings Plaud has not processed yet have no summary and no transcript, and
  processing **cannot** be started through the API. The tools flag them and hand
  back a deep link into Plaud's web app.
- The plugin adds a short section to the agent's system prompt so it knows the
  library exists — and only while a grant is present, so an unconfigured host
  carries nothing.
- User plugins import as `hermes_plugins.<name>`, so the modules use relative
  imports; the bundled-plugin form (`from plugins.x import y`) would not resolve.
- Plaud's list route is picky about page size (`page_size=5` answers 422, while
  20 and 100 work), and documents no range — `list_files` normalizes into the
  window that is known to work rather than passing the number through.

MIT. Not affiliated with Plaud Inc.; "Plaud" is their trademark.

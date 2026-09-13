# Hermes on a VPS in 4 steps

You need: a VPS (Ubuntu 22/24, 2+ GB RAM) and a domain. The agent becomes
reachable from any network over HTTPS — no VPN.

This guide is self-sufficient: follow it yourself, or paste it whole into any
capable LLM and it will walk you through with your values filled in.

## Step 1 — DNS

At your domain registrar: two A-records pointing at the server's IP —
`agent` and `dash`. (Server IP: run `curl -s -4 ifconfig.me` on the server —
the `-4` matters, without it you may get an IPv6 address.)

## Step 2 — install (the only interactive step)

```bash
apt update && apt install -y curl && curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash && source ~/.bashrc && hermes
```

The wizard asks four things — answer:

1. **Quick Setup (Nous Portal)** → Enter, log in via the link in a browser
2. Terminal backend → **Local**
3. Egress firewall → **N**
4. Telegram → skip (or Ctrl+C at this step — everything needed is saved)

The agent opens a chat — say "hi", wait for the reply, exit (Ctrl+C).

## Step 3 — everything else in one paste

Replace `YOUR-DOMAIN` on the first line, then paste the whole block:

```bash
DOMAIN="YOUR-DOMAIN"

# API server (chat)
cat >> ~/.hermes/.env <<EOF
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_KEY=$(openssl rand -hex 24)
EOF
hermes gateway install

# Gateway patch (backup lands next to the file; each edit skips itself if
# already applied; repeat after a Hermes update, which overwrites the file):
# 1. usage.context_tokens + context_window — the real context fill/window
#    for the client gauge. The fill prefers the usage anchor (the last
#    response's exact provider-reported prompt+completion — what /context
#    itself shows since Hermes gained usage-anchored context accounting)
#    and falls back to last_prompt_tokens on older installs. An older v3
#    fill line upgrades in place; a Hermes that ships the fields natively
#    is left untouched.
# 2. Detached session runs — stock Hermes INTERRUPTS a live run when the
#    session SSE client disconnects, so a backgrounded phone or a network
#    flap killed the agent mid-task ("Operation interrupted" in the chat).
#    Patched, the run finishes on its own and clients recover the reply
#    from the transcript. An explicit Stop still works (/v1/runs/{id}/stop).
# Anchored by code, not line numbers: recognizes Hermes up to 0.21.0 (one
# usage entry per line, the disconnect call closing on its own line) and
# 0.21.1 (packed usage dict, hugged bracket); refuses any other layout
# without touching the file.
HERMES_DIR=$(hermes --version | sed -n 's/^Install directory: //p') python3 - <<'PYEOF'
import os, re, pathlib
p = pathlib.Path(os.environ["HERMES_DIR"]) / "gateway/platforms/api_server.py"
src = orig = p.read_text()
fill_v3 = '"context_tokens": max(0, getattr(getattr(agent, "context_compressor", None), "last_prompt_tokens", 0) or 0),'
fill = '"context_tokens": (lambda _a, _c: max(0, int(_a["prompt_tokens"]) + int(_a.get("completion_tokens") or 0)) if isinstance(_a, dict) and _a.get("prompt_tokens") else max(0, getattr(_c, "last_prompt_tokens", 0) or 0))(getattr(agent, "_usage_anchor", None), getattr(agent, "context_compressor", None)),'
window = '"context_window": max(0, getattr(getattr(agent, "context_compressor", None), "context_length", 0) or 0),'
total = '"total_tokens": getattr(agent, "session_total_tokens", 0) or 0'
if fill in src:
    print("context_tokens: v4 already in place")
elif fill_v3 in src:
    src = src.replace(fill_v3, fill)
    print("context_tokens: upgraded v3 -> v4 (usage-anchored)")
elif '"context_tokens"' in src:
    print("context_tokens: native upstream - leaving as is")
else:
    # Up to 0.21.0 the usage dict holds one entry per line (trailing comma);
    # 0.21.1 packs "total_tokens" and the closing brace on one line.
    pat = re.compile(r'^(\s*)' + re.escape(total) + r'(,|\})$', re.M)
    src, n = pat.subn(lambda m: m.group(1) + total + ",\n" + m.group(1) + fill + ("" if m.group(2) == "," else "\n" + m.group(1) + "}"), src)
    assert n >= 1, "context anchor not found - different Hermes version, patch by hand"
    print(f"context_tokens: ok, {n} site(s)")
if '"context_window"' in src:
    print("context_window: already patched")
else:
    pat = re.compile(r'^(\s*)(' + re.escape(fill) + r')$', re.M)
    src, n = pat.subn(lambda m: m.group(0) + "\n" + m.group(1) + window, src)
    assert n >= 1, "context_window anchor not found - different Hermes version, patch by hand"
    print(f"context_window: ok, {n} site(s)")
if "continues detached" in src:
    print("detached runs: already patched")
else:
    call = (
        '            await self._drain_session_stream_task_on_disconnect(\n'
        '                run_id, task, interrupt_message="SSE client disconnected", shield_wait=False'
    )
    log = '            logger.info("Session SSE client disconnected; interrupted live run %s", run_id)'
    new = '            logger.info("Session SSE client disconnected; run %s continues detached", run_id)'
    # Up to 0.21.0 the call closes on its own line; 0.21.1 hugs the bracket.
    old = next((o for o in (call + '\n            )\n' + log, call + ')\n' + log) if o in src), None)
    assert old, "disconnect anchor not found - different Hermes version, patch by hand"
    src = src.replace(old, new)
    print("detached runs: ok")
# Repair a retained old inventory after the pricing module was split out.
# Stock old/new installs are no-ops; preserve every unrelated local edit.
catalog = p.parents[2] / "hermes_cli/inventory.py"
models = p.parents[2] / "hermes_cli/models.py"
pricing = p.parents[2] / "hermes_cli/models_pricing.py"
catalog_orig = catalog_new = None
if all(f.is_file() for f in (catalog, models, pricing)):
    definition = r"(?m)^def _format_price_per_mtok\("
    if re.search(definition, pricing.read_text()) and not re.search(definition, models.read_text()):
        catalog_orig = catalog.read_text()
        catalog_new = re.sub(
            r"(?m)^([ \t]*)from hermes_cli\.models import \(\n[ \t]*_format_price_per_mtok,\n",
            r"\1from hermes_cli.models_pricing import _format_price_per_mtok\n\1from hermes_cli.models import (\n",
            catalog_orig)
        catalog_new = re.sub(
            r"(?m)^([ \t]*)from hermes_cli\.models import _format_price_per_mtok$",
            r"\1from hermes_cli.models_pricing import _format_price_per_mtok", catalog_new)
# Validate BOTH candidates before either file changes. No module is imported
# here: patching must not load credentials or contact provider APIs.
import ast
ast.parse(src)
if catalog_new is not None:
    ast.parse(catalog_new)
if src != orig:
    pathlib.Path(str(p) + ".bak").write_text(orig)
    p.write_text(src)
    print("written; backup at api_server.py.bak")
else:
    print("nothing to do")
if catalog_new is not None and catalog_new != catalog_orig:
    pathlib.Path(str(catalog) + ".bak").write_text(catalog_orig)
    catalog.write_text(catalog_new)
    print("model catalog: repaired pricing import; backup at inventory.py.bak")
else:
    print("model catalog: no repair needed")
PYEOF
hermes gateway restart

# Dashboard (files) + the one token used everywhere
DASHTOKEN=$(openssl rand -hex 24)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$DASHTOKEN" >> ~/.hermes/.env
HB=$(command -v hermes)
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Dashboard
After=network-online.target
[Service]
ExecStart=$HB dashboard --no-open
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now hermes-dashboard

# HTTPS (Caddy issues and renews certificates by itself)
apt install -y caddy
cat > /etc/caddy/Caddyfile <<EOF
agent.$DOMAIN {
    reverse_proxy 127.0.0.1:8642 {
        flush_interval -1
    }
    request_body {
        max_size 64MB
    }
}
dash.$DOMAIN {
    @noauth not header Authorization "Bearer $DASHTOKEN"
    respond @noauth 401
    reverse_proxy 127.0.0.1:9119 {
        header_up Host 127.0.0.1:9119
    }
    request_body {
        max_size 64MB
    }
}
EOF
systemctl reload caddy

# Teach the agent about itself
grep -q "Self-maintenance" ~/.hermes/SOUL.md 2>/dev/null || cat >> ~/.hermes/SOUL.md <<'EOF'

## Self-maintenance
You run on your own VPS with full rights — maintain yourself.
- Code: /usr/local/lib/hermes-agent; config and data: ~/.hermes
- Your services: export XDG_RUNTIME_DIR=/run/user/$(id -u), then
  systemctl --user restart hermes-gateway | hermes-dashboard;
  logs: journalctl --user -u hermes-gateway -n 50
- Install packages freely (apt, pip) — the environment is persistent.
- Do NOT update yourself unless the user explicitly asks.
- Never touch ~/.hermes/state.db or its -wal/-shm files: no moving, renaming,
  replacing, repairing, `.recover`, `hermes sessions repair`, `hermes doctor --fix`.
  The operator recovers the database from an external shell with the gateway
  stopped. If the state database reports corruption, say so and stop.
EOF

# Verify and print the app values
sleep 8
echo "════════════════════════════════════════════"
curl -s https://agent.$DOMAIN/health && echo " ← should say ok"
# Body-limit self-check for the FILE domain: an 11 MB POST must come back as
# anything except 413 (401/404 mean the proxy passed it through). A 413 here
# caps every file attachment at the proxy's limit — this one matters.
head -c 11000000 /dev/zero | curl -s -o /dev/null -w "dash body-limit: %{http_code} (413 = file uploads capped)\n" -X POST "https://dash.$DOMAIN/api/files/upload-stream" --data-binary @-
# (agent.$DOMAIN carries only text + downscaled inline images, so its body
# limit is a non-issue in practice — the lone exception is GIFs over ~7 MB,
# which travel uncompressed. Probe the same way against /v1/chat if you care.)
echo "Gateway address:  https://agent.$DOMAIN"
echo "Key:              $(grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2)"
echo "Dashboard URL:    https://dash.$DOMAIN"
echo "Dashboard token:  $DASHTOKEN"
echo "════════════════════════════════════════════"
```


The patch also repairs the known old `inventory.py` pricing import when Hermes
has moved `_format_price_per_mtok` to `hermes_cli.models_pricing`. It backs up
that file separately; stock old/new installations need no catalog edit.
Restart from an external terminal, not the agent's own gateway session. Then
refresh the model list in Cuate: an active service and valid Python syntax do
not prove that `/api/model/options` can execute successfully.

## Step 4 — the app

Cuate → Settings → **Hermes Agent**: paste the four values printed above →
"Check & save" → `✓ hermes-agent`. Done: the 🪽 role appears in the switcher,
sessions in the sidebar, files and images work.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| Check returns 401 right after install | warm-up — retry in 10 sec |
| `502 Bad Gateway` | the gateway is restarting — wait 30–60 sec |
| health does not answer | `systemctl --user status hermes-gateway`; DNS may not have propagated — check `dig +short agent.YOUR-DOMAIN` |
| File upload → `Unauthorized` | the app's token ≠ `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env` |
| File uploads over ~10 MB fail (413) | proxy body limit below 64 MB on `dash.` (or on `agent.`, but only oversized inline GIFs ever hit that one) — rerun the body-limit self-check from Step 3; in Caddy: `request_body { max_size 64MB }`, in nginx: `client_max_body_size 64m` (rewrite the config file whole, never append a duplicate directive, and `nginx -t` before reloading) |
| The agent's terminal does not work at all | egress firewall was enabled — set `proxy.enabled: false` in `~/.hermes/config.yaml` + restart the gateway |
| The agent "cannot see" files/images | Docker terminal backend is still active: set `backend: local` in config.yaml **and** delete the `TERMINAL_ENV=docker` line from `.env`, restart |
| Turns come back empty, `state database reported structural corruption` | stop the gateway and the dashboard, then the offline recovery of Hermes itself: `hermes sessions recover --source ~/.hermes/state.db --inspect-only`, then `--output ~/recovered.db` (add `--allow-partial` when it stops at a damaged range), verify the counts, move the live `state.db`, `-wal`, `-shm` aside together, copy the recovered file in, `hermes sessions repair --check-only`, start. Never `hermes doctor --fix` on a live gateway, never `sqlite3 .recover` on the live file |
| `state database file was replaced underneath this process` right after a recovery | the agent executed a stale plan from its own session and swapped the file under the running gateway (SOUL.md rule above forbids it): stop the gateway, put the intended `state.db`, `-wal`, `-shm` back under their names, move the agent's file aside, start, and continue in a NEW session |
| Something broke after `hermes update` | roll back: `cd /usr/local/lib/hermes-agent && git fetch --unshallow; git checkout <previous commit> && systemctl --user restart hermes-gateway` |

## If ports 80/443 are already taken on the server

Step 3 assumes a clean server. If another web stack already owns 80/443,
Caddy will not bind; your existing proxy must provide (hand these
requirements plus this file to an LLM — the config follows from them):

- `agent.domain` → `127.0.0.1:8642`: **no buffering** (SSE),
  read timeout ≥ 3600 s, body ≤ 64 MB;
- `dash.domain` → `127.0.0.1:9119`: a Bearer gate comparing against
  `$DASHTOKEN` (in nginx put it in the location context, not the server
  context — otherwise the ACME challenge gets blocked and no certificate is
  ever issued), rewrite `Host` to `127.0.0.1:9119`, body ≤ 64 MB;
- proven for jwilder/nginx-proxy: `alpine/socat` bridge containers with
  `VIRTUAL_HOST`/`LETSENCRYPT_HOST`, gateway on `API_SERVER_HOST=0.0.0.0`
  plus `ufw allow from 172.16.0.0/12`, vhost.d configs written **only by
  full rewrite** (`cat >`), and `docker exec nginx-proxy nginx -t` before
  every reload.

---

## Appendix — the nginx-proxy recipe (a server that already hosts other apps)

A self-hosted [Hermes agent](https://github.com/NousResearch/hermes-agent) on a
VPS makes the same agent reachable from the desktop and the Android app from any
network — no VPN. This recipe was debugged end-to-end on a real server (Ubuntu
24.04 with a dockerized `jwilder/nginx-proxy` + letsencrypt-companion already
serving other apps); every trap below cost real time. It is written to be
self-sufficient: **paste it into any capable LLM and it will walk you through**.

```bash
# 1) Install + configure (interactive wizard: Quick Setup / Nous Portal;
#    terminal backend: Docker; egress firewall: N — see traps)
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc && hermes

# 2) API server (chat) — loopback-invisible from the internet, proxied later
cat >> ~/.hermes/.env <<EOF
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_HOST=0.0.0.0
API_SERVER_KEY=$(openssl rand -hex 24)
EOF
hermes gateway install          # systemd service, survives reboots
ufw allow from 172.16.0.0/12 to any port 8642 proto tcp   # docker nets only

# 3) Dashboard (file uploads) — systemd unit by hand (no `install` subcommand);
#    ONE token everywhere: nginx gate + dashboard + the apps
DASHTOKEN=$(openssl rand -hex 24)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$DASHTOKEN" >> ~/.hermes/.env
# unit: ExecStart=$(which hermes) dashboard --no-open  → enable --now
# socat relay 0.0.0.0:9120 → 127.0.0.1:9119 (ufw: docker nets only)

# 4) Expose through the existing proxy: per host `agent.` and `dash.` —
#    an alpine/socat bridge container with VIRTUAL_HOST/LETSENCRYPT_HOST,
#    plus a vhost.d/<host>_location file (see traps)

# 5) Sandbox must see uploads (config.yaml):
#    terminal:
#      docker_volumes:
#        - "/root/cuate-uploads:/root/cuate-uploads"
```

**The traps** (each one produced a live failure):

- `HERMES_DASHBOARD_SESSION_TOKEN` is the ONLY way external Bearer clients can
  call the dashboard files API — without it a random token is generated per
  restart and every upload gets `401` even on loopback (`web_server.py`,
  `auth_middleware` guards all `/api/*`).
- The **egress firewall** wizard option breaks the sandbox terminal entirely
  when the agent authenticates via Nous Portal OAuth (no provider keys in env →
  nothing to mint proxy tokens from). Answer `N`, or fix later with
  `proxy.enabled: false` in `~/.hermes/config.yaml` + gateway restart.
- The dashboard rejects foreign `Host` headers (DNS-rebinding guard, `400`) —
  the proxy must send `proxy_set_header Host "127.0.0.1:9119";`.
- Auth-gate `if (...) return 401;` goes into `vhost.d/<host>_location`, NOT the
  server-level file — otherwise it also blocks the ACME challenge and the
  certificate is never issued.
- SSE needs `proxy_buffering off;` and `proxy_read_timeout 3600s;` on the
  `agent.` host; `client_max_body_size 64m;` is needed on **BOTH** hosts —
  `dash.` for file uploads AND `agent.` for inline (pasted) images, which
  travel base64 in the chat request body and blow through nginx's default
  1 MB limit (surfaces as an opaque `AgentDiagnostic` turn error).
- With the Docker terminal backend the agent CANNOT see host files — mount
  `~/cuate-uploads` into the sandbox via `terminal.docker_volumes` (same path
  on both sides so courier notes stay valid).
- Check the server's IPv4 with `curl -4 ifconfig.me` — plain `ifconfig.me` may
  return IPv6 and DNS A-records will point at the wrong thing.

Then in the apps (Settings → Hermes Agent): gateway `https://agent.<domain>` +
`API_SERVER_KEY`; dashboard `https://dash.<domain>` + `DASHTOKEN`.

The same dashboard token also powers the **reverse courier**
(`/api/files/download`): files the agent creates on the VPS flow back into the
apps — preview cards, downloads, inline images — with no extra server setup.

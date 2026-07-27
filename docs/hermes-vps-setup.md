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
EOF

# Verify and print the app values
sleep 8
echo "════════════════════════════════════════════"
curl -s https://agent.$DOMAIN/health && echo " ← should say ok"
echo "Gateway address:  https://agent.$DOMAIN"
echo "Key:              $(grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2)"
echo "Dashboard URL:    https://dash.$DOMAIN"
echo "Dashboard token:  $DASHTOKEN"
echo "════════════════════════════════════════════"
```

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
| The agent's terminal does not work at all | egress firewall was enabled — set `proxy.enabled: false` in `~/.hermes/config.yaml` + restart the gateway |
| The agent "cannot see" files/images | Docker terminal backend is still active: set `backend: local` in config.yaml **and** delete the `TERMINAL_ENV=docker` line from `.env`, restart |
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

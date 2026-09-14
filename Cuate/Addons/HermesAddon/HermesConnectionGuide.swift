import Foundation

/// Localized walkthrough assembled offline. Commands are copied for the user
/// to run; opening the guide never connects to or changes a server.
enum HermesConnectionGuide {
    static func markdown(usesDomain: Bool, patch: String) -> String {
        let route = usesDomain ? "domain" : "tunnel"
        let parts = [
            "# " + HL("hermes.guide.title"),
            HL("hermes.guide.\(route).intro"),
            HL("hermes.guide.prerequisites"),
            "## " + HL("hermes.guide.prepare.title"),
            HL("hermes.guide.prepare.body"),
            HL("hermes.guide.prepare.update"),
            code("hermes update"),
            HL("hermes.guide.prepare.configure"),
            code("hermes setup"),
            HL("hermes.guide.prepare.check"),
            code("hermes"),
            "## " + HL("hermes.guide.server.title"),
            HL("hermes.guide.server.body"),
            code(serverCommands(patch: patch)),
            "## " + HL("hermes.guide.\(route).title"),
            HL("hermes.guide.\(route).body"),
            code(usesDomain ? domainCommands : tunnelCommands),
            "## " + HL("hermes.guide.fields.title"),
            HL("hermes.guide.\(route).fields"),
            HL("hermes.guide.keys"),
            "## " + HL("hermes.guide.verify.title"),
            HL("hermes.guide.verify.body"),
            HL("hermes.guide.\(route).restart"),
            "## " + HL("hermes.guide.trouble.title"),
            HL("hermes.guide.trouble.body"),
            code(runtimeCommands),
            HL("hermes.guide.maintenance"),
            "[Hermes](https://hermes-agent.nousresearch.com/docs/) · "
                + "[Caddy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) · "
                + "[uv](https://docs.astral.sh/uv/guides/install-python/)"
        ]
        return parts.joined(separator: "\n\n")
    }

    private static func code(_ text: String) -> String { "```bash\n" + text + "\n```" }

    /// Reuse the shipped, contract-tested transform, but select the known
    /// install and restart system services only after the whole setup succeeds.
    static func serverCommands(patch: String) -> String {
        let marker = "<<'EOF' && hermes gateway restart\n"
        guard let start = patch.range(of: marker),
              let end = patch.range(of: "\nEOF", options: .backwards),
              start.upperBound <= end.lowerBound else {
            return "echo 'Cuate: missing gateway patch; stop and contact support.'\nfalse"
        }
        let body = String(patch[start.upperBound..<end.lowerBound])
        return serverPrefix + "\nHERMES_DIR=\"$INSTALL\" \"$PYTHON\" - <<'EOF'\n"
            + body + "\nEOF\n" + serverSuffix
    }

    static let serverPrefix = #"""
    (
    set -eu
    [ "$(id -u)" = 0 ] || { echo 'Use the root VPS account for this guide.'; exit 1; }
    [ "$HOME" = /root ] || { echo 'Use a root login shell.'; exit 1; }
    INSTALL=/root/.hermes/hermes-agent
    PYTHON="$INSTALL/venv/bin/python"
    [ -f "$INSTALL/gateway/platforms/api_server.py" ] && [ -x "$PYTHON" ] || {
      echo 'Expected the standard Hermes install in /root/.hermes/hermes-agent.'; exit 1;
    }
    "$PYTHON" - <<'PY'
    import sqlite3
    from pathlib import Path
    from dotenv import dotenv_values, set_key
    import secrets
    import shutil
    import time

    v = sqlite3.sqlite_version_info
    if not (v >= (3, 51, 3) or (3, 50, 7) <= v < (3, 51, 0) or (3, 44, 6) <= v < (3, 45, 0)):
        raise SystemExit('SQLite ' + sqlite3.sqlite_version + ': see the Python/SQLite help below before continuing.')
    p = Path('/root/.hermes/.env')
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        backup = p.with_name('.env.cuate-backup-' + str(time.time_ns()))
        shutil.copy2(p, backup)
        backup.chmod(0o600)
    else:
        p.touch(mode=0o600)
    config = dotenv_values(p)
    values = {'API_SERVER_ENABLED': 'true', 'API_SERVER_HOST': '127.0.0.1', 'API_SERVER_PORT': '8642'}
    for key in ('API_SERVER_KEY', 'HERMES_DASHBOARD_SESSION_TOKEN'):
        values[key] = config.get(key) or secrets.token_hex(32)
    for key, value in values.items():
        set_key(str(p), key, value, quote_mode='always')
    p.chmod(0o600)
    print('Configuration saved; existing keys preserved.')
    PY
    """#

    static let serverSuffix = #"""
    if ! systemctl cat hermes-gateway.service >/dev/null 2>&1; then
      cat > /etc/systemd/system/hermes-gateway.service <<'UNIT'
    [Unit]
    Description=Hermes Agent Gateway
    Wants=network-online.target
    After=network-online.target
    [Service]
    User=root
    WorkingDirectory=/root/.hermes/hermes-agent
    Environment=HOME=/root
    ExecStart=/root/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=3600
    [Install]
    WantedBy=multi-user.target
    UNIT
    fi
    if ! systemctl cat hermes-dashboard.service >/dev/null 2>&1; then
      cat > /etc/systemd/system/hermes-dashboard.service <<'UNIT'
    [Unit]
    Description=Hermes Agent Dashboard
    Wants=network-online.target
    After=network-online.target
    [Service]
    User=root
    WorkingDirectory=/root/.hermes/hermes-agent
    Environment=HOME=/root
    ExecStart=/root/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main dashboard --no-open --host 127.0.0.1 --port 9119
    Restart=on-failure
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    UNIT
    fi
    systemctl daemon-reload
    systemctl enable hermes-gateway.service hermes-dashboard.service
    systemctl restart hermes-gateway.service hermes-dashboard.service
    "$PYTHON" - <<'PY'
    import json
    import time
    import urllib.request
    from dotenv import dotenv_values

    config = dotenv_values('/root/.hermes/.env')
    for name, url, key in (
        ('Gateway', 'http://127.0.0.1:8642/v1/capabilities', 'API_SERVER_KEY'),
        ('Dashboard', 'http://127.0.0.1:9119/api/model/options', 'HERMES_DASHBOARD_SESSION_TOKEN'),
    ):
        for attempt in range(15):
            try:
                request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + config[key]})
                with urllib.request.urlopen(request, timeout=5) as response:
                    json.load(response)
                print(name + ': OK')
                break
            except Exception as error:
                if attempt == 14:
                    raise SystemExit(name + ': ' + str(error))
                time.sleep(2)
    print('Gateway key (API_SERVER_KEY): ' + config['API_SERVER_KEY'])
    print('Dashboard token (HERMES_DASHBOARD_SESSION_TOKEN): ' + config['HERMES_DASHBOARD_SESSION_TOKEN'])
    print('Server setup complete. Continue with the connection step.')
    PY
    )
    """#

    static let tunnelCommands = #"""
    /bin/bash <<'CUATE_SETUP'
    set -eu
    SSH_HOST='YOUR_SERVER_IP'
    SSH_USER='root'
    SSH_PORT='22'
    SSH_KEY="$HOME/.ssh/YOUR_SSH_KEY"

    case "$SSH_HOST:$SSH_KEY" in *YOUR_*) echo 'Replace YOUR_SERVER_IP and YOUR_SSH_KEY first.'; exit 1;; esac
    [ -f "$SSH_KEY" ] || { echo 'SSH key file not found.'; exit 1; }
    /usr/bin/ssh-add --apple-use-keychain "$SSH_KEY" </dev/tty
    /usr/bin/ssh -i "$SSH_KEY" -p "$SSH_PORT" \
      -o UseKeychain=yes -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
      "$SSH_USER@$SSH_HOST" true

    LABEL=com.cuate.hermes-tunnel
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    SCRIPT="$HOME/Library/Application Support/Cuate/hermes-tunnel.sh"
    # Refuse ambiguous ownership instead of reporting another tunnel's health.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if /usr/sbin/lsof -nP -iTCP:18642 -sTCP:LISTEN >/dev/null 2>&1 || \
       /usr/sbin/lsof -nP -iTCP:19119 -sTCP:LISTEN >/dev/null 2>&1; then
      echo 'Ports 18642/19119 are busy. Stop the previous tunnel (including its autostart) first.'
      exit 1
    fi
    # PlistBuddy's quoted string syntax cannot represent an apostrophe here.
    case "$SCRIPT" in *"'"*) echo 'Home path contains an apostrophe; contact support.'; exit 1;; esac
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$SCRIPT")"
    if [ -f "$SCRIPT" ]; then cp -p "$SCRIPT" "$SCRIPT.backup"; fi
    {
      echo '#!/bin/bash'
      printf 'exec /usr/bin/ssh -NT -i %q -p %q ' "$SSH_KEY" "$SSH_PORT"
      printf '%s ' '-o UseKeychain=yes -o IdentitiesOnly=yes -o BatchMode=yes'
      printf '%s ' '-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3'
      printf '%s ' '-o ExitOnForwardFailure=yes'
      printf '%s ' '-L 127.0.0.1:18642:127.0.0.1:8642 -L 127.0.0.1:19119:127.0.0.1:9119'
      printf '%q\n' "$SSH_USER@$SSH_HOST"
    } > "$SCRIPT"
    chmod 700 "$SCRIPT"
    if [ -f "$PLIST" ]; then cp -p "$PLIST" "$PLIST.backup"; rm "$PLIST"; fi
    /usr/libexec/PlistBuddy \
      -c "Add :Label string $LABEL" \
      -c 'Add :ProgramArguments array' \
      -c 'Add :ProgramArguments:0 string /bin/bash' \
      -c "Add :ProgramArguments:1 string '$SCRIPT'" \
      -c 'Add :RunAtLoad bool true' \
      -c 'Add :KeepAlive bool true' \
      -c 'Add :ThrottleInterval integer 15' "$PLIST"
    plutil -lint "$PLIST"
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    for attempt in 1 2 3 4 5 6 7 8; do
      if curl -fsS --max-time 3 http://127.0.0.1:18642/health && \
         curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:19119/; then
        echo
        echo 'Tunnel ready. You can close Terminal.'
        exit 0
      fi
      sleep 2
    done
    echo 'Tunnel check failed. Check SSH access and whether ports 18642/19119 are already in use.'
    exit 1
    CUATE_SETUP
    """#

    static let domainCommands = #"""
    (
    set -eu
    DOMAIN='YOUR_DOMAIN'
    [ "$DOMAIN" != YOUR_DOMAIN ] || { echo 'Replace YOUR_DOMAIN first.'; exit 1; }
    [ "$(id -u)" = 0 ] || { echo 'Run on the VPS as root.'; exit 1; }
    case "$DOMAIN" in *[!a-zA-Z0-9.-]*|'') echo 'Use a domain name without https:// or a path.'; exit 1;; esac
    if [ -f /etc/caddy/Caddyfile ] || ss -ltnH '( sport = :80 or sport = :443 )' | grep -q .; then
      echo 'An existing web server needs its own proxy configuration. See the advanced VPS guide.'
      exit 1
    fi
    apt-get update
    apt-get install -y caddy
    TOKEN=$(/root/.hermes/hermes-agent/venv/bin/python - <<'PY'
    from dotenv import dotenv_values
    print(dotenv_values('/root/.hermes/.env')['HERMES_DASHBOARD_SESSION_TOKEN'])
    PY
    )
    case "$TOKEN" in *[!a-zA-Z0-9_-]*|'') echo 'Dashboard token needs manual Caddy escaping. Stop here.'; exit 1;; esac
    cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-cuate
    cat > /etc/caddy/Caddyfile <<CADDY
    agent.$DOMAIN {
        request_body {
            max_size 64MB
        }
        reverse_proxy 127.0.0.1:8642 {
            flush_interval -1
        }
    }
    dash.$DOMAIN {
        @noauth not header Authorization "Bearer $TOKEN"
        respond @noauth 401
        request_body {
            max_size 64MB
        }
        reverse_proxy 127.0.0.1:9119 {
            header_up Host 127.0.0.1:9119
        }
    }
    CADDY
    chown root:caddy /etc/caddy/Caddyfile
    chmod 640 /etc/caddy/Caddyfile
    caddy validate --config /etc/caddy/Caddyfile
    systemctl enable caddy
    systemctl restart caddy
    echo "Gateway address: https://agent.$DOMAIN"
    echo "Dashboard URL: https://dash.$DOMAIN"
    echo 'HTTPS configured. Certificate issuance needs DNS and inbound ports 80/443. Test the connection in Cuate.'
    )
    """#

    static let runtimeCommands = #"""
    (
    set -eu
    uv self update
    SERVICES=""
    trap 'if [ -n "$SERVICES" ]; then systemctl start $SERVICES; fi' EXIT
    for SERVICE in hermes-dashboard.service hermes-gateway.service; do
      if systemctl is-active --quiet "$SERVICE"; then
        systemctl stop "$SERVICE"
        SERVICES="$SERVICES $SERVICE"
      fi
    done
    uv python upgrade --reinstall 3.11
    /root/.hermes/hermes-agent/venv/bin/python -c 'import sqlite3; print("SQLite inside Hermes:", sqlite3.sqlite_version)'
    )
    """#
}

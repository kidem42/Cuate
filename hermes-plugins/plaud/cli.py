"""`hermes plaud` — login, status, refresh, logout.

Follows the shape Hermes uses for service auth (`hermes auth spotify`): a
browser round-trip with PKCE, a `--no-browser` mode for machines without one,
and status/logout beside it. The shared `auth.json` is core-only — its writers
are private and its provider registry is a fixed list — so the grant lives in
the plugin's own store, the way google_meet keeps its credentials.

On a server there is no browser AND its localhost is not the user's, so the
redirect can never arrive: `--no-browser` prints the URL, the user opens it on
their own machine and pastes back the `code` from the address bar. Same trick
Hermes' own remote-OAuth skill uses.

`refresh` is for a timer (see the README): it renews the pair before Plaud's
clock kills an idle grant, and retires the grant after `MAX_GRANT_AGE_DAYS`.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict

from . import client

# Plaud's public client (PKCE, empty secret) — the same identifiers their own
# MCP package ships with.
CLIENT_ID = "client_9c501dad-8a0d-40b2-a7b0-d1cb8787f674"
CLIENT_SECRET = ""
AUTHORIZE_URL = "https://web.plaud.ai/platform/oauth"
TOKEN_URL = f"{client.API_BASE}/oauth/third-party/access-token"
REDIRECT_URI = "http://localhost:8199/auth/callback"
CALLBACK_PORT = 8199
CALLBACK_PATH = "/auth/callback"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _authorize_url(challenge: str, state: str) -> str:
    query = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })
    return f"{AUTHORIZE_URL}?{query}"


def _exchange(code: str, verifier: str, state: str) -> Dict[str, Any]:
    body = urllib.parse.urlencode({
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier,
        "state": state,
    }).encode()
    request = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.add_header("Accept", "application/json")
    request.add_header("User-Agent", client.USER_AGENT)
    basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
    request.add_header("Authorization", f"Basic {basic}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:200]
        raise SystemExit(f"Plaud rejected the authorization code (HTTP {exc.code}): {detail}")
    access = payload.get("access_token") or payload.get("accessToken")
    refresh = payload.get("refresh_token") or payload.get("refreshToken")
    if not access:
        raise SystemExit("Plaud returned no access token.")
    tokens: Dict[str, Any] = {"access_token": access, "refresh_token": refresh or ""}
    expires_in = payload.get("expires_in")
    if isinstance(expires_in, (int, float)) and expires_in > 0:
        tokens["expires_at"] = int(time.time() + expires_in)
    return tokens


class _CallbackHandler(BaseHTTPRequestHandler):
    result: Dict[str, str] = {}

    def do_GET(self):  # noqa: N802 — BaseHTTPRequestHandler's naming
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != CALLBACK_PATH:
            self.send_response(404)
            self.end_headers()
            return
        params = urllib.parse.parse_qs(parsed.query)
        _CallbackHandler.result = {
            "code": (params.get("code") or [""])[0],
            "state": (params.get("state") or [""])[0],
        }
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"<html><body><h3>Plaud connected. You can close this tab.</h3></body></html>")

    def log_message(self, *_args):  # keep the CLI output clean
        return


def _login(args) -> None:
    verifier = _b64url(secrets.token_bytes(64))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    state = _b64url(secrets.token_bytes(16))
    url = _authorize_url(challenge, state)

    if getattr(args, "no_browser", False):
        print("Open this URL on a machine with a browser:\n")
        print(f"  {url}\n")
        print("After approving, the browser lands on a localhost address that will not")
        print("load — that is expected. Copy the `code` value out of its address bar.")
        code = input("code: ").strip()
        if not code:
            raise SystemExit("No code entered.")
        tokens = _exchange(code, verifier, state)
    else:
        server = HTTPServer(("127.0.0.1", CALLBACK_PORT), _CallbackHandler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()
        print("Opening the browser to connect Plaud…")
        print(f"If nothing opens, visit:\n  {url}\n")
        try:
            webbrowser.open(url)
        except (webbrowser.Error, OSError):
            # No browser on this machine (or it refused to start): the URL is
            # already printed above, and --no-browser is the way through.
            pass
        thread.join(timeout=180)
        server.server_close()
        result = _CallbackHandler.result
        if not result.get("code"):
            raise SystemExit(
                "No authorization arrived within three minutes.\n"
                "On a server use: hermes plaud login --no-browser"
            )
        if result.get("state") != state:
            raise SystemExit("State mismatch — start the login again.")
        tokens = _exchange(result["code"], verifier, state)

    # The retirement clock starts here (see client.MAX_GRANT_AGE_DAYS).
    tokens["granted_at"] = int(time.time())
    client.save_tokens(tokens)
    try:
        user = client._api("/open/third-party/users/current")
        who = user.get("nickname") or user.get("email") or "connected"
    except client.PlaudError:
        who = "connected"
    print(f"Plaud: {who}. Grant stored at {client.token_file()}")
    print(f"  retires on {_day(tokens['granted_at'] + client.MAX_GRANT_AGE)} unless signed in again;"
          f" `hermes plaud refresh` from a timer keeps it alive until then.")


def _day(stamp: Any) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(stamp)) if isinstance(stamp, (int, float)) else "unknown"


def _status(_args) -> None:
    source = client.token_source()
    if source == "none":
        print("Plaud: not connected. Run `hermes plaud login`.")
        return
    where = {
        "file": str(client.token_file()),
        "legacy-file": f"{client.legacy_token_file()} (legacy path — re-run `hermes plaud login` to move it)",
        "env": "PLAUD_ACCESS_TOKEN environment variable",
    }[source]
    try:
        tokens = client._load_tokens()
        user = client._api("/open/third-party/users/current")
    except client.PlaudError as exc:
        print(f"Plaud: grant present ({where}) but NOT working — {exc}")
        return
    print(f"Plaud: connected as {user.get('nickname') or user.get('email') or 'unknown'}")
    print(f"  grant: {where}")
    since = client.granted_at(tokens)
    if since is not None:
        print(f"  signed in {_day(since)}, retires {_day(since + client.MAX_GRANT_AGE)}"
              f" ({client.MAX_GRANT_AGE_DAYS}-day ceiling)")
    if isinstance(tokens.get("renewed_at"), (int, float)):
        print(f"  last renewed {_day(tokens['renewed_at'])}")


def _refresh(_args) -> None:
    """For a timer: exit 0 when the grant is fine (renewed or not yet due),
    1 when it is gone — the journal then carries the reason."""
    try:
        print(client.keep_alive())
    except client.PlaudError as exc:
        print(f"Plaud: {exc}", file=sys.stderr)
        raise SystemExit(1)


def _logout(_args) -> None:
    removed = []
    for path in (client.token_file(), client.legacy_token_file()):
        if path.exists():
            try:
                path.unlink()
                removed.append(str(path))
            except OSError as exc:
                raise SystemExit(f"Could not remove {path}: {exc}")
    if removed:
        print("Plaud: disconnected. Removed " + ", ".join(removed))
    else:
        print("Plaud: nothing stored on this host.")
    if os.environ.get("PLAUD_ACCESS_TOKEN"):
        print("Note: PLAUD_ACCESS_TOKEN is still set in the environment.")


def register_cli(subparser) -> None:
    """Wire `hermes plaud <action>`; called by the plugin's CLI registration."""
    actions = subparser.add_subparsers(dest="plaud_action")
    login = actions.add_parser("login", help="Connect a Plaud account (OAuth)")
    login.add_argument(
        "--no-browser", action="store_true",
        help="Print the URL and read the code back — for servers without a browser",
    )
    actions.add_parser("status", help="Show whether this host has a working Plaud grant")
    actions.add_parser(
        "refresh",
        help="Renew the session ahead of expiry (run from a timer); "
             f"retires the grant {client.MAX_GRANT_AGE_DAYS} days after the sign-in",
    )
    actions.add_parser("logout", help="Remove the stored Plaud grant from this host")


def handle(args) -> None:
    action = (getattr(args, "plaud_action", "") or "status").strip().lower()
    if action == "login":
        _login(args)
    elif action == "logout":
        _logout(args)
    elif action == "status":
        _status(args)
    elif action == "refresh":
        _refresh(args)
    else:
        print(f"Unknown action: {action}. Use login, status, refresh or logout.", file=sys.stderr)
        raise SystemExit(2)

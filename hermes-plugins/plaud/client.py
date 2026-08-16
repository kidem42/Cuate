"""Plaud developer-API client — the Python twin of Cuate's PlaudClient.swift.

Read-only by construction: the API exposes nothing that mutates a recording,
and this client calls three routes — list files, get file, resolve content.

Tokens come from ``$HERMES_HOME/plaud/auth.json`` — written by ``hermes plaud
login`` or handed over by the Cuate desktop app when the user grants the agent
access — or from the environment. The access token is refreshed on a 401 and
the new pair written back, so a long-lived gateway keeps working without anyone
touching the file again.
"""

from __future__ import annotations

import json
import os
import pathlib
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

API_BASE = "https://platform.plaud.ai/developer/api"
REFRESH_URL = f"{API_BASE}/oauth/third-party/access-token/refresh"
WEB_APP = "https://web.plaud.ai/"

# Presigned content links live ~5 minutes; fetch them the moment they arrive.
CONTENT_TIMEOUT = 30
REQUEST_TIMEOUT = 30

# Plaud's list route is picky about the page size: `page_size=5` answered 422
# on a live run (2026-08-16), while 100 (this plugin) and 20 (Cuate's desktop
# client, in daily use) both work. Since the API documents no range, requests
# are normalized into the window that is known good rather than passed through.
PAGE_SIZE = 100
MIN_PAGE_SIZE = 20

# Plaud sits behind Cloudflare, which rejects urllib's default
# "Python-urllib/3.x" outright (403 before the API is even reached — found on
# the first live run). Every request identifies itself as the plugin instead.
USER_AGENT = "Cuate-Hermes-Plaud/1.0 (+https://github.com/kidem42/Cuate)"

_LOCK = threading.Lock()


class PlaudError(RuntimeError):
    """Any failure worth telling the model about, in words it can relay."""


def reconnect_hint() -> str:
    """How THIS host got its grant decides how to renew it."""
    source = token_source()
    if source == "env":
        return "Refresh PLAUD_ACCESS_TOKEN / PLAUD_REFRESH_TOKEN in the environment."
    if source in {"file", "legacy-file"}:
        return (
            "Run `hermes plaud login` on this host (add --no-browser on a server). "
            "If the grant was granted from the Cuate app, re-grant it there instead."
        )
    return "Run `hermes plaud login` (add --no-browser on a server)."


class PlaudSessionExpired(PlaudError):
    """The grant is gone — only a fresh sign-in in Cuate fixes it. Retrying
    any Plaud call in the same turn is pointless, so this is its own type."""


def hermes_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes"))


def token_file() -> pathlib.Path:
    """Where the grant lives: the plugin's own store under HERMES_HOME, named
    the way other credential holders name theirs (google_meet keeps its own
    auth.json). Hermes' dashboard refuses to serve files with credential
    basenames — auth.json included — and that refusal is correct: a token file
    should not be readable through a files API. Clients learn only that it
    EXISTS, which is all they need."""
    return hermes_home() / "plaud" / "auth.json"


def legacy_token_file() -> pathlib.Path:
    """The flat file the first build wrote. Read for one release so an agent
    already granted access does not go dark on upgrade."""
    return hermes_home() / "plaud.json"


def token_source() -> str:
    """Where the current grant came from: shapes the wording when it expires —
    telling a CLI user to open an app they do not run is useless."""
    if token_file().exists():
        return "file"
    if legacy_token_file().exists():
        return "legacy-file"
    if os.environ.get("PLAUD_ACCESS_TOKEN"):
        return "env"
    return "none"


def _load_tokens() -> Dict[str, str]:
    for path in (token_file(), legacy_token_file()):
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text())
            if isinstance(data, dict) and data.get("access_token"):
                return data
        except (OSError, ValueError):
            pass
    access = os.environ.get("PLAUD_ACCESS_TOKEN", "")
    if access:
        return {"access_token": access, "refresh_token": os.environ.get("PLAUD_REFRESH_TOKEN", "")}
    raise PlaudError(
        "Plaud is not connected on this host. Run `hermes plaud login` "
        "(add --no-browser on a server), or set PLAUD_ACCESS_TOKEN."
    )


def save_tokens(tokens: Dict[str, str]) -> None:
    path = token_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(tokens, indent=2))
        path.chmod(0o600)  # a grant to someone's recordings, not a config knob
    except OSError:
        pass


def _refresh(tokens: Dict[str, str]) -> Dict[str, str]:
    refresh_token = tokens.get("refresh_token") or ""
    if not refresh_token:
        raise PlaudSessionExpired(
            "The Plaud access token expired and no refresh token is stored. "
            + reconnect_hint()
        )
    body = json.dumps({"refresh_token": refresh_token}).encode()
    request = urllib.request.Request(REFRESH_URL, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json")
    request.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            payload = json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        raise PlaudSessionExpired(
            "Plaud refused to renew the session (HTTP %d). " % exc.code + reconnect_hint()
        ) from exc
    except urllib.error.URLError as exc:
        raise PlaudError(f"Plaud is unreachable: {exc.reason}") from exc

    access = payload.get("access_token") or payload.get("accessToken")
    if not access:
        raise PlaudSessionExpired("Plaud returned no access token on refresh. " + reconnect_hint())
    fresh = {
        "access_token": access,
        "refresh_token": payload.get("refresh_token") or payload.get("refreshToken") or refresh_token,
        "renewed_at": int(time.time()),
    }
    save_tokens(fresh)
    return fresh


def _api(path: str) -> Any:
    """GET a developer-API path, renewing the token once on a 401."""
    with _LOCK:
        tokens = _load_tokens()

    def attempt(access_token: str) -> Any:
        request = urllib.request.Request(API_BASE + path)
        request.add_header("Authorization", f"Bearer {access_token}")
        request.add_header("Accept", "application/json")
        request.add_header("User-Agent", USER_AGENT)
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            return json.loads(response.read().decode() or "{}")

    try:
        return attempt(tokens["access_token"])
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            with _LOCK:
                tokens = _refresh(_load_tokens())
            try:
                return attempt(tokens["access_token"])
            except urllib.error.HTTPError as retry_exc:
                if retry_exc.code == 401:
                    raise PlaudSessionExpired(
                        "The Plaud grant is no longer valid (access was revoked). "
                        + reconnect_hint()
                    ) from retry_exc
                raise PlaudError(f"Plaud API error (HTTP {retry_exc.code}).") from retry_exc
        if exc.code == 404:
            raise PlaudError("Recording not found — the id may be wrong.") from exc
        if exc.code == 500:
            raise PlaudError("Plaud backend error (usually an invalid id).") from exc
        raise PlaudError(f"Plaud API error (HTTP {exc.code}).") from exc
    except urllib.error.URLError as exc:
        raise PlaudError(f"Plaud is unreachable: {exc.reason}") from exc


def list_files(page: int = 1, page_size: int = PAGE_SIZE) -> List[Dict[str, Any]]:
    """One page of the library, newest first. `page_size` is normalized into
    the range the live API is known to accept — see `PAGE_SIZE`."""
    page_size = max(MIN_PAGE_SIZE, min(int(page_size), PAGE_SIZE))
    raw = _api(f"/open/third-party/files/?page={page}&page_size={page_size}")
    if isinstance(raw, dict) and isinstance(raw.get("data"), list):
        return raw["data"]
    if isinstance(raw, list):
        return raw
    raise PlaudError("Malformed file list response.")


def get_file(file_id: str) -> Dict[str, Any]:
    safe = "".join(ch for ch in file_id if ch.isalnum() or ch in "-_")
    if not safe or safe != file_id:
        raise PlaudError("Invalid file id.")
    raw = _api(f"/open/third-party/files/{safe}")
    if not isinstance(raw, dict):
        raise PlaudError("Malformed file response.")
    return raw


def resolve_content(item: Dict[str, Any]) -> Optional[str]:
    """A note/transcript item carries its payload inline (``data_content``) or
    behind a presigned link (``data_link``) that dies in ~5 minutes — which is
    why nothing here is cached for later."""
    inline = item.get("data_content")
    if isinstance(inline, str) and inline:
        return inline
    link = item.get("data_link")
    if not isinstance(link, str) or not link:
        return None
    # The link arrives inside an API payload, and `urlopen` happily opens
    # `file://` — a malformed or hostile response would otherwise make the
    # plugin read the agent host's disk and hand it to the model. Plaud
    # presigns over HTTPS only; anything else is not a content link.
    if urllib.parse.urlparse(link).scheme != "https":
        return None
    try:
        content_request = urllib.request.Request(link)
        content_request.add_header("User-Agent", USER_AGENT)
        with urllib.request.urlopen(content_request, timeout=CONTENT_TIMEOUT) as response:
            return response.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, ValueError):
        return None


def is_unprocessed(file_obj: Dict[str, Any]) -> bool:
    """Plaud has not transcribed it yet: no notes, no source text. Processing
    cannot be started over the API — the answer must point at the app."""
    return not file_obj.get("note_list") and not file_obj.get("source_list")


def deep_link(file_id: str) -> str:
    return urllib.parse.urljoin(WEB_APP, f"file/{file_id}")

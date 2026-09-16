"""The three Plaud tools: find a recording, read its summary, read its transcript.

Everything the model gets back is text, and every recording it names carries a
``plaud://<file_id>`` marker. Clients that understand the marker (Cuate) turn it
into a card with the summary tabs, the timecoded transcript and inline audio —
resolved with the user's own grant, so no content and no expiring links travel
through the agent. Clients that do not simply see a harmless token.
"""

from __future__ import annotations

import os
import json
import functools
import datetime as dt
from typing import Any, Dict, List

from . import client, read_contract as read

# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------

PLAUD_FIND_SCHEMA = {
    "type": "function",
    "function": {
        "name": "plaud_find",
        "description": (
            "Search the user's Plaud voice-recorder library (recorded meetings, calls and memos). "
            "Returns recordings newest first with id, name, date, duration and whether Plaud has "
            "processed them yet. Use this FIRST to locate a recording, then plaud_get_note."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "timezone": {"type": "string", "description": "IANA timezone for date filters. Defaults to the agent host timezone; specify the user timezone on a remote host."},
                "query": {
                    "type": "string",
                    "description": "Case-insensitive substring of the recording name. Omit to list the newest.",
                },
                "date_from": {"type": "string", "description": "Earliest date, YYYY-MM-DD."},
                "date_to": {"type": "string", "description": "Latest date, YYYY-MM-DD."},
                "limit": {"type": "integer", "description": "Maximum recordings to return (default 10)."},
            },
        },
    },
}

PLAUD_GET_NOTE_SCHEMA = {
    "type": "function",
    "function": {
        "name": "plaud_get_note",
        "description": (
            "Read a recording's AI summary — every tab Plaud produced (Summary, Highlights, ...). "
            "Answers most questions about a meeting; reach for plaud_get_transcript only when the "
            "summary lacks the detail asked for (exact wording, who said what)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "file_id": {"type": "string", "description": "Recording id from plaud_find."},
                "tab": {"type": "string", "description": "Only this tab, by name. Omit for all of them."},
            },
            "required": ["file_id"],
        },
    },
}

PLAUD_GET_TRANSCRIPT_SCHEMA = {
    "type": "function",
    "function": {
        "name": "plaud_get_transcript",
        "description": (
            "Read the verbatim transcript of a recording, as timecoded speaker turns. "
            "Returns text and next_cursor; repeat with that cursor and unchanged selection until null. Pages may split an utterance; concatenate text in order. Prefer plaud_get_note for summaries."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "file_id": {"type": "string", "description": "Recording id from plaud_find."},
                "version": {"type": "string", "enum": ["verbatim", "clean", "outline", "marks"], "description": "Default verbatim for quotes. Clean is AI-polished speech; outline is structure; marks are device-button highlights, not speech. Read verbatim separately for quotes."},
                "cursor": {"type": "string", "description": "next_cursor from the previous page. Keep file_id, version and minute range unchanged."},
                "page_chars": {"type": "integer", "description": "Maximum text characters per page (default 12000, range 1–60000)."},
                "from_min": {"type": "number", "description": "Start of the window, in minutes."},
                "to_min": {"type": "number", "description": "End of the window, in minutes."},
            },
            "required": ["file_id"],
        },
    },
}

# --------------------------------------------------------------------------
# Formatting helpers
# --------------------------------------------------------------------------


def _duration(raw: Any) -> str:
    try:
        seconds = int(float(raw or 0) / 1000)
    except (TypeError, ValueError, OverflowError):
        return "?"
    hours, remainder = divmod(seconds, 3600)
    minutes, _ = divmod(remainder, 60)
    return f"{hours}h {minutes:02d}m" if hours else f"{minutes} min"


def _day(file_obj: Dict[str, Any]) -> str:
    return str(file_obj.get("created_at") or "")[:10]


def _reference(file_id: str) -> str:
    """How a recording is referred to in the model's answer.

    The IDENTIFIER is the contract — it is always present, so a client can act
    on it. Only its shape is configurable, because a bare token reads as noise
    on surfaces that cannot render anything from it:
      marker (default) — plaud://<id>, what card-rendering clients look for;
      link             — a deep link into Plaud's web app;
      id               — the raw id.
    """
    style = (os.environ.get("PLAUD_REFERENCE_STYLE") or "marker").strip().lower()
    if style == "link":
        return client.deep_link(file_id)
    if style == "id":
        return file_id
    return f"plaud://{file_id}"


def _headline(file_obj: Dict[str, Any]) -> str:
    """One line the model can quote as is — and the marker the client turns
    into a card."""
    name = file_obj.get("name") or "(untitled)"
    file_id = str(file_obj.get("id") or "")
    parts = [f'"{name}"', _day(file_obj), _duration(file_obj.get("duration"))]
    line = " | ".join(part for part in parts if part)
    return f"{line} | {_reference(file_id)}"


def _clock(ms: Any) -> str:
    try:
        total = int(float(ms or 0) // 1000)
    except (TypeError, ValueError, OverflowError):
        total = 0
    minutes, seconds = divmod(total, 60)
    return f"{minutes:02d}:{seconds:02d}"


# --------------------------------------------------------------------------
# Handlers
# --------------------------------------------------------------------------


def _check_plaud_available() -> bool:
    """Registered either way so the tools show up in `hermes tools`; dispatch
    is blocked until a grant exists. Returns a plain bool — the shape the
    registry expects (plugins/spotify/tools.py does the same)."""
    try:
        client._load_tokens()
        return True
    except client.PlaudSessionExpired:
        # A retired grant is still "this host has Plaud": the tools stay
        # callable and answer with the reason, so the agent asks for a new
        # sign-in instead of reporting a tool it does not have.
        return True
    except client.PlaudError:
        return False


def _recording_data(handler):
    @functools.wraps(handler)
    def wrapped(*args, **kwargs):
        return read.untrusted(handler(*args, **kwargs))
    return wrapped


@_recording_data
def _handle_plaud_find(args: Dict[str, Any] | None = None, **kwargs: Any) -> str:
    kwargs = {**(args or {}), **kwargs}
    query = str(kwargs.get("query") or "").strip().lower()
    date_from, date_to = kwargs.get("date_from"), kwargs.get("date_to")
    for value in (date_from, date_to):
        if value is not None and not read.valid_day(value):
            return "Invalid date — use a valid YYYY-MM-DD date."
    if date_from and date_to and date_from > date_to:
        return "date_from must not be after date_to."
    try:
        zone = read.timezone(kwargs.get("timezone"))
    except (ValueError, KeyError, TypeError):
        return "Invalid IANA timezone."
    try:
        limit = max(1, min(int(kwargs.get("limit") or 10), 100))
    except (TypeError, ValueError):
        limit = 10
    filtered = bool(query or date_from or date_to)
    files = []
    exhausted = False
    try:
        size = 100 if filtered else max(20, limit)
        for page_num in range(1, 6 if filtered else 2):
            batch = client.list_files(page=page_num, page_size=size)
            files.extend(batch)
            if len(batch) < size:
                exhausted = True
                break
    except client.PlaudError as exc:
        return str(exc)
    found = []
    unknown_dates = 0
    for item in files:
        if query and query not in str(item.get("name") or "").lower():
            continue
        stamp = read.timestamp(item.get("created_at"))
        if date_from or date_to:
            if stamp is None:
                unknown_dates += 1
                continue
            day = stamp.astimezone(zone).date().isoformat()
            if date_from and day < date_from or date_to and day > date_to:
                continue
        found.append(item)
    found.sort(key=lambda item: read.timestamp(item.get("created_at")) or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)
    lines = [f"{min(limit, len(found))} recording(s):" if found else "No matching recordings in the searched portion."]
    for item in found[:limit]:
        stamp = read.timestamp(item.get("created_at"))
        day = stamp.astimezone(zone).date().isoformat() if stamp else "unknown date"
        lines.append("- " + _headline(item) + f" | local date={day}")
        if "note_list" in item and "source_list" in item and client.is_unprocessed(item):
            lines.append("Not processed by Plaud yet: no notes or transcript. The user starts processing in the Plaud app.")
    lines.append(f"Searched {len(files)} recordings; dates use {zone}.")
    if not exhausted:
        lines.append("Results may be incomplete: older recordings were not searched. An empty result does not prove that no matching recording exists.")
    if unknown_dates:
        lines.append(f"{unknown_dates} recordings have unreadable dates and were excluded from the date filter.")
    if len(found) > limit:
        lines.append(f"Showing {limit} of {len(found)} matches; narrow the query or date range.")
    lines.append("Keep each recording's reference exactly as returned when mentioning it; clients use it to render recording cards.")
    return "\n".join(lines)


@_recording_data
def _handle_plaud_get_note(args: Dict[str, Any] | None = None, **kwargs: Any) -> str:
    kwargs = {**(args or {}), **kwargs}
    file_id = str(kwargs.get("file_id") or "").strip()
    wanted_tab = (kwargs.get("tab") or "").strip().lower()
    try:
        file_obj = client.get_file(file_id)
    except client.PlaudError as exc:
        return str(exc)

    if client.is_unprocessed(file_obj):
        return (
            f"{_headline(file_obj)}\nThis recording has not been processed by Plaud yet, so it has no "
            f"summary or transcript. Processing cannot be started through the API — the user starts it in "
            f"the Plaud app: {client.deep_link(file_id)}"
        )

    notes = file_obj.get("note_list") or []
    chunks: List[str] = [_headline(file_obj)]
    for item in notes:
        tab_name = str(item.get("data_tab_name") or item.get("data_type") or "Summary")
        if wanted_tab and wanted_tab not in tab_name.lower():
            continue
        content = client.resolve_content(item)
        if content is None:
            chunks.append(f"\n## {tab_name}\nContent unavailable or failed to load; try this tab again.")
            continue
        chunks.append(f"\n## {tab_name}\n{content.strip()}")

    if len(chunks) == 1:
        return chunks[0] + "\nThe recording has no readable summary tabs; try plaud_get_transcript."
    return "\n".join(chunks)


@_recording_data
def _handle_plaud_get_transcript(args: Dict[str, Any] | None = None, **kwargs: Any) -> str:
    kwargs = {**(args or {}), **kwargs}
    file_id = str(kwargs.get("file_id") or "").strip()
    versions = {"verbatim": "transaction", "clean": "transaction_polish", "outline": "outline", "marks": "mark_memo"}
    version = kwargs.get("version", "verbatim")
    if not isinstance(version, str) or version not in versions:
        return "Unknown version. Use verbatim, clean, outline or marks."
    try:
        start, end = read.minute_range(kwargs)
        if version == "marks" and (start is not None or end is not None):
            return "Minute filters apply to speech segments, not device marks. Read marks without a minute range."
        file_obj = client.get_file(file_id)
        if client.is_unprocessed(file_obj):
            return _headline(file_obj) + "\nNot processed by Plaud yet. The user starts processing in the Plaud app."
        sources = file_obj.get("source_list") or []
        selected = next((item for item in sources if item.get("data_type") == versions[version]), None)
        # Legacy responses without data_type: accept a single untyped source
        # only for verbatim, never merge arbitrary blocks into speech.
        if selected is None and version == "verbatim" and len(sources) == 1 and not sources[0].get("data_type"):
            selected = sources[0]
        if selected is None:
            available = [key for key, kind in versions.items() if any(item.get("data_type") == kind for item in sources)]
            return _headline(file_obj) + "\nRequested version unavailable. Available: " + ", ".join(available)
        raw = client.resolve_content(selected)
        if raw is None:
            return _headline(file_obj) + "\nContent could not be loaded; try again."
        text = raw
        if version != "marks":
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = None
            if isinstance(parsed, dict) and isinstance(parsed.get("data"), list):
                parsed = parsed["data"]
            if isinstance(parsed, list):
                lines = []
                for segment in parsed:
                    if not isinstance(segment, dict):
                        continue
                    stamp = segment.get("start_time", 0)
                    if not isinstance(stamp, (float, int)):
                        continue
                    if start is not None and stamp < start * 60000 or end is not None and stamp > end * 60000:
                        continue
                    content = str(segment.get("content") or segment.get("topic") or segment.get("title") or "")
                    speaker = segment.get("speaker") or segment.get("original_speaker")
                    if not content and not speaker:
                        continue
                    lines.append(f"[{_clock(stamp)}] " + (f"{speaker}: " if speaker else "") + content)
                text = "\n".join(lines)
            elif start is not None or end is not None:
                return "This block has no timestamped segments; omit the minute range."
        context = f"{file_id}|{versions[version]}|{start}|{end}"
        result = read.page(text, context, kwargs)
        return _headline(file_obj) + f"\nVersion: {version}\n" + result
    except (client.PlaudError, ValueError) as exc:
        return str(exc)

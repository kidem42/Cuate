"""The three Plaud tools: find a recording, read its summary, read its transcript.

Everything the model gets back is text, and every recording it names carries a
``plaud://<file_id>`` marker. Clients that understand the marker (Cuate) turn it
into a card with the summary tabs, the timecoded transcript and inline audio —
resolved with the user's own grant, so no content and no expiring links travel
through the agent. Clients that do not simply see a harmless token.
"""

from __future__ import annotations

from typing import Any, Dict, List

from . import client

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
            "Long — prefer plaud_get_note, and narrow with from_min/to_min when only part matters."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "file_id": {"type": "string", "description": "Recording id from plaud_find."},
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
        seconds = int(float(raw or 0))
    except (TypeError, ValueError):
        return "?"
    if seconds > 100000:  # some payloads carry milliseconds
        seconds //= 1000
    hours, remainder = divmod(seconds, 3600)
    minutes, _ = divmod(remainder, 60)
    return f"{hours}h {minutes:02d}m" if hours else f"{minutes} min"


def _day(file_obj: Dict[str, Any]) -> str:
    return str(file_obj.get("created_at") or "")[:10]


def _marker(file_id: str) -> str:
    return f"plaud://{file_id}"


def _headline(file_obj: Dict[str, Any]) -> str:
    """One line the model can quote as is — and the marker the client turns
    into a card."""
    name = file_obj.get("name") or "(untitled)"
    file_id = str(file_obj.get("id") or "")
    parts = [f'"{name}"', _day(file_obj), _duration(file_obj.get("duration"))]
    line = " | ".join(part for part in parts if part)
    return f"{line} | {_marker(file_id)}"


def _clock(ms: Any) -> str:
    try:
        total = int(float(ms or 0) // 1000)
    except (TypeError, ValueError):
        total = 0
    minutes, seconds = divmod(total, 60)
    return f"{minutes:02d}:{seconds:02d}"


# --------------------------------------------------------------------------
# Handlers
# --------------------------------------------------------------------------


def _check_plaud_available() -> tuple[bool, str]:
    """Registered either way so the tools show up in `hermes tools`; dispatch
    is blocked until the grant exists."""
    try:
        client._load_tokens()
        return True, ""
    except client.PlaudError as exc:
        return False, str(exc)


def _handle_plaud_find(**kwargs: Any) -> str:
    query = (kwargs.get("query") or "").strip().lower()
    date_from = (kwargs.get("date_from") or "").strip()
    date_to = (kwargs.get("date_to") or "").strip()
    try:
        limit = max(1, min(int(kwargs.get("limit") or 10), 50))
    except (TypeError, ValueError):
        limit = 10

    try:
        # The API filters nothing but pagination, so the narrowing happens
        # here — over at most five pages, as in the desktop client.
        found: List[Dict[str, Any]] = []
        for page in range(1, 6):
            batch = client.list_files(page=page, page_size=100)
            if not batch:
                break
            for item in batch:
                name = str(item.get("name") or "")
                day = _day(item)
                if query and query not in name.lower():
                    continue
                if date_from and day and day < date_from:
                    continue
                if date_to and day and day > date_to:
                    continue
                found.append(item)
                if len(found) >= limit:
                    break
            if len(found) >= limit or len(batch) < 100:
                break
    except client.PlaudError as exc:
        return str(exc)

    if not found:
        return "No matching recordings in Plaud."

    lines = [f"{len(found)} recording(s):"]
    unprocessed: List[str] = []
    for item in found:
        lines.append("- " + _headline(item))
        if client.is_unprocessed(item):
            unprocessed.append(str(item.get("name") or item.get("id")))
    if unprocessed:
        lines.append(
            "\nNot processed by Plaud yet (no summary or transcript exists): "
            + ", ".join(unprocessed)
            + ". Processing cannot be started through the API — mention this separately and point the user "
            "at the Plaud app."
        )
    lines.append(
        "\nWhen you mention a recording in your answer, keep its plaud://<id> marker — the app renders it "
        "as a card with the summary, transcript and audio."
    )
    return "\n".join(lines)


def _handle_plaud_get_note(**kwargs: Any) -> str:
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
        if not content:
            continue
        chunks.append(f"\n## {tab_name}\n{content.strip()}")

    if len(chunks) == 1:
        return chunks[0] + "\nThe recording has no readable summary tabs; try plaud_get_transcript."
    return "\n".join(chunks)


def _handle_plaud_get_transcript(**kwargs: Any) -> str:
    file_id = str(kwargs.get("file_id") or "").strip()
    try:
        from_min = float(kwargs["from_min"]) if kwargs.get("from_min") is not None else None
        to_min = float(kwargs["to_min"]) if kwargs.get("to_min") is not None else None
    except (TypeError, ValueError):
        from_min = to_min = None

    try:
        file_obj = client.get_file(file_id)
    except client.PlaudError as exc:
        return str(exc)

    if client.is_unprocessed(file_obj):
        return (
            f"{_headline(file_obj)}\nNot processed by Plaud yet — no transcript exists. "
            f"The user starts processing in the Plaud app: {client.deep_link(file_id)}"
        )

    segments: List[Dict[str, Any]] = []
    for item in file_obj.get("source_list") or []:
        content = client.resolve_content(item)
        if not content:
            continue
        try:
            import json as _json

            parsed = _json.loads(content)
        except ValueError:
            # Plain-text transcript: hand it over as is.
            return f"{_headline(file_obj)}\n\n{content.strip()}"
        if isinstance(parsed, list):
            segments.extend(segment for segment in parsed if isinstance(segment, dict))
        elif isinstance(parsed, dict) and isinstance(parsed.get("data"), list):
            segments.extend(segment for segment in parsed["data"] if isinstance(segment, dict))

    if not segments:
        return f"{_headline(file_obj)}\nNo transcript content is available for this recording."

    lines = [_headline(file_obj), ""]
    for segment in segments:
        start_ms = segment.get("start_time") or 0
        if from_min is not None and float(start_ms) < from_min * 60000:
            continue
        if to_min is not None and float(start_ms) > to_min * 60000:
            continue
        speaker = segment.get("speaker") or segment.get("original_speaker") or "Speaker"
        text = str(segment.get("content") or "").strip()
        if not text:
            continue
        lines.append(f"[{_clock(start_ms)}] {speaker}: {text}")

    if len(lines) == 2:
        return f"{_headline(file_obj)}\nNothing was said in the requested window."
    return "\n".join(lines)

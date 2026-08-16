"""Plaud voice-recorder library for a Hermes agent — user-installed plugin.

Gives the agent three read-only tools over the Plaud developer API: find a
recording, read its AI summary, read its transcript. With them, questions like
"what did we decide on Monday's call?" are answerable on every surface the
agent has — chat, Telegram, a cron job — instead of only inside the app that
holds the account.

**Identifiers, not content.** Every recording the tools name carries a
``plaud://<file_id>`` marker. The Cuate desktop and Android clients recognize
it and render the recording as a card — summary tabs, timecoded transcript,
inline audio — resolved with the user's own grant on the user's own device.
Nothing of the recording travels through the agent: Plaud's content links
expire in five minutes, and a pasted transcript would burn the agent's context
to draw something worse.

**The grant.** Tokens live in ``~/.hermes/plaud.json`` (chmod 600), written by
Cuate when the user grants the agent access, or in ``PLAUD_ACCESS_TOKEN`` /
``PLAUD_REFRESH_TOKEN``. The plugin refreshes the access token by itself and
writes the new pair back. Access is read-only — the API has no route that
alters a recording — and revocable at any time from the Plaud app.

Install: copy this directory to ``~/.hermes/plugins/cuate-plaud`` and enable it
(``hermes plugins enable cuate-plaud``).
"""

from __future__ import annotations

from .tools import (
    PLAUD_FIND_SCHEMA,
    PLAUD_GET_NOTE_SCHEMA,
    PLAUD_GET_TRANSCRIPT_SCHEMA,
    _check_plaud_available,
    _handle_plaud_find,
    _handle_plaud_get_note,
    _handle_plaud_get_transcript,
)

_TOOLS = (
    ("plaud_find", PLAUD_FIND_SCHEMA, _handle_plaud_find, "🔎"),
    ("plaud_get_note", PLAUD_GET_NOTE_SCHEMA, _handle_plaud_get_note, "📝"),
    ("plaud_get_transcript", PLAUD_GET_TRANSCRIPT_SCHEMA, _handle_plaud_get_transcript, "🎙️"),
)


def register(ctx) -> None:
    """Register the Plaud toolset. Called once by the plugin loader."""
    for name, schema, handler, emoji in _TOOLS:
        ctx.register_tool(
            name=name,
            toolset="plaud",
            schema=schema,
            handler=handler,
            check_fn=_check_plaud_available,
            emoji=emoji,
        )

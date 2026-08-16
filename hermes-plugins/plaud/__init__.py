"""Plaud voice-recorder library for a Hermes agent — user-installed plugin.

Three read-only tools over the Plaud developer API: find a recording, read its
AI summary, read its transcript. With them, "what did we decide on Monday's
call?" is answerable on every surface the agent has — chat, messengers, cron —
instead of only inside the app that holds the account.

**Identifiers, not content.** Every recording the tools name carries a
``plaud://<file_id>`` marker. Content links from Plaud expire in about five
minutes and a pasted transcript would burn the agent's context, so the tools
hand back an id and let the client decide what to draw: one that understands
the marker renders a card with the summary tabs, the timecoded transcript and
playable audio; anything else sees a short token. The reference style is
configurable (``marker`` / ``link`` / ``id``) for surfaces where a bare token
would read as noise.

Cuate (https://github.com/kidem42/Cuate) implements the marker end to end and
is the reference client for the format.

**Auth.** ``hermes plaud login`` (``--no-browser`` on a server), or the
``PLAUD_ACCESS_TOKEN`` / ``PLAUD_REFRESH_TOKEN`` environment variables. The
grant is stored under ``$HERMES_HOME/plaud/auth.json``, chmod 600, and the
plugin refreshes it by itself. Hermes' shared ``auth.json`` is core-only — its
writers are private and its provider list is fixed — so this follows the
convention other credential-holding plugins use.

Install: copy this directory to ``~/.hermes/plugins/plaud`` and enable it
(``hermes plugins enable plaud``).
"""

from __future__ import annotations

from . import cli as plaud_cli
from . import client
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

# What the agent needs to KNOW, as opposed to what it can call. This rides in
# EVERY session's system prompt, so it carries only what nothing else says:
# the library exists, and questions about what was SAID belong to it. The order
# of the tools is already in their descriptions, the "keep the reference" rule
# rides with each tool RESULT (where it applies), and the unprocessed-recording
# caveat comes back from the tools themselves — repeating any of that here
# would be a permanent tax on the context window for nothing.
_PROMPT_SECTION = (
    "The user has a Plaud voice recorder: meetings, calls and memos are recorded and "
    "transcribed. When an answer would come from something that was SAID — decisions, "
    "agreements, who said what, \"summarize yesterday's call\" — look there with the "
    "plaud_* tools, even when Plaud is not mentioned."
)


def _prompt_section(_session_info) -> str:
    """Nothing to say on a host with no grant: an agent that cannot reach the
    library should not carry instructions about it. Evaluated per session, so
    the guidance appears the moment `hermes plaud login` succeeds."""
    return _PROMPT_SECTION if client.token_source() != "none" else ""


def register(ctx) -> None:
    """Register the Plaud toolset, its prompt section and the CLI command."""
    for name, schema, handler, emoji in _TOOLS:
        ctx.register_tool(
            name=name,
            toolset="plaud",
            schema=schema,
            handler=handler,
            check_fn=_check_plaud_available,
            emoji=emoji,
        )

    # A skill registered BY a plugin is deliberately kept out of the system
    # prompt's skill index (plugin skills are explicit loads only), so the
    # guidance goes in as a prompt section instead — same effect, and it ships
    # with the plugin rather than as a file the user must copy separately.
    # Older Hermes has no prompt-section API; ask before calling rather than
    # swallowing every failure — a real registration error must not look like
    # an old host. Without the section the tool descriptions still stand on
    # their own, the agent just needs the topic named more explicitly.
    if hasattr(ctx, "register_system_prompt_section"):
        ctx.register_system_prompt_section("plaud", _prompt_section)

    ctx.register_cli_command(
        name="plaud",
        help="Plaud account for this agent (login, status, logout)",
        setup_fn=plaud_cli.register_cli,
        handler_fn=plaud_cli.handle,
        description=(
            "Connect the Plaud voice-recorder account this agent reads from. "
            "See: hermes plaud login --no-browser on a server."
        ),
    )

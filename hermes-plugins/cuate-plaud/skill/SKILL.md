---
name: plaud
description: Answer from the user's recorded meetings, calls and voice memos (Plaud recorder library).
version: 1.0.0
author: Cuate (github.com/kidem42/Cuate)
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Plaud, Meetings, Transcripts, Voice, Notes]
    related_skills: []
---

# Plaud recordings

The user carries a Plaud voice recorder: meetings, calls and memos are captured
and turned into AI summaries and transcripts. This skill is how you answer from
them, using the `plaud_find`, `plaud_get_note` and `plaud_get_transcript` tools.

## When to use

Reach for the recordings whenever the answer would come from something that was
**said**, not written — even when Plaud is never named:

- "what did we decide on Monday's call?", "what did I promise the client?"
- "who was against the deadline?", "what did they say about the budget?"
- "summarize yesterday's meeting", "any action items from the standup?"
- any question about an agreement, a discussion or a conversation whose record
  you do not already have in this chat.

If the user's own words are already in the conversation, answer from them. The
recordings are for what happened outside this chat.

## How to work

1. **Locate first.** `plaud_find` with a name fragment and/or a date range;
   resolve relative dates ("last week", "Monday") against today. Without a hint,
   the newest recordings come back first.
2. **Read the summary.** `plaud_get_note` answers most questions — the tabs
   Plaud produced (Summary, Highlights, …).
3. **Only then the transcript.** `plaud_get_transcript` when the summary lacks
   what was asked: exact wording, who said what, a quote. Narrow it with
   `from_min`/`to_min` — a full transcript is long.

## Reporting back

- **Keep the `plaud://<id>` marker** exactly as the tools return it. The Cuate
  app turns that marker into a card with the summary tabs, the timecoded
  transcript and playable audio; strip it and the user loses all of that.
- Name the recording, its date and duration when you cite it, so the answer
  stands on its own on surfaces that do not render cards.
- **Unprocessed recordings** have no summary or transcript yet, and processing
  cannot be started through the API. Mention them on a separate line and point
  the user at the Plaud app — never imply you read one.
- Quote sparingly. A summary of what was said beats a wall of transcript.

## When it does not work

If a tool answers that Plaud is not connected or that the session expired, say
so plainly and tell the user to reconnect in Cuate (Settings → Plaud, then
"Give the agent access"). Do not retry the other Plaud tools in the same turn —
only a fresh grant fixes it — and answer whatever else you can without them.

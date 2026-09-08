#!/bin/bash
# Contract tests for everything the app and an agent agree on in TEXT — the
# formats that break silently when one side changes alone:
#   - the attach note (attachments in agent chats), Swift + Kotlin, against
#     shared/fixtures/attach-note.json;
#   - the Plaud marker (plaud://<id>), against shared/fixtures/plaud-note.json;
#   - the mid-turn follow-up frame (steer), Swift + Kotlin, against
#     shared/fixtures/steer-frame.json;
#   - markdown lists (numbering, nesting, continuations);
#   - the conference link of a calendar event (which hosts, which field wins);
#   - the Hermes Plaud plugin, including the seam with the Hermes runtime.
# Run after touching any of those implementations or their fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Swift contract: attach note =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -o "$tmp/attach-note-test" \
    Cuate/Addons/AgentGateway/Core/AgentAttachNote.swift \
    scripts/AttachNoteContractTest.swift
"$tmp/attach-note-test" shared/fixtures/attach-note.json

echo "== Swift contract: plaud note =="
# How an agent refers to a Plaud recording (plaud://<id>) and what the bubble
# shows instead — the app resolves the id into its own card.
xcrun swiftc -o "$tmp/plaud-note-test" \
    Cuate/Addons/AgentGateway/Core/AgentPlaudNote.swift \
    scripts/PlaudNoteContractTest.swift
"$tmp/plaud-note-test" shared/fixtures/plaud-note.json

echo "== Swift contract: steer frame =="
# What a message typed mid-turn looks like on the wire (an addition to the
# task in progress) and how the words come back out of a tool row.
xcrun swiftc -o "$tmp/steer-test" \
    Cuate/Addons/HermesAddon/HermesSteer.swift \
    scripts/SteerContractTest.swift
"$tmp/steer-test" shared/fixtures/steer-frame.json

echo "== Swift contract: markdown lists =="
# Numbering, nesting and continuation lines — the shapes a sub-list used to
# break (every point rendering as "1.").
xcrun swiftc -o "$tmp/md-list-test" scripts/MarkdownListContractTest.swift
"$tmp/md-list-test"

echo "== Swift contract: documents =="
# Document attachments: the pre-flight limits and the read_document text
# queries (page markers, ranges, search, cap) — pure files, no app target.
xcrun swiftc -o "$tmp/document-test" \
    Cuate/Providers/DocumentPreflight.swift \
    Cuate/Providers/DocumentTextQuery.swift \
    scripts/DocumentContractTest.swift
"$tmp/document-test"

echo "== Swift contract: dictation shaping =="
# The dictation post-process: instruction in the system slot, bare transcript
# in the user slot, and the reply shaped before it is typed (lead-ins, labels,
# quotes, Markdown, code fences, em dashes) — pure file, no app target.
xcrun swiftc -o "$tmp/dictation-shaping-test" \
    Cuate/App/DictationTextShaping.swift \
    scripts/DictationShapingContractTest.swift
"$tmp/dictation-shaping-test"

echo "== Swift contract: conference link =="
# Which link in an event counts as the call (Zoom, Meet, Teams… by host) and
# which field wins — shared by the calendar tool and the World Time popover.
xcrun swiftc -o "$tmp/conference-link-test" \
    Cuate/Addons/CalendarAddon/ConferenceLinkDetector.swift \
    scripts/ConferenceLinkContractTest.swift
"$tmp/conference-link-test"

echo "== Python contract: Hermes Plaud plugin =="
# The seam with Hermes (how it calls a handler, what it does with check_fn)
# plus the tool behaviour. Pure stdlib: no network, no grant, no pytest.
python3 hermes-plugins/plaud/tests/test_plugin.py 2>&1 | tail -3

echo "== Kotlin contract =="
# Same JDK default as android/scripts/make-apk.sh.
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
(cd android && ./gradlew --console=plain -q :app:testDebugUnitTest \
    --tests 'com.aispotlight.android.hermes.AgentAttachNoteTest' \
    --tests 'com.aispotlight.android.hermes.HermesSteerTest')
echo "kotlin: all green"

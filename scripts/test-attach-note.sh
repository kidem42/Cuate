#!/bin/bash
# Contract tests for everything the app and an agent agree on in TEXT — the
# formats that break silently when one side changes alone:
#   - the attach note (attachments in agent chats), Swift + Kotlin, against
#     shared/fixtures/attach-note.json;
#   - the Plaud marker (plaud://<id>), against shared/fixtures/plaud-note.json;
#   - markdown lists (numbering, nesting, continuations);
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

echo "== Swift contract: markdown lists =="
# Numbering, nesting and continuation lines — the shapes a sub-list used to
# break (every point rendering as "1.").
xcrun swiftc -o "$tmp/md-list-test" scripts/MarkdownListContractTest.swift
"$tmp/md-list-test"

echo "== Python contract: Hermes Plaud plugin =="
# The seam with Hermes (how it calls a handler, what it does with check_fn)
# plus the tool behaviour. Pure stdlib: no network, no grant, no pytest.
python3 hermes-plugins/plaud/tests/test_plugin.py 2>&1 | tail -3

echo "== Kotlin contract =="
# Same JDK default as android/scripts/make-apk.sh.
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
(cd android && ./gradlew --console=plain -q :app:testDebugUnitTest \
    --tests 'com.aispotlight.android.hermes.AgentAttachNoteTest')
echo "kotlin: all green"

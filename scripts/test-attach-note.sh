#!/bin/bash
# Contract tests for the agent attach note — the cross-device carrier of
# attachments in agent chats. Runs BOTH platform implementations against
# shared/fixtures/attach-note.json:
#   - Swift:  Cuate/Addons/AgentGateway/Core/AgentAttachNote.swift
#   - Kotlin: android/.../hermes/AgentAttachNote.kt (gradle unit test)
# Run after touching either implementation or the fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Swift contract =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -o "$tmp/attach-note-test" \
    Cuate/Addons/AgentGateway/Core/AgentAttachNote.swift \
    scripts/AttachNoteContractTest.swift
"$tmp/attach-note-test" shared/fixtures/attach-note.json

echo "== Kotlin contract =="
# Same JDK default as android/scripts/make-apk.sh.
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
(cd android && ./gradlew --console=plain -q :app:testDebugUnitTest \
    --tests 'com.aispotlight.android.hermes.AgentAttachNoteTest')
echo "kotlin: all green"

#!/bin/bash
# Canonical release build for Cuate Android — the only supported way to
# produce an installable APK (mirrors the mac's scripts/make-dmg.sh role).
#
# Usage:
#   ./scripts/make-apk.sh           # rebuild with the current version
#   ./scripts/make-apk.sh 1.5.0    # bump versionName to 1.5.0, versionCode +1, then build
#
# Data inheritance contract (settings, API keys, chat history survive updates):
#   1. SAME SIGNATURE — android/release.keystore + keystore.properties must be
#      the ones used for every previous build. They are gitignored: losing them
#      means users must uninstall (and lose data) to install the next version.
#   2. GROWING versionCode — Android refuses to install an update whose
#      versionCode is not higher than the installed one. This script bumps it
#      automatically when a new version is passed.
#   3. applicationId stays com.aispotlight.android — never change it.
#   4. Room schema changes need a real Migration in Db.kt; while
#      fallbackToDestructiveMigration is in place, a schema bump wipes CHAT
#      HISTORY (keys/settings survive regardless — they live outside the DB).
set -euo pipefail

cd "$(dirname "$0")/.."

JAVA_HOME_DEFAULT="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"

GRADLE_FILE="app/build.gradle.kts"

if [[ ! -f keystore.properties || ! -f release.keystore ]]; then
    echo "ERROR: keystore.properties / release.keystore missing — the build would be unsigned" >&2
    echo "and could NOT install over the existing app. Restore them before building." >&2
    exit 1
fi

# Optional version bump: versionName := $1, versionCode += 1.
if [[ $# -ge 1 ]]; then
    NEW_VERSION="$1"
    CURRENT_CODE=$(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' "$GRADLE_FILE")
    NEW_CODE=$((CURRENT_CODE + 1))
    sed -i '' "s/versionCode = $CURRENT_CODE/versionCode = $NEW_CODE/" "$GRADLE_FILE"
    sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$NEW_VERSION\"/" "$GRADLE_FILE"
    echo "Version: $NEW_VERSION (code $NEW_CODE)"
fi

VERSION=$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$GRADLE_FILE")

./gradlew assembleRelease

mkdir -p dist
OUT="dist/Cuate-$VERSION.apk"
cp app/build/outputs/apk/release/app-release.apk "$OUT"

# Signature check — catches an accidentally unsigned/foreign-key build.
APKSIGNER=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
"$APKSIGNER" verify "$OUT"

echo "OK: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"

#!/bin/bash
#
# Builds a Release AISpotlight.app, ad-hoc signs it, and packages it into a
# pretty .dmg with a drag-to-Applications layout. No external tools required
# (uses only xcodebuild, codesign, hdiutil, sips, swift and Finder).
#
# Usage:  ./scripts/make-dmg.sh
# Output: build/AISpotlight-<version>.dmg
#
set -euo pipefail

# --- Config ---------------------------------------------------------------
APP_NAME="AISpotlight"
SCHEME="AISpotlight"
PROJECT="AISpotlight.xcodeproj"
VOL_NAME="$APP_NAME"

# Code-signing identity. A stable certificate keeps the app's TCC identity
# constant across releases, so users don't lose Microphone / Screen Recording
# / Accessibility grants on every update (ad-hoc "-" re-keys the identity to
# each binary's hash, which is why permissions used to reset).
#
# One-time setup (free, no Apple Developer account):
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "AISpotlight Signing", Identity Type: Self-Signed Root,
#   Certificate Type: Code Signing → Create.
# All future releases must be signed with this same certificate.
# Override with SIGN_ID env var; falls back to ad-hoc if the cert is absent.
SIGN_ID="${SIGN_ID:-AISpotlight Signing}"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "!! Signing identity '$SIGN_ID' not found in Keychain — falling back to ad-hoc."
    echo "   (Ad-hoc builds lose TCC permissions on every update; see comment above.)"
    SIGN_ID="-"
fi

cd "$(dirname "$0")/.."          # project root (folder with the .xcodeproj)

BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
RELEASE_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
STAGE="$BUILD_DIR/dmg-staging"

VERSION=$(grep -m1 -o 'MARKETING_VERSION = [^;]*' "$PROJECT/project.pbxproj" | head -1 | sed 's/MARKETING_VERSION = //;s/ //g')
[ -z "$VERSION" ] && VERSION="1.0"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
TMP_DMG="$BUILD_DIR/tmp.dmg"

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -d "$RELEASE_APP" ]; then
    echo "==> SKIP_BUILD=1 — reusing existing $RELEASE_APP"
else
    echo "==> Building $APP_NAME $VERSION (Release, universal arm64+x86_64)…"
    rm -rf "$DERIVED"
    # ARCHS/ONLY_ACTIVE_ARCH overrides: the project builds the active arch
    # only (fast dev cycle); the shipped app must also run on Intel Macs.
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -derivedDataPath "$DERIVED" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
        build >/dev/null
fi

[ -d "$RELEASE_APP" ] || { echo "Build failed: $RELEASE_APP not found"; exit 1; }

if [ "$SIGN_ID" = "-" ]; then
    echo "==> Ad-hoc signing (required on Apple Silicon)…"
else
    echo "==> Signing with '$SIGN_ID' (stable TCC identity across updates)…"
fi
codesign --force --deep --sign "$SIGN_ID" "$RELEASE_APP"
codesign --verify --deep --strict "$RELEASE_APP" && echo "    signature OK"

# --- Stage DMG contents ---------------------------------------------------
echo "==> Staging DMG contents…"
rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
cp -R "$RELEASE_APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "scripts/dmg-readme.txt" "$STAGE/How to open — read me.txt"

echo "==> Generating background image (1x + 2x → Retina TIFF)…"
swift - "$STAGE/.background" "$VERSION" <<'SWIFT'
import AppKit
let dir = CommandLine.arguments[1]
let version = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let W = 600.0, H = 400.0

// Renders the 600×400 pt design into a raster of the given scale.
// Note: with rep.size set to points, the bitmap context draws in POINTS.
func render(scale: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Soft vertical gradient backdrop
    NSGradient(colors: [
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.97, alpha: 1)
    ])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    let accent = NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.93, alpha: 1)
    let pc = NSMutableParagraphStyle(); pc.alignment = .center

    // Title + version
    "AISpotlight".draw(in: NSRect(x: 0, y: H - 72, width: W, height: 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
        .paragraphStyle: pc
    ])
    if !version.isEmpty {
        "Version \(version)".draw(in: NSRect(x: 0, y: H - 94, width: W, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
            .paragraphStyle: pc
        ])
    }

    // Arrow from app (left) to Applications (right)
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 245, y: 210))
    arrow.line(to: NSPoint(x: 355, y: 210))
    arrow.move(to: NSPoint(x: 340, y: 223))
    arrow.line(to: NSPoint(x: 355, y: 210))
    arrow.line(to: NSPoint(x: 340, y: 197))
    accent.setStroke()
    arrow.stroke()

    // Hint text
    "Drag AISpotlight to the Applications folder".draw(
        in: NSRect(x: 0, y: 82, width: W, height: 22), withAttributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1),
        .paragraphStyle: pc
    ])
    "Before first launch, remove quarantine in Terminal:".draw(
        in: NSRect(x: 0, y: 58, width: W, height: 16), withAttributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.52, alpha: 1),
        .paragraphStyle: pc
    ])
    "xattr -dr com.apple.quarantine /Applications/AISpotlight.app".draw(
        in: NSRect(x: 0, y: 42, width: W, height: 15), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
        .paragraphStyle: pc
    ])
    // A Finder window paints a BACKGROUND IMAGE — nothing in it can be
    // selected or copied, this line included. The one place the command can
    // actually be copied from is the text file sitting in the window, so say
    // so rather than leaving people to retype it by hand.
    "(open “How to open — read me” to copy this command)".draw(
        in: NSRect(x: 0, y: 24, width: W, height: 14), withAttributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1),
        .paragraphStyle: pc
    ])

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
render(scale: 1, to: dir + "/bg1x.png")
render(scale: 2, to: dir + "/bg2x.png")
SWIFT

# Combine 1x + 2x into a HiDPI TIFF — the only background format Finder
# reliably renders crisp on Retina displays.
tiffutil -cathidpicheck "$STAGE/.background/bg1x.png" "$STAGE/.background/bg2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm -f "$STAGE/.background/bg1x.png" "$STAGE/.background/bg2x.png"

# --- Build a writable DMG, lay it out, then compress ----------------------
echo "==> Creating disk image…"
rm -f "$TMP_DMG" "$DMG_PATH"

# Detach stale volumes from previous/aborted runs, otherwise the new image
# mounts as "$VOL_NAME 1" and the Finder AppleScript targets the wrong disk.
for v in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME "*; do
    [ -d "$v" ] && { echo "    detaching stale volume: $v"; hdiutil detach "$v" -force >/dev/null 2>&1 || true; }
done

hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
    -format UDRW -ov "$TMP_DMG" >/dev/null

ATTACH_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")
DEVICE=$(echo "$ATTACH_OUT" | egrep '^/dev/' | head -1 | awk '{print $1}')
MOUNT=$(echo "$ATTACH_OUT" | egrep -o '/Volumes/.*' | head -1)
DISK_NAME=$(basename "$MOUNT")
sleep 2

echo "==> Arranging Finder window…"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 200, 900, 600}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        set position of item "How to open — read me.txt" of container window to {520, 300}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null
sleep 1

echo "==> Compressing…"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"

echo ""
echo "✅ Done: $DMG_PATH"
echo "   Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "First launch on another Mac (unsigned build):"
echo "  xattr -dr com.apple.quarantine /Applications/AISpotlight.app"

#!/bin/bash
#
# Builds a Release Cuate.app, ad-hoc signs it, and packages it into a
# pretty .dmg with a drag-to-Applications layout. No external tools required
# (uses only xcodebuild, codesign, hdiutil, sips, swift and Finder).
#
# Usage:  ./scripts/make-dmg.sh
# Output: build/Cuate-<version>.dmg
#
set -euo pipefail

# --- Config ---------------------------------------------------------------
APP_NAME="Cuate"
SCHEME="Cuate"
PROJECT="Cuate.xcodeproj"
VOL_NAME="$APP_NAME"

# Code-signing identity. A stable certificate keeps the app's TCC identity
# constant across releases, so users don't lose Microphone / Screen Recording
# / Accessibility grants on every update (ad-hoc "-" re-keys the identity to
# each binary's hash, which is why permissions used to reset).
#
# One-time setup (free, no Apple Developer account):
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "Cuate Signing", Identity Type: Self-Signed Root,
#   Certificate Type: Code Signing → Create.
# All future releases must be signed with this same certificate.
# Override with SIGN_ID env var; falls back to ad-hoc if the cert is absent.
SIGN_ID="${SIGN_ID:-Cuate Signing}"
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

// "Eclipse" design: a near-black sky with star dust, a warm corona behind the
// app icon (Finder position {150, 190}), a dotted trail of growing dots toward
// the Applications folder ({450, 190}) and the quarantine command in a
// terminal-style chip. Colors follow the app icon and the Café theme accent.
func hex(_ h: UInt32, _ a: Double = 1) -> NSColor {
    NSColor(calibratedRed: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255,
            blue: Double(h & 0xff) / 255, alpha: a)
}
// Finder positions are measured from the top-left; AppKit draws from the bottom-left.
func fy(_ finderY: Double) -> Double { H - finderY }

func center(_ s: String, top: Double, h: Double, size: Double, weight: NSFont.Weight,
            color: NSColor, mono: Bool = false) {
    let pc = NSMutableParagraphStyle(); pc.alignment = .center
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    s.draw(in: NSRect(x: 0, y: fy(top) - h, width: W, height: h),
           withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: pc])
}
// Radial glow that fades to transparent exactly at the circle's edge. NSGradient
// ends its radial run at the bounding box corner (r·√2), so the stops are
// scaled by 1/√2 and a transparent stop is appended at 1.
func radial(cx: Double, cyF: Double, r: Double, stops: [(NSColor, CGFloat)]) {
    let cols = stops.map { $0.0 } + [stops.last!.0.withAlphaComponent(0)]
    let locs = stops.map { $0.1 * 0.7071 } + [1]
    let g = NSGradient(colors: cols, atLocations: locs, colorSpace: .genericRGB)!
    let rect = NSRect(x: cx - r, y: fy(cyF) - r, width: 2 * r, height: 2 * r)
    g.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
}

let orange = hex(0xFF7A1A), gold = hex(0xFFB347), gold2 = hex(0xFFC46B)

func draw() {
    // Night sky
    NSGradient(colors: [hex(0x121116), hex(0x1C1922)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Star dust — a fixed seed keeps the 1x and 2x renders identical.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    for _ in 0..<70 {
        let x = rnd() * W, y = rnd() * H, r = 0.5 + rnd() * 0.9
        NSColor.white.withAlphaComponent(0.06 + rnd() * 0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
    }

    // Corona behind the app icon, a fainter warm haze behind the folder
    radial(cx: 158, cyF: 198, r: 150, stops: [
        (orange.withAlphaComponent(0.55), 0), (gold.withAlphaComponent(0.22), 0.4), (gold.withAlphaComponent(0), 1)])
    radial(cx: 450, cyF: 195, r: 100, stops: [
        (gold.withAlphaComponent(0.16), 0), (gold.withAlphaComponent(0), 1)])

    // Vignette
    NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.45)],
               atLocations: [0.55, 1], colorSpace: .genericRGB)!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), relativeCenterPosition: .zero)

    // Dotted trail: dots grow and brighten from orange to gold toward the folder
    for i in 0..<6 {
        let t = Double(i) / 5, r = 2.0 + 2.2 * t, x = 240 + 100 * t
        orange.blended(withFraction: CGFloat(t), of: gold2)!.withAlphaComponent(0.45 + 0.55 * t).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: fy(210) - r, width: 2 * r, height: 2 * r)).fill()
    }
    let chevron = NSBezierPath()
    chevron.lineWidth = 3; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 351, y: fy(210) + 12))
    chevron.line(to: NSPoint(x: 364, y: fy(210)))
    chevron.line(to: NSPoint(x: 351, y: fy(210) - 12))
    gold2.setStroke(); chevron.stroke()

    // Title + version
    center("Cuate", top: 32, h: 40, size: 28, weight: .semibold, color: .white)
    if !version.isEmpty {
        center("Version \(version)", top: 76, h: 18, size: 13, weight: .regular, color: hex(0x9A96A3))
    }

    // Hint text
    center("Drag Cuate to the Applications folder", top: 296, h: 22, size: 15, weight: .medium, color: hex(0xEDE8F0))
    center("Before first launch, remove quarantine in Terminal:", top: 320, h: 16, size: 11, weight: .regular, color: hex(0x8F8A98))

    // The command in a terminal-style chip
    let cmd = "xattr -dr com.apple.quarantine /Applications/Cuate.app"
    let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    let w = (cmd as NSString).size(withAttributes: [.font: font]).width + 22, h = 21.0
    let chip = NSBezierPath(roundedRect: NSRect(x: (W - w) / 2, y: fy(337) - h, width: w, height: h), xRadius: 6, yRadius: 6)
    hex(0x26232D).setFill(); chip.fill()
    hex(0x3B3744).setStroke(); chip.lineWidth = 1; chip.stroke()
    center(cmd, top: 341, h: 15, size: 10, weight: .regular, color: gold2, mono: true)

    // A Finder window paints a BACKGROUND IMAGE — nothing in it can be
    // selected or copied, this line included. The one place the command can
    // actually be copied from is the text file sitting in the window, so say
    // so rather than leaving people to retype it by hand.
    center("(open “How to open — read me” to copy this command)", top: 366, h: 14, size: 10, weight: .regular, color: hex(0x6F6B78))
}

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
    draw()
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
        set position of item "How to open — read me.txt" of container window to {66, 300}
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
echo "  xattr -dr com.apple.quarantine /Applications/Cuate.app"

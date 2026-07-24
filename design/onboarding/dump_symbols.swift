import AppKit
import Foundation

// Настоящие SF Symbols → PNG с альфой → base64.
// В HTML используются как CSS mask, поэтому красятся currentColor,
// ровно как template-изображения в приложении.

let names = [
    "brain.head.profile", "brain", "mic.fill", "stop.fill", "paperplane.fill",
    "paperclip", "square.and.pencil", "chevron.down", "chevron.right",
    "text.viewfinder", "doc.on.doc", "doc.fill", "tablecells",
    "arrow.up.backward.and.arrow.down.forward.rectangle", "wand.and.stars",
    "scissors", "calendar", "globe", "checkmark.circle.fill", "checkmark",
    "xmark.circle.fill", "plus", "info.circle", "gearshape", "sparkles",
    "clock", "magnifyingglass", "wifi", "battery.100", "sun.max.fill",
    "cloud.sun.fill", "camera.viewfinder", "waveform", "character.cursor.ibeam",
    "keyboard", "photo", "arrow.triangle.2.circlepath", "list.bullet",
    "person.crop.square", "cpu", "location.fill", "thermometer.medium",
    "eraser", "person.and.background.dotted", "quote.opening", "bubble.left.and.bubble.right",
    "arrow.down.left.and.arrow.up.right", "wind", "drop.fill", "square.grid.2x2",
    "house.fill", "house", "trash", "chevron.left"
]

let cfg = NSImage.SymbolConfiguration(pointSize: 72, weight: .medium)
var out: [String] = []

for name in names {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(cfg) else {
        FileHandle.standardError.write("нет символа: \(name)\n".data(using: .utf8)!)
        continue
    }
    let size = img.size
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let b64 = png.base64EncodedString()
    let key = name.replacingOccurrences(of: ".", with: "-")
    out.append("  \"\(key)\": \"\(b64)\"")
    FileHandle.standardError.write("ок \(name)  \(png.count) B  \(Int(size.width))×\(Int(size.height))\n".data(using: .utf8)!)
}

print("{\n" + out.joined(separator: ",\n") + "\n}")

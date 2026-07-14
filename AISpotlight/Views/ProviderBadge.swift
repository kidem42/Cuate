import SwiftUI

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A provider's official glyph as a monochrome template vector — it tints
/// like an SF Symbol (secondary gray in views, system tint in menus).
/// Falls back to a lettered badge if the asset is missing.
/// Asset naming convention: `Provider-<name>` (e.g. `Provider-openai`).
struct ProviderGlyph: View {
    let name: String
    let fallbackLetter: String
    var size: CGFloat = 16

    var body: some View {
        if let base = NSImage(named: "Provider-\(name)") {
            // Copy so the shared named image isn't globally resized.
            let sized = base.copy() as! NSImage
            let _ = sized.size = NSSize(width: size, height: size)
            let _ = sized.isTemplate = true
            Image(nsImage: sized)
                .renderingMode(.template)
                .foregroundColor(.secondary)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Text(fallbackLetter)
                        .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                )
        }
    }
}

/// Chat-provider logo (OpenAI, Anthropic, Gemini, Mistral, DeepSeek).
struct ProviderLogo: View {
    let provider: ProviderID
    var size: CGFloat = 16

    var body: some View {
        ProviderGlyph(name: provider.rawValue, fallbackLetter: provider.badgeLetter, size: size)
    }
}

/// STT-provider logo (Mistral, OpenAI, Deepgram).
struct STTProviderLogo: View {
    let provider: STTProviderID
    var size: CGFloat = 16

    var body: some View {
        ProviderGlyph(name: provider.rawValue, fallbackLetter: String(provider.displayName.prefix(1)), size: size)
    }
}

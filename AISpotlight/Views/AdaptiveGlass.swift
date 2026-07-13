import SwiftUI

/// Liquid Glass with a graceful fallback: on macOS 26+ the real
/// `GlassEffectContainer`/`.glassEffect` is used; on older systems (the app
/// supports macOS 14+) the same surfaces render as a translucent material —
/// the standard "frosted" look panels had before Tahoe.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

extension View {
    /// Glass panel with rounded-rect shape; material fallback pre-26.
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }

    /// Glass capsule (dictation pill); material fallback pre-26.
    @ViewBuilder
    func adaptiveGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

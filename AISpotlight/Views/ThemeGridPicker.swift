import SwiftUI

/// Theme picker for Settings → Appearance → Themes: a grid of clickable
/// mini-previews (one per theme) instead of a dropdown. Each thumbnail renders
/// the theme's real palette — background, a user + assistant bubble pair and
/// the send accent — so the user can pick by look, not by name.
struct ThemeGridPicker: View {
    @Binding var selection: AppTheme
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    selection = theme
                } label: {
                    VStack(spacing: 5) {
                        ThemeThumbnail(theme: theme)
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selection == theme ? Color.accentColor : Color.secondary.opacity(0.25),
                                                  lineWidth: selection == theme ? 2 : 1)
                            )
                        Text(theme.displayName)
                            .font(.caption)
                            .foregroundColor(selection == theme ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.displayName)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

/// One theme's miniature: its panel background with a pair of bubble pills and
/// the send accent dot. Uses the live `ThemePalette`, so thumbnails follow
/// light/dark automatically and never drift from the real look.
private struct ThemeThumbnail: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ThemePalette.palette(for: theme, scheme: scheme)
        ZStack {
            // Background — mirrors themedPanelSurface's stacking.
            if palette.isGlass {
                Rectangle().fill(.ultraThinMaterial)
            } else if palette.glassSurface {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(palette.backgroundStyle).opacity(0.85)
                Rectangle().fill(palette.panelTint)
            } else {
                Rectangle().fill(palette.backgroundStyle)
            }

            // Bubble pair
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(palette.isGlass ? AnyShapeStyle(Color.accentColor.opacity(0.5)) : palette.userFill)
                        .frame(width: 40, height: 11)
                }
                Capsule()
                    .fill(palette.isGlass ? AnyShapeStyle(Color.secondary.opacity(0.25)) : palette.assistantFill)
                    .frame(width: 50, height: 11)
                Spacer()
            }
            .padding(8)

            // Send accent
            Circle()
                .fill(palette.isGlass ? AnyShapeStyle(Color.accentColor) : palette.sendFill)
                .frame(width: 9, height: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(6)
        }
    }
}

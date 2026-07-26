import SwiftUI

extension Notification.Name {
    /// The agent sidebar appeared/disappeared (userInfo["visible"]: Bool).
    /// The AppDelegate grows the window LEFT by `AgentSidebarLayout.width`
    /// (right edge fixed) or shrinks it back — the CHAT column's size is
    /// invariant across role switches, only the window makes room.
    static let agentSidebarVisibilityChanged = Notification.Name("agentSidebarVisibilityChanged")
}

/// Layout constants for the agent management sidebar (left column, notes
/// §"Боковая панель").
enum AgentSidebarLayout {
    static let width: CGFloat = 280
}

/// Section scaffold for the sidebar: collapsible header (chevron + count),
/// lazy body, skeleton while the first load is in flight. A gateway serves
/// dozens of skills — expanded-by-default everywhere read as one long mash
/// (e2e feedback 2026-07-25), so each section folds and remembers its state.
struct AgentSidebarSection<Content: View>: View {
    @Environment(\.themePalette) private var palette

    let title: String
    /// Persistence key for the expanded state ("sessions", "skills", …).
    let stateKey: String
    let isLoading: Bool
    /// Row count shown next to the title (nil → no badge).
    var count: Int?
    var defaultExpanded = false
    /// Hover tooltip explaining WHAT the section is for (the categories are
    /// foreign vocabulary — a header without an explanation reads as noise;
    /// e2e feedback 2026-07-25).
    var helpText: String?
    @ViewBuilder let content: () -> Content

    @State private var expanded: Bool?

    private var defaultsKey: String { "agentSidebar.expanded.\(stateKey)" }

    private var isExpanded: Bool {
        expanded ?? (UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let next = !isExpanded
                withAnimation(.easeInOut(duration: 0.15)) { expanded = next }
                UserDefaults.standard.set(next, forKey: defaultsKey)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .foregroundColor(palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(helpText ?? title)

            if isExpanded {
                if isLoading {
                    // Skeleton rows, not a spinner: the column keeps its shape.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(height: 14)
                        }
                    }
                } else {
                    content()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row inside a sidebar section: title + optional caption + optional
/// trailing action, in the theme's secondary typography.
struct AgentSidebarRow: View {
    @Environment(\.themePalette) private var palette

    let title: String
    var caption: String?
    var systemImage: String?
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundColor(palette.ink)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: emphasized ? .medium : .regular))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundColor(palette.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

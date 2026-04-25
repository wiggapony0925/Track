// FloatingTabBar
//
// YouTube / iMessage–inspired floating pill tab bar used by
// `MainTabView`.  Owns no navigation state of its own — it simply
// drives the `AppTab` selection binding it is given, and the
// parent `TabView` handles the actual screen swap (e.g. tapping
// the Chat pill switches `MainTabView`'s `TabView` to `ChatView`).
//
// Visual rules:
// • Inactive items are icon-only with a muted tint.
// • The active item expands into a purple gradient pill that
//   carries both the icon and its label.
// • Lives in a glassy capsule that floats above the safe area
//   so it never collides with the Chat input bar above it.

import SwiftUI

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pillNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(AppTheme.Colors.glassHighlight, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12),
                radius: 16, x: 0, y: 6)
        .shadow(color: AppTheme.Colors.accentGlow.opacity(0.18),
                radius: 22, x: 0, y: 10)
        .padding(.horizontal, 18)
        .padding(.bottom, -8)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selection)
    }

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        let isSelected = selection == tab
        Button {
            guard selection != tab else { return }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
            selection = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                if isSelected {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .leading)),
                            removal: .opacity
                        ))
                }
            }
            .foregroundStyle(isSelected ? Color.white : AppTheme.Colors.textSecondary)
            .padding(.horizontal, isSelected ? 14 : 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.Gradients.accentVibrant)
                        .shadow(color: AppTheme.Colors.accentGlow.opacity(0.55),
                                radius: 10, x: 0, y: 4)
                        .matchedGeometryEffect(id: "activePill", in: pillNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.rawValue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    struct PreviewHost: View {
        @State var tab: AppTab = .chat
        var body: some View {
            ZStack(alignment: .bottom) {
                AppTheme.Gradients.screen.ignoresSafeArea()
                FloatingTabBar(selection: $tab)
            }
        }
    }
    return PreviewHost().preferredColorScheme(.dark)
}

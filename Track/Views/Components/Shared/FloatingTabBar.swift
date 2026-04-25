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

    /// Tracks whether a horizontal drag is currently in progress so we
    /// can briefly swap the spring response for a snappier follow-the-
    /// finger feel without clobbering the regular tap animation.
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
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
            .contentShape(Capsule())
            // Press-and-drag across the bar to live-scrub between tabs,
            // iMessage-style. The pill follows the finger because each
            // crossing into a new item flips `selection`, and the
            // matched-geometry pill animates to the new slot.
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        updateSelection(forDragX: value.location.x, totalWidth: geo.size.width)
                    }
                    .onEnded { value in
                        updateSelection(forDragX: value.predictedEndLocation.x,
                                        totalWidth: geo.size.width)
                        isDragging = false
                    }
            )
            .animation(
                isDragging
                    ? .interactiveSpring(response: 0.28, dampingFraction: 0.78)
                    : .spring(response: 0.42, dampingFraction: 0.78),
                value: selection
            )
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
        .padding(.bottom, -22)
    }

    /// Translate a finger x-position (in the GeometryReader's local
    /// space) into the corresponding `AppTab` and update `selection`
    /// when it changes.  Each item gets an equal slice of the bar.
    private func updateSelection(forDragX x: CGFloat, totalWidth: CGFloat) {
        let count = AppTab.allCases.count
        guard count > 0, totalWidth > 0 else { return }
        // The bar has 6pt horizontal padding inside the glass capsule
        // (matches `.padding(.horizontal, 6)` above) — account for it
        // so the leftmost / rightmost items are easy to reach.
        let inset: CGFloat = 6
        let usable = max(1, totalWidth - inset * 2)
        let slice = usable / CGFloat(count)
        let raw = Int(((x - inset) / slice).rounded(.down))
        let clamped = min(max(raw, 0), count - 1)
        let target = AppTab.allCases[clamped]
        if target != selection {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
            #endif
            selection = target
        }
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
                        .fill(AppTheme.Colors.accent)
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

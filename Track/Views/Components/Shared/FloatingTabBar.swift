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
// • When `HomeView` reports its sheet has collapsed (via
//   `.homeSheetCollapsedChanged`), the bar morphs:
//   adds a top "grabber" handle + chevron, glows accent purple,
//   and accepts an upward drag/tap to post `.requestRestoreHomeSheet`,
//   which restores the dashboard sheet.

import SwiftUI

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pillNamespace
    @Environment(\.colorScheme) private var colorScheme

    /// Tracks whether a horizontal drag is currently in progress so we
    /// can briefly swap the spring response for a snappier follow-the-
    /// finger feel without clobbering the regular tap animation.
    @State private var isDragging: Bool = false

    /// Mirrors `HomeView.isSheetCollapsed`. Updated via NotificationCenter
    /// so this component stays decoupled from the home screen.
    @State private var sheetCollapsed: Bool = false
    /// Live upward-drag distance while the user is pulling the bar to
    /// restore the sheet.  Drives the elastic stretch / chevron lift.
    @State private var pullProgress: CGFloat = 0
    /// Soft pulse driven by `sheetCollapsed` to telegraph that the bar
    /// is now also a grabber.
    @State private var grabberPulse: Bool = false
    /// One-shot burst applied to the train when the sheet is
    /// restored — the train visually "spits" the sheet back out.
    @State private var burpBurst: Bool = false
    /// Drives the train's continuous gentle horizontal bob so it feels
    /// like it's idling on the platform.
    @State private var trainBob: Bool = false
    /// Mirrors `HomeViewModel.selectedMode` so the grabber renders the
    /// vehicle that matches whatever transit mode the user is browsing
    /// (subway / bus / LIRR / Metro-North).
    @State private var transportMode: TransportMode = .subway

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Train sits as a SIBLING of the bar inside the
                // GeometryReader so its hit region is part of this
                // view's bounds.  Overlays drawn outside their
                // parent's frame don't always receive touches under
                // the sheet overlay above; keeping the train inside
                // the layout frame fixes tap-through.
                // IMPORTANT: do NOT apply `.contentShape(Rectangle())`
                // after the `.frame(maxHeight: .infinity)` below — that
                // would make the entire ZStack (including the area over
                // the tab pills) tappable, swallowing the first tap on
                // a different tab while collapsed and forcing the user
                // to tap twice.  The inner `trainGrabber` view already
                // owns its own tight tap target on the sprite itself.
                trainGrabber
                    .opacity(sheetCollapsed ? 1 : 0)
                    .scaleEffect(sheetCollapsed ? 1 : 0.6, anchor: .bottom)
                    .offset(y: -56)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(sheetCollapsed)
                    .zIndex(2)

                tabRow
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                sheetCollapsed
                                    ? AppTheme.Colors.accent.opacity(0.55)
                                    : AppTheme.Colors.glassHighlight,
                                lineWidth: sheetCollapsed ? 1 : 0.5
                            )
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12),
                            radius: 16, x: 0, y: 6)
                    .shadow(
                        color: AppTheme.Colors.accentGlow
                            .opacity(sheetCollapsed ? (grabberPulse ? 0.55 : 0.32) : 0.18),
                        radius: sheetCollapsed ? 26 : 22, x: 0, y: 10
                    )
                    .frame(height: 56)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(combinedGesture(in: geo))
                    .animation(
                        isDragging
                            ? .interactiveSpring(response: 0.28, dampingFraction: 0.78)
                            : .spring(response: 0.42, dampingFraction: 0.78),
                        value: selection
                    )
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: sheetCollapsed)
                    .zIndex(1)
                    // No animation on `pullProgress` — follows the finger
                    // 1:1 so the grabber's elastic stretch never feels
                    // rubbery or laggy.
            }
        }
        // Outer frame is taller while collapsed so the train (which
        // sits ~50pt above the bar) is INSIDE this view's bounds and
        // therefore inside its hit-test region.  When expanded, the
        // frame collapses back to 56 so each tab's safe-area inset
        // doesn't reserve space we don't need.
        .frame(height: sheetCollapsed ? 56 + 56 : 56, alignment: .bottom)
        .padding(.horizontal, 18)
        .padding(.bottom, -22)
        // Wire to HomeView via NotificationCenter so the bar stays
        // decoupled — no shared state object required.
        .onReceive(NotificationCenter.default.publisher(for: .homeSheetCollapsedChanged)) { note in
            let collapsed = (note.object as? Bool) ?? false
            sheetCollapsed = collapsed
            grabberPulse = collapsed
            if !collapsed { pullProgress = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeTransportModeChanged)) { note in
            if let mode = note.object as? TransportMode {
                transportMode = mode
            }
        }
    }

    // MARK: - Subviews

    /// A purple vehicle (subway / bus / LIRR / Metro-North) that rests
    /// ON TOP of the floating tab bar while the dashboard sheet is
    /// collapsed.  The specific vehicle reflects the user's current
    /// `TransportMode`, so swiping down from the Bus tab shows a bus,
    /// from the LIRR tab shows a commuter train, etc.
    private var trainGrabber: some View {
        let kind = VehicleDisplayKind(mode: transportMode)
        let size = kind.aspectSize
        return VehicleDisplayModel(kind: kind, pulse: grabberPulse)
            .frame(width: size.width, height: size.height)
            .id(kind)        // force a smooth crossfade when the mode flips
            .transition(.scale.combined(with: .opacity))
            .offset(x: trainBob ? 2 : -2)
            .scaleEffect(burpBurst ? 1.18 : (grabberPulse ? 1.03 : 1.0),
                         anchor: .bottom)
            .rotationEffect(.degrees(burpBurst ? -3 : 0), anchor: .bottom)
            .shadow(color: AppTheme.Colors.accentGlow.opacity(grabberPulse ? 0.65 : 0.4),
                    radius: grabberPulse ? 14 : 10, x: 0, y: 5)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: trainBob
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: burpBurst)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: kind)
            .accessibilityElement()
            .accessibilityLabel("Show dashboard")
            .accessibilityHint("Drag up or tap to restore the dashboard sheet")
            .onTapGesture { requestRestore() }
            .onAppear { trainBob = true }
    }

    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Gesture

    /// Drag gesture for horizontal tab scrubbing.  Vertical pull-up
    /// to restore the sheet was removed — tap the train instead.
    private func combinedGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !isDragging { isDragging = true }
                updateSelection(forDragX: value.location.x, totalWidth: geo.size.width)
            }
            .onEnded { value in
                if isDragging {
                    updateSelection(forDragX: value.predictedEndLocation.x,
                                    totalWidth: geo.size.width)
                }
                isDragging = false
            }
    }

    private func requestRestore() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        // Trigger the "spit" burst, then settle back.
        burpBurst = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            burpBurst = false
        }
        NotificationCenter.default.post(name: .requestRestoreHomeSheet, object: nil)
    }

    // MARK: - Helpers

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


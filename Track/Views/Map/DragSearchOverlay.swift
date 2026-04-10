// Live drag-to-search overlay. When the user pans the map away from
// their real location, a subtle dim covers the map, a blue dot appears
// at the screen center, and the bottom sheet shows a loading state.
// The API fires automatically after panning stops.
//
// v2: Polished with multi-ring ripple, smooth scrim transitions,
//     staggered status pill entrance, and breathing dot while idle.

import SwiftUI

/// A fixed-position blue dot at screen center + a status pill at the top,
/// with a subtle map dim while the user is actively panning.
/// The dot "emerges" from the user's GPS circle with a grow animation.
struct DragSearchOverlay: View {
    
    let isActive: Bool
    let isSearching: Bool
    let isPanning: Bool
    let onDismiss: () -> Void
    
    /// The bottom safe-area padding applied to the map (e.g. 350pt for the bottom sheet).
    /// The map camera center is shifted up by half this value, so we offset the dot to match.
    var mapBottomPadding: CGFloat = 350
    
    /// Tracks whether the dot has fully appeared (drives the grow-from-center animation).
    @State private var hasAppeared = false
    
    /// Drives the repeating ripple animation when searching.
    @State private var rippleActive = false

    /// Second ripple ring with staggered timing for depth.
    @State private var ripple2Active = false

    /// Gentle breathing scale when idle (settled, not searching).
    @State private var breathe = false

    /// Pill entrance stagger — slides in from top after dot appears.
    @State private var pillVisible = false
    
    var body: some View {
        if isActive {
            ZStack {
                // ── Map scrim ──
                // Soft dim while panning, fades lighter once settled.
                // Uses interpolatingSpring for organic feel.
                AppTheme.Colors.mapScrim
                    .opacity(isPanning ? 1.0 : 0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(
                        .interpolatingSpring(stiffness: 120, damping: 18),
                        value: isPanning
                    )
                
                // ── Blue dot pinned to map's effective center ──
                appleLocationDot
                    .scaleEffect(hasAppeared ? 1.0 : 0.01)
                    .opacity(hasAppeared ? 1.0 : 0.0)
                    .offset(y: -(mapBottomPadding / 2))
                    .allowsHitTesting(false)
                
                // ── Status pill at top ──
                VStack {
                    statusPill
                        .padding(.top, 14)
                        .offset(y: pillVisible ? 0 : -30)
                        .opacity(pillVisible ? 1 : 0)
                    Spacer()
                }
            }
            .transition(
                .asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.25)),
                    removal: .opacity.combined(with: .scale(scale: 0.97))
                        .animation(.easeIn(duration: 0.2))
                )
            )
            .onAppear {
                // Dot grows from center — feels like it emerged from GPS circle
                withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                    hasAppeared = true
                }
                // Pill slides in with slight stagger
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78).delay(0.12)) {
                    pillVisible = true
                }
            }
            .onDisappear {
                hasAppeared = false
                pillVisible = false
                breathe = false
            }
        }
    }
    
    // MARK: - Apple-style Location Dot
    
    private var appleLocationDot: some View {
        ZStack {
            // ── Outer ripple ring — pulses outward while searching ──
            if isSearching {
                // Primary ripple
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                    .scaleEffect(rippleActive ? 2.0 : 1.0)
                    .opacity(rippleActive ? 0.0 : 0.6)
                    .onAppear {
                        withAnimation(
                            .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                        ) {
                            rippleActive = true
                        }
                    }
                    .onDisappear { rippleActive = false }

                // Secondary ripple (staggered for depth)
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue.opacity(0.2), lineWidth: 1)
                    .frame(width: 44, height: 44)
                    .scaleEffect(ripple2Active ? 2.4 : 0.8)
                    .opacity(ripple2Active ? 0.0 : 0.4)
                    .onAppear {
                        // Delay the second ring so they alternate
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            withAnimation(
                                .easeOut(duration: 1.4)
                                .repeatForever(autoreverses: false)
                            ) {
                                ripple2Active = true
                            }
                        }
                    }
                    .onDisappear { ripple2Active = false }
            }

            // ── Soft accuracy halo ──
            // Slightly larger and more visible while panning;
            // gentle breathing when settled idle.
            Circle()
                .fill(AppTheme.Colors.mtaBlue.opacity(isPanning ? 0.20 : 0.10))
                .frame(width: 48, height: 48)
                .scaleEffect(breatheScale)
                .animation(
                    .interpolatingSpring(stiffness: 100, damping: 16),
                    value: isPanning
                )
            
            // ── White border ring ──
            Circle()
                .fill(AppTheme.Colors.cardBackground)
                .frame(width: 22, height: 22)
                .shadow(color: AppTheme.Colors.shadow.opacity(0.22), radius: 4, y: 1.5)
            
            // ── Blue fill ──
            // Pulses while searching; breathes gently when idle-settled.
            Circle()
                .fill(AppTheme.Colors.mtaBlue)
                .frame(width: 16, height: 16)
                .scaleEffect(dotScale)
                .animation(
                    isSearching
                        ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                    value: isSearching ? isSearching : breathe
                )
                .onAppear {
                    // Start subtle breathing after a beat
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        breathe = true
                    }
                }
        }
    }

    private var dotScale: CGFloat {
        if isSearching { return 1.15 }
        if breathe && !isPanning { return 1.06 }
        return 1.0
    }

    private var breatheScale: CGFloat {
        if isPanning { return 1.0 }
        if breathe { return 1.08 }
        return 1.0
    }
    
    // MARK: - Status Pill
    
    private var statusPill: some View {
        HStack(spacing: 8) {
            // ── Leading indicator ──
            Group {
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(AppTheme.Colors.mtaBlue)
                } else if isPanning {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.mtaBlue)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.mtaBlue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: statusPhase)
            
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: statusText)
            
            // ── Dismiss X ──
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .trackFloatingChrome(cornerRadius: 999)
    }

    /// Discrete phase for animating indicator transitions.
    private var statusPhase: Int {
        if isSearching { return 2 }
        if isPanning { return 1 }
        return 0
    }
    
    private var statusText: String {
        if isSearching { return "Searching here…" }
        if isPanning { return "Release to search" }
        return "Exploring area"
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.15).ignoresSafeArea()
        DragSearchOverlay(isActive: true, isSearching: false, isPanning: true, onDismiss: {})
    }
}

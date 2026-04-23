// SheetPeekButton — shown when the user drags the dashboard sheet
// fully down past the minimum height, collapsing it out of view.
//
// Design:
//   • Floating capsule with the app accent colour
//   • Upward chevron + "Track" wordmark
//   • Continuous pulse/glow animation to signal interactivity
//   • Swipe-up gesture also triggers restore (in addition to tap)
//
// The owning view (HomeView) handles the actual detent restoration
// via the `onRestore` callback.

import SwiftUI

struct SheetPeekButton: View {
    let onRestore: () -> Void

    @State private var isPulsing = false
    @State private var isDragging = false
    @State private var dragProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            // ── Upward arrow hint ──
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.Colors.accent.opacity(0.5))
                .offset(y: isPulsing ? -3 : 0)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: isPulsing
                )

            // ── Main pill ──
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(isDragging ? -20 : 0))

                Text("Show dashboard")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Capsule()
                    .fill(AppTheme.Colors.accent)
                    // Pulsing glow ring
                    .shadow(
                        color: AppTheme.Colors.accent.opacity(isPulsing ? 0.7 : 0.3),
                        radius: isPulsing ? 18 : 8,
                        y: 2
                    )
            }
            .scaleEffect(isDragging ? 1.06 : 1.0)
            .offset(y: -dragProgress * 20)
        }
        .onAppear { isPulsing = true }
        // ── Tap ──
        .onTapGesture { onRestore() }
        // ── Swipe up ──
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if value.translation.height < 0 {
                        isDragging = true
                        dragProgress = min(1, -value.translation.height / 60)
                    }
                }
                .onEnded { value in
                    isDragging = false
                    dragProgress = 0
                    if value.translation.height < -30 {
                        onRestore()
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SheetPeekButton { }
    }
}

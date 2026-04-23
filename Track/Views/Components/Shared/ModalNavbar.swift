// Modal navbar component displayed at the top of the dashboard sheet.
// Only contains the transport mode filter strip.
// The floating search bar is rendered separately in HomeView as a
// ZStack overlay that sits above the sheet top edge.

import SwiftUI
import CoreLocation

struct ModalNavbar: View {
    @Binding var selectedMode: TransportMode
    var lastUpdated: Date?
    var isRefreshing: Bool = false
    var weatherSnapshot: WeatherSnapshot? = nil
    var locationName: String? = nil
    var isDragSearchActive: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top clearance: the floating pill straddles the sheet top edge
            // (50% in map, 50% in sheet) so we need spacing before the chips.
            // No drag handle — the pill itself is the visual anchor.
            Color.clear
                .frame(height: 54)  // clears the pill's bottom half + breathing room

            // ── Mode chips ──
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.bottom, 14)
        }
        .clipped()
    }
}

// MARK: - Mode Filter Strip

struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    @Namespace private var modeNamespace
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TransportMode.allCases, id: \.self) { mode in
                    modeChip(for: mode)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            // Extra trailing padding so the last chip doesn't clip under
            // the sheet's right edge on smaller screens.
            .padding(.trailing, 8)
        }
        .clipped()
    }

    private func modeChip(for mode: TransportMode) -> some View {
        let isActive = selectedMode == mode
        return Button {
            // Animate only the pill highlight — NOT the model mutation.
            // Wrapping selectedMode = mode in withAnimation propagates
            // the animation to every @Observable property change triggered
            // downstream (clearRoute, refresh, etc.), causing lag.
            selectedMode = mode
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(AppTheme.Colors.accent)
                            .matchedGeometryEffect(id: "modeHighlight", in: modeNamespace)
                    } else {
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 1)
                            .background(Capsule().fill(AppTheme.Colors.cardInset.opacity(0.3)))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // Animate only the pill highlight slide — scoped so it doesn't
        // propagate to downstream model mutations.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedMode)
    }
}

#Preview {
    ModalNavbar(selectedMode: .constant(.nearby))
        .background(Color(.systemBackground))
        .padding(.top, 20)
}

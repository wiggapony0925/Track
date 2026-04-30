// Shared annotation content view for all live vehicle markers
// (bus, subway, LIRR, MNR). Eliminates duplicate rendering code
// across BusVehicleMarker, SubwayTrainMarker, LIRRMarker, MNRMarker.

import SwiftUI

/// Reusable vehicle marker icon rendered inside a MapLibre overlay.
/// All four vehicle types share the same circle-icon layout and
/// highlight/tap behavior — only the icon and color differ.
struct VehicleMarkerContent: View {
    let icon: String
    let color: Color
    let isHighlighted: Bool
    /// When true, the marker uses a diamond shape instead of circle (express subway).
    var isExpress: Bool = false
    /// GTFS-RT VehiclePosition.OccupancyStatus enum (0=empty \u2026 6=not_accepting).
    /// When present, a small colored dot appears at the marker's top-right
    /// to telegraph crowding without cluttering the icon.
    var occupancy: Int? = nil
    /// Seconds since the upstream vehicle position was recorded. Rendered
    /// as a tiny freshness badge so riders can see whether the marker is live.
    var updateAgeSeconds: TimeInterval? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(AnyShape(isExpress ? AnyShape(RotatedDiamondShape()) : AnyShape(Circle())))
                .overlay(
                    AnyShape(isExpress ? AnyShape(RotatedDiamondShape()) : AnyShape(Circle()))
                        .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
                )
                .overlay(alignment: .topTrailing) {
                    if let dotColor = occupancyDotColor {
                        Circle()
                            .fill(dotColor)
                            .overlay(Circle().stroke(.white, lineWidth: 1.2))
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .shadow(
                    color: isHighlighted ? color.opacity(0.6) : AppTheme.Colors.shadow.opacity(0.22),
                    radius: isHighlighted ? 6 : 2,
                    y: isHighlighted ? 0 : 1
                )

            if let freshnessLabel {
                Text(freshnessLabel)
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(freshnessColor.opacity(0.95)))
                    .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 0.6))
                    .offset(y: 25)
                    .accessibilityLabel("Updated \(freshnessLabel) ago")
            }
        }
            .frame(width: 48, height: 68)
            .contentShape(Rectangle())
            .scaleEffect(isHighlighted ? 1.3 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
            .onTapGesture { onTap?() }
    }

    /// Maps GTFS-RT OccupancyStatus to a traffic-light color.
    /// Returns nil for unknown / "many seats available" so the dot
    /// only appears when there's actionable signal for the rider.
    private var occupancyDotColor: Color? {
        switch occupancy {
        case 2: return .yellow         // few seats available
        case 3: return .orange         // standing room only
        case 4, 5, 6: return .red      // crushed / full / not accepting
        default: return nil            // 0/1/nil \u2192 plenty of room or unknown
        }
    }

    private var freshnessLabel: String? {
        guard let updateAgeSeconds, updateAgeSeconds >= 0 else { return nil }
        if updateAgeSeconds < 60 { return "\(Int(updateAgeSeconds))s" }
        return "\(Int(updateAgeSeconds / 60))m"
    }

    private var freshnessColor: Color {
        guard let updateAgeSeconds else { return color }
        if updateAgeSeconds > 180 { return AppTheme.Colors.alertRed }
        if updateAgeSeconds > 90 { return Color.orange }
        return color
    }
}

/// A diamond shape (rotated rounded rectangle) for express subway markers.
struct RotatedDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.08
        let r = rect.insetBy(dx: inset, dy: inset)
        let cx = r.midX
        let cy = r.midY
        let hw = r.width / 2
        let hh = r.height / 2
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - hh))
        path.addLine(to: CGPoint(x: cx + hw, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy + hh))
        path.addLine(to: CGPoint(x: cx - hw, y: cy))
        path.closeSubpath()
        return path
    }

}

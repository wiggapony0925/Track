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
    var onTap: (() -> Void)? = nil

    var body: some View {
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
            .shadow(
                color: isHighlighted ? color.opacity(0.6) : AppTheme.Colors.shadow.opacity(0.22),
                radius: isHighlighted ? 6 : 2,
                y: isHighlighted ? 0 : 1
            )
            .scaleEffect(isHighlighted ? 1.3 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
            .drawingGroup()
            .onTapGesture { onTap?() }
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

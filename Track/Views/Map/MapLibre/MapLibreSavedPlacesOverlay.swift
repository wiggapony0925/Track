import MapLibre
import SwiftUI

struct MapLibreSavedPlacesOverlay: View {
    private static let pinWidth: CGFloat = 28
    private static let pinHeight: CGFloat = 34

    let mapView: MLNMapView?
    let places: [SavedLocation]
    let cameraChangeToken: UInt64
    let onTap: (SavedLocation) -> Void

    var body: some View {
        GeometryReader { _ in
            ForEach(places) { place in
                if let point = projectToScreen(place.coordinate, mapView: mapView, margin: 48) {
                    Button {
                        onTap(place)
                    } label: {
                        SavedPlaceMapPin(iconName: place.iconName)
                            .frame(width: Self.pinWidth, height: Self.pinHeight)
                    }
                    .buttonStyle(.plain)
                    .position(x: point.x, y: point.y - Self.pinHeight / 2)
                    .accessibilityLabel("Plan trip to \(place.name)")
                }
            }
        }
    }
}

#Preview {
    MapLibreSavedPlacesOverlay(
        mapView: nil,
        places: [],
        cameraChangeToken: 0,
        onTap: { _ in }
    )
}

private struct SavedPlaceMapPin: View {
    let iconName: String

    var body: some View {
        ZStack(alignment: .top) {
            SavedPlacePinShape()
                .fill(AppTheme.Colors.accent)
                .shadow(color: AppTheme.Colors.accent.opacity(0.26), radius: 6, x: 0, y: 3)
                .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)

            SavedPlacePinShape()
                .strokeBorder(.white.opacity(0.86), lineWidth: 1.1)

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: iconName)
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                )
                .padding(.top, 5)

            Circle()
                .fill(.white)
                .frame(width: 3, height: 3)
                .position(x: 14, y: 32.6)
        }
        .contentShape(SavedPlacePinShape())
    }
}

private struct SavedPlacePinShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let midX = rect.midX
        let top = rect.minY
        let bodyBottom = rect.minY + rect.height * 0.72
        let tip = CGPoint(x: midX, y: rect.maxY)

        var path = Path()
        path.move(to: tip)
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.12, y: bodyBottom),
            control1: CGPoint(x: midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.12),
            control2: CGPoint(x: rect.minX + rect.width * 0.12, y: bodyBottom + rect.height * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: midX, y: top),
            control1: CGPoint(x: rect.minX - rect.width * 0.06, y: rect.height * 0.32),
            control2: CGPoint(x: rect.minX + rect.width * 0.25, y: top)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.12, y: bodyBottom),
            control1: CGPoint(x: rect.maxX - rect.width * 0.25, y: top),
            control2: CGPoint(x: rect.maxX + rect.width * 0.06, y: rect.height * 0.32)
        )
        path.addCurve(
            to: tip,
            control1: CGPoint(x: rect.maxX - rect.width * 0.12, y: bodyBottom + rect.height * 0.10),
            control2: CGPoint(x: midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.12)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
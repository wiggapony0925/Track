import MapLibre
import SwiftUI

struct MapLibreSavedPlacesOverlay: View {
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
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.cardBackground.opacity(0.94))
                                .frame(width: 36, height: 36)
                                .shadow(color: .black.opacity(0.26), radius: 7, y: 3)
                            Circle()
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.55), lineWidth: 1.4)
                                .frame(width: 36, height: 36)
                            Image(systemName: place.iconName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(point)
                    .accessibilityLabel("Plan trip to \(place.name)")
                }
            }
        }
        .id(cameraChangeToken)
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
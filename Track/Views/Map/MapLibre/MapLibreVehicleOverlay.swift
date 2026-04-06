// SwiftUI overlay that positions vehicle markers (bus, subway, LIRR, MNR)
// on top of the MapLibre GL map using coordinate-to-screen-point projection.
// Why an overlay instead of MLNAnnotationView?
// MapLibre's annotation system is UIKit-based and can't render complex
// SwiftUI views (spring animations, SF Symbols, gradient shadows).
// By projecting lat/lon → screen points we get full SwiftUI rendering
// with zero UIKit bridging overhead per marker.
// Performance: O(n) per frame where n = visible vehicles (typically < 50).
// The projection math is a single matrix multiply per coordinate.

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Vehicle Overlay

/// Renders live vehicle markers as a SwiftUI overlay positioned above
/// the MapLibre GL map. Each vehicle's lat/lon is projected to screen
/// coordinates every frame via `MLNMapView.convert(_:toPointTo:)`.
struct MapLibreVehicleOverlay: View {
    /// Reference to the underlying MapLibre map view for coordinate projection.
    let mapView: MLNMapView?

    /// Bus vehicles to display.
    let busVehicles: [BusVehicleResponse]

    /// Train vehicles to display.
    let trainVehicles: [TrainVehicle]

    /// Currently tapped vehicle ID (for highlight state).
    let tappedVehicleId: String?

    /// Callback when a vehicle is tapped.
    let onVehicleTap: (String) -> Void

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    var body: some View {
        GeometryReader { _ in
            ZStack {
                busVehicleMarkers
                trainVehicleMarkers
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Bus Markers (extracted to reduce body type-check)

    private var busVehicleMarkers: some View {
        ForEach(busVehicles) { vehicle in
            let coord = CLLocationCoordinate2D(
                latitude: vehicle.lat,
                longitude: vehicle.lon
            )
            let isHighlighted: Bool = tappedVehicleId == vehicle.vehicleId
            let isStale: Bool = {
                guard let recorded = vehicle.positionRecordedAt else { return false }
                return Date().timeIntervalSince(recorded) > 120 // >2 min = stale GPS
            }()
            if let point: CGPoint = projectToScreen(coord, mapView: mapView) {
                VehicleMarkerContent(
                    icon: TransportMode.bus.icon,
                    color: AppTheme.Colors.mtaBlue,
                    isHighlighted: isHighlighted
                ) {
                    toggleVehicle(vehicle.vehicleId)
                }
                .opacity(isStale ? 0.45 : 1.0)
                .position(point)
            }
        }
    }

    // MARK: - Train Markers (extracted to reduce body type-check)

    private var trainVehicleMarkers: some View {
        ForEach(trainVehicles) { train in
            let coord = CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            if let point = projectToScreen(coord, mapView: mapView) {
                trainMarkerContent(for: train)
                    .position(point)
            }
        }
    }

    private func trainMarkerContent(for train: TrainVehicle) -> some View {
        let rid: String = train.routeId.lowercased()
        let vehicleKey: String = train.tripId ?? train.id
        let isHighlighted: Bool = tappedVehicleId == vehicleKey

        return Group {
            if rid.contains("lirr") || rid.contains("lir") {
                VehicleMarkerContent(
                    icon: TransportMode.lirr.icon,
                    color: UIColor(AppTheme.CommuterRailColors.lirrBlue),
                    isHighlighted: isHighlighted
                ) { toggleVehicle(vehicleKey) }
            } else if rid.contains("mnr") || rid.contains("metro") {
                VehicleMarkerContent(
                    icon: TransportMode.mnr.icon,
                    color: UIColor(AppTheme.CommuterRailColors.mnrBlue),
                    isHighlighted: isHighlighted
                ) { toggleVehicle(vehicleKey) }
            } else {
                let expressVariants: Set<String> = ["6X", "7X", "FX"]
                let isExpress = expressVariants.contains(train.routeId.uppercased())
                VehicleMarkerContent(
                    icon: TransportMode.subway.icon,
                    color: AppTheme.SubwayColors.color(for: train.routeId),
                    isHighlighted: isHighlighted,
                    isExpress: isExpress
                ) { toggleVehicle(vehicleKey) }
            }
        }
    }

    private func toggleVehicle(_ id: String) {
        onVehicleTap(id)
    }
}

// MARK: - VehicleMarkerContent Extension (UIColor init)

extension VehicleMarkerContent {
    /// Convenience initializer accepting UIColor for MapLibre bridge.
    init(icon: String, color: UIColor, isHighlighted: Bool, isExpress: Bool = false, onTap: (() -> Void)? = nil) {
        self.init(icon: icon, color: Color(color), isHighlighted: isHighlighted, isExpress: isExpress, onTap: onTap)
    }
}

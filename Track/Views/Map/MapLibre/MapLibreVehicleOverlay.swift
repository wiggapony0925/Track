//
//  MapLibreVehicleOverlay.swift
//  Track
//
//  SwiftUI overlay that positions vehicle markers (bus, subway, LIRR, MNR)
//  on top of the MapLibre GL map using coordinate-to-screen-point projection.
//
//  Why an overlay instead of MLNAnnotationView?
//  MapLibre's annotation system is UIKit-based and can't render complex
//  SwiftUI views (spring animations, SF Symbols, gradient shadows).
//  By projecting lat/lon → screen points we get full SwiftUI rendering
//  with zero UIKit bridging overhead per marker.
//
//  Performance: O(n) per frame where n = visible vehicles (typically < 50).
//  The projection math is a single matrix multiply per coordinate.
//

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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bus vehicles
                ForEach(busVehicles) { vehicle in
                    let coord = CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
                    if let point = projectToScreen(coord, in: geo) {
                        VehicleMarkerContent(
                            icon: TransportMode.bus.icon,
                            color: AppTheme.Colors.mtaBlue,
                            isHighlighted: tappedVehicleId == vehicle.vehicleId
                        ) {
                            toggleVehicle(vehicle.vehicleId)
                        }
                        .position(point)
                    }
                }

                // Train vehicles
                ForEach(trainVehicles) { train in
                    let coord = CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
                    if let point = projectToScreen(coord, in: geo) {
                        let rid = train.routeId.lowercased()
                        let vehicleKey = train.tripId ?? train.id
                        let isHighlighted = tappedVehicleId == vehicleKey

                        if rid.contains("lirr") || rid.contains("lir") {
                            VehicleMarkerContent(
                                icon: TransportMode.lirr.icon,
                                color: UIColor(AppTheme.CommuterRailColors.lirrBlue),
                                isHighlighted: isHighlighted
                            ) { toggleVehicle(vehicleKey) }
                            .position(point)
                        } else if rid.contains("mnr") || rid.contains("metro") {
                            VehicleMarkerContent(
                                icon: TransportMode.mnr.icon,
                                color: UIColor(AppTheme.CommuterRailColors.mnrBlue),
                                isHighlighted: isHighlighted
                            ) { toggleVehicle(vehicleKey) }
                            .position(point)
                        } else {
                            VehicleMarkerContent(
                                icon: TransportMode.subway.icon,
                                color: UIColor(AppTheme.SubwayColors.color(for: train.routeId)),
                                isHighlighted: isHighlighted
                            ) { toggleVehicle(vehicleKey) }
                            .position(point)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Coordinate Projection

    /// Projects a geographic coordinate to a screen point within the overlay.
    /// Returns `nil` if the coordinate is outside the visible map bounds.
    ///
    /// Complexity: O(1) — single matrix multiply via MapLibre's projection.
    private func projectToScreen(
        _ coordinate: CLLocationCoordinate2D,
        in geometry: GeometryProxy
    ) -> CGPoint? {
        guard let mapView else { return nil }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        // Cull off-screen markers (with margin for marker size)
        let margin: CGFloat = 40
        guard point.x > -margin, point.x < mapView.bounds.width + margin,
              point.y > -margin, point.y < mapView.bounds.height + margin
        else { return nil }
        return point
    }

    private func toggleVehicle(_ id: String) {
        onVehicleTap(id)
    }
}

// MARK: - VehicleMarkerContent Extension (UIColor init)

extension VehicleMarkerContent {
    /// Convenience initializer accepting UIColor for MapLibre bridge.
    init(icon: String, color: UIColor, isHighlighted: Bool, onTap: (() -> Void)? = nil) {
        self.init(icon: icon, color: Color(color), isHighlighted: isHighlighted, onTap: onTap)
    }
}

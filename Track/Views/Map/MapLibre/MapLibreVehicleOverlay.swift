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

    /// Backend-owned live detail metadata keyed by vehicle id and trip id.
    let liveVehicleDetailsByKey: [String: LiveVehicleDetailResponse]

    /// Currently tapped vehicle ID (for highlight state).
    let tappedVehicleId: String?

    /// Callback when a vehicle is tapped.
    let onVehicleTap: (String) -> Void

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    /// Optional lookup closure: given a bus routeId, returns the route's color.
    /// When nil, falls back to the generic MTA blue.
    var busColorLookup: ((String) -> Color)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            GeometryReader { _ in
                let _ = cameraChangeToken
                ZStack {
                    busVehicleMarkers(now: timeline.date)
                    trainVehicleMarkers(now: timeline.date)
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Bus Markers (extracted to reduce body type-check)

    private func busVehicleMarkers(now: Date) -> some View {
        ForEach(busVehicles) { vehicle in
            let coord = CLLocationCoordinate2D(
                latitude: vehicle.lat,
                longitude: vehicle.lon
            )
            let isHighlighted: Bool = tappedVehicleId == vehicle.vehicleId
            let detail = liveVehicleDetailsByKey[vehicle.vehicleId]
            let updateAge = detail?.effectivePositionAgeSeconds(now: now)
                ?? vehicle.positionRecordedAt.map { now.timeIntervalSince($0) }
            let markerColor: Color = busColorLookup?(vehicle.routeId) ?? AppTheme.Colors.mtaBlue
            let quality = markerQuality(
                detail: detail,
                updateAge: updateAge,
                isCrowdsourced: vehicle.isCrowdsourced ?? false
            )
            if let point: CGPoint = projectToScreen(coord, mapView: mapView) {
                VehicleMarkerContent(
                    icon: TransportMode.bus.icon,
                    color: markerColor,
                    isHighlighted: isHighlighted,
                    occupancy: vehicle.occupancy,
                    updateAgeSeconds: updateAge,
                    isGhost: vehicle.isCrowdsourced ?? false,
                    quality: quality
                ) {
                    toggleVehicle(vehicle.vehicleId)
                }
                .position(point)
                .id(vehicle.vehicleId)
            }
        }
    }

    // MARK: - Train Markers (extracted to reduce body type-check)

    private func trainVehicleMarkers(now: Date) -> some View {
        ForEach(trainVehicles) { train in
            let coord = CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            if let point = projectToScreen(coord, mapView: mapView) {
                trainMarkerContent(for: train, now: now)
                    .position(point)
                    .id(train.id)
            }
        }
    }

    private func trainMarkerContent(for train: TrainVehicle, now: Date) -> some View {
        let rid: String = train.routeId.lowercased()
        let vehicleKey: String = train.tripId ?? train.id
        let isHighlighted: Bool = tappedVehicleId == vehicleKey || tappedVehicleId == train.id
        let detail = liveVehicleDetailsByKey[vehicleKey] ?? liveVehicleDetailsByKey[train.id]
        let updateAge = detail?.effectivePositionAgeSeconds(now: now)
            ?? train.timestamp.map { now.timeIntervalSince1970 - Double($0) }
        let quality = markerQuality(detail: detail, updateAge: updateAge, isCrowdsourced: false)

        return Group {
            if rid.contains("lirr") || rid.contains("lir") {
                VehicleMarkerContent(
                    icon: TransportMode.lirr.icon,
                    color: UIColor(AppTheme.CommuterRailColors.lirrBlue),
                    isHighlighted: isHighlighted,
                    occupancy: train.occupancy,
                    updateAgeSeconds: updateAge,
                    quality: quality
                ) { toggleVehicle(vehicleKey) }
            } else if rid.contains("mnr") || rid.contains("metro") {
                VehicleMarkerContent(
                    icon: TransportMode.mnr.icon,
                    color: UIColor(AppTheme.CommuterRailColors.mnrBlue),
                    isHighlighted: isHighlighted,
                    occupancy: train.occupancy,
                    updateAgeSeconds: updateAge,
                    quality: quality
                ) { toggleVehicle(vehicleKey) }
            } else {
                let expressVariants: Set<String> = ["6X", "7X", "FX"]
                let isExpress = expressVariants.contains(train.routeId.uppercased())
                VehicleMarkerContent(
                    icon: TransportMode.subway.icon,
                    color: AppTheme.SubwayColors.color(for: train.routeId),
                    isHighlighted: isHighlighted,
                    isExpress: isExpress,
                    occupancy: train.occupancy,
                    updateAgeSeconds: updateAge,
                    quality: quality
                ) { toggleVehicle(vehicleKey) }
            }
        }
    }

    private func markerQuality(
        detail: LiveVehicleDetailResponse?,
        updateAge: TimeInterval?,
        isCrowdsourced: Bool
    ) -> VehicleMarkerQuality {
        if detail?.isStale == true { return .stale }
        if let updateAge, updateAge > 180 { return .stale }
        if isCrowdsourced { return .estimated }
        if let detail {
            if detail.positionConfidence < 0.7 { return .estimated }
            if detail.positionSource == "interpolated" || detail.positionSource == "stop_anchor" {
                return .estimated
            }
        }
        if let updateAge, updateAge > 90 { return .estimated }
        return .live
    }

    private func toggleVehicle(_ id: String) {
        onVehicleTap(id)
    }
}

// MARK: - VehicleMarkerContent Extension (UIColor init)

extension VehicleMarkerContent {
    /// Convenience initializer accepting UIColor for MapLibre bridge.
    init(
        icon: String,
        color: UIColor,
        isHighlighted: Bool,
        isExpress: Bool = false,
        occupancy: Int? = nil,
        updateAgeSeconds: TimeInterval? = nil,
        isGhost: Bool = false,
        quality: VehicleMarkerQuality = .live,
        onTap: (() -> Void)? = nil
    ) {
        self.init(
            icon: icon,
            color: Color(color),
            isHighlighted: isHighlighted,
            isExpress: isExpress,
            occupancy: occupancy,
            updateAgeSeconds: updateAgeSeconds,
            isGhost: isGhost,
            quality: quality,
            onTap: onTap
        )
    }
}

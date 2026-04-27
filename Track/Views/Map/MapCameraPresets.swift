// Reusable map camera helpers for the Track NYC Transit App.
// Every view that sets `cameraPosition` should use these presets
// instead of constructing TrackCamera(...) inline.
// Usage:
//     cameraPosition = MapCameraPresets.center(on: coord, is3D: false)
//     cameraPosition = MapCameraPresets.fitWalkingPath(
//         user: userCoord, stop: stopCoord, is3D: true
//     )

import SwiftUI
import CoreLocation

enum MapCameraPresets {

    // MARK: - Settings (all from AppSettings → settings.json)

    private static var s: AppSettings { AppSettings.shared }

    // MARK: - Distances (meters → camera altitude)

    /// Comfortable street-level default — the "home" zoom.
    static var defaultDistance: Double { s.userZoomDistance }

    /// Zoomed-in view for focusing on a vehicle marker.
    static var vehicleFocusDistance: Double { s.vehicleFocusDistance }

    /// Slightly wider view for "Explore NYC" overview.
    static var explorerDistance: Double { s.userZoomDistance * s.explorerDistanceMultiplier }

    // MARK: - Walking Path Fit

    /// Minimum camera altitude for a walking-path fit.
    static var walkingMinAltitude: Double { s.walkingZoomMinAltitude }

    /// Maximum camera altitude — beyond this the walk isn't practical to visualize.
    static var walkingMaxAltitude: Double { s.walkingZoomMaxAltitude }

    // MARK: - Animations
    //
    // These are now deprecated aliases forwarding to HoverAnimations,
    // which is the single source of truth.  Existing call sites continue
    // to work — migrate to HoverAnimations.fly / .snap / .smooth over time.

    /// Standard camera fly animation. Deprecated: use `HoverAnimations.fly`.
    @available(*, deprecated, renamed: "HoverAnimations.fly")
    static var flyAnimation: Animation { HoverAnimations.fly }

    /// Snappier animation for sheet transitions. Deprecated: use `HoverAnimations.snap`.
    @available(*, deprecated, renamed: "HoverAnimations.snap")
    static var snapAnimation: Animation { HoverAnimations.snap }

    /// Longer smooth animation for 3D toggles. Deprecated: use `HoverAnimations.smooth`.
    @available(*, deprecated, renamed: "HoverAnimations.smooth")
    static var smoothAnimation: Animation { HoverAnimations.smooth }

    // MARK: - Camera Constructors

    /// Center the map on a coordinate at the standard default zoom.
    static func center(on coordinate: CLLocationCoordinate2D, is3D: Bool) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: coordinate,
            distance: defaultDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Center the map on a coordinate at a specific distance.
    static func center(
        on coordinate: CLLocationCoordinate2D,
        distance: Double,
        is3D: Bool
    ) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: coordinate,
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Focus on a vehicle marker — tighter zoom at `vehicleFocusDistance`.
    static func focusVehicle(
        at coordinate: CLLocationCoordinate2D,
        is3D: Bool
    ) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: coordinate,
            distance: vehicleFocusDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Wide overview for exploring NYC (slightly wider than default).
    static func explorer(is3D: Bool) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: AppTheme.MapConfig.nycCenter,
            distance: explorerDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    // MARK: - Walking Path Geometry (shared computation)

    /// Intermediate result of bounding-box + adaptive padding analysis.
    private struct WalkingPathGeometry {
        let centerLat: Double
        let centerLon: Double
        let spanMeters: Double
        let basePadding: Double
    }

    /// Computes bounding box, span, and adaptive padding tier for two points.
    private static func walkingGeometry(
        user userCoord: CLLocationCoordinate2D,
        stop stopCoord: CLLocationCoordinate2D
    ) -> WalkingPathGeometry {
        let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let stopLoc = CLLocation(latitude: stopCoord.latitude, longitude: stopCoord.longitude)
        let straightLine = userLoc.distance(from: stopLoc)

        let minLat = min(userCoord.latitude, stopCoord.latitude)
        let maxLat = max(userCoord.latitude, stopCoord.latitude)
        let minLon = min(userCoord.longitude, stopCoord.longitude)
        let maxLon = max(userCoord.longitude, stopCoord.longitude)

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        let latSpanMeters = (maxLat - minLat) * 111_000
        let lonSpanMeters = (maxLon - minLon) * 111_000 * cos(centerLat * .pi / 180)
        let spanMeters = max(latSpanMeters, lonSpanMeters)

        let basePadding: Double
        if straightLine < s.walkingCloseThresholdMeters {
            basePadding = s.walkingClosePadding
        } else if straightLine < s.walkingMediumThresholdMeters {
            basePadding = s.walkingMediumPadding
        } else {
            basePadding = s.walkingFarPadding
        }

        return WalkingPathGeometry(
            centerLat: centerLat,
            centerLon: centerLon,
            spanMeters: spanMeters,
            basePadding: basePadding
        )
    }


    // MARK: - Walking Path Fit

    /// Fit the user's walking path from their location to the nearest stop.
    static func fitWalkingPath(
        user userCoord: CLLocationCoordinate2D,
        stop stopCoord: CLLocationCoordinate2D,
        is3D: Bool
    ) -> TrackCameraPosition {
        let geo = walkingGeometry(user: userCoord, stop: stopCoord)
        let distance = max(
            walkingMinAltitude,
            min(geo.spanMeters * geo.basePadding,
                walkingMaxAltitude)
        )

        let bias = s.walkingCenterBias
        let biasedLat = geo.centerLat + (stopCoord.latitude - geo.centerLat) * bias
        let biasedLon = geo.centerLon + (stopCoord.longitude - geo.centerLon) * bias

        return .camera(TrackCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: biasedLat, longitude: biasedLon),
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Fit two arbitrary points with smart zoom clamping (midpoint center).
    static func fitTwoPoints(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        is3D: Bool
    ) -> TrackCameraPosition {
        let midLat = (from.latitude + to.latitude) / 2
        let midLon = (from.longitude + to.longitude) / 2

        let fromLoc = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLoc = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let distanceMeters = fromLoc.distance(from: toLoc)

        let zoomDistance = max(
            AppSettings.shared.smartZoomMinAltitude,
            min(distanceMeters * AppSettings.shared.smartZoomPaddingMultiplier,
                AppSettings.shared.smartZoomMaxAltitude)
        )

        return .camera(TrackCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
            distance: zoomDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    // MARK: - Walking Route Bounding-Box Fit

    /// Fits a walking route bounding box in the visible map area.
    ///
    /// - Parameters:
    ///   - latSpanMeters: North-south span of the route bounding box in meters.
    ///   - lonSpanMeters: East-west span of the route bounding box in meters.
    ///   - center: Geographic center of the bounding box.
    ///   - is3D: Whether 3D perspective is active.
    static func fitWalkingRoute(
        latSpanMeters: Double,
        lonSpanMeters: Double,
        center: CLLocationCoordinate2D,
        is3D: Bool
    ) -> TrackCameraPosition {
        let maxSpanMeters = max(latSpanMeters, lonSpanMeters)
        let distance = max(walkingMinAltitude, min(maxSpanMeters * 3.2, walkingMaxAltitude))

        return .camera(TrackCamera(
            centerCoordinate: center,
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    // MARK: - Route Detail Fit

    /// Frames the route-detail "boarding scene" in the same spirit as Transit:
    /// nearby selected-direction corridor, boarding stop, and walk from the
    /// user's reference point, without zooming out to the whole route.
    static func fitRouteDetailScene(
        user userCoord: CLLocationCoordinate2D?,
        stop stopCoord: CLLocationCoordinate2D,
        routePoints: [CLLocationCoordinate2D],
        walkingPoints: [CLLocationCoordinate2D],
        is3D: Bool
    ) -> TrackCameraPosition {
        let localRoutePoints = nearbyCoordinates(routePoints, to: stopCoord, maxMeters: 3_200)
        let localWalkingPoints = nearbyCoordinates(walkingPoints, to: stopCoord, maxMeters: 2_400)

        var scenePoints: [CLLocationCoordinate2D] = [stopCoord]
        scenePoints.append(contentsOf: localRoutePoints)
        scenePoints.append(contentsOf: localWalkingPoints)
        if let userCoord {
            scenePoints.append(userCoord)
        }

        guard let geometry = boundsGeometry(for: scenePoints) else {
            return center(on: stopCoord, distance: 1600, is3D: false)
        }

        let maxSpanMeters = max(geometry.latSpanMeters, geometry.lonSpanMeters)
        let distance = max(1500, min(maxSpanMeters * 3.35, 7200))

        var center = geometry.center
        let routeFocusPoints = localRoutePoints.isEmpty ? [stopCoord] : localRoutePoints + [stopCoord]
        if let routeFocus = averageCoordinate(routeFocusPoints) {
            // Keep the active route visually dominant even when the walk is angled
            // away from it, then apply a sheet-aware center bias below.
            center = interpolate(from: center, to: routeFocus, fraction: 0.12)
        }
        center = routeDetailSheetAwareCenter(
            center: center,
            geometry: geometry,
            maxSpanMeters: maxSpanMeters
        )

        return .camera(TrackCamera(
            centerCoordinate: center,
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    private static func nearbyCoordinates(
        _ coordinates: [CLLocationCoordinate2D],
        to anchor: CLLocationCoordinate2D,
        maxMeters: Double
    ) -> [CLLocationCoordinate2D] {
        coordinates.filter { coordinate in
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return false }
            return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: anchor.latitude, longitude: anchor.longitude))
                <= maxMeters
        }
    }

    private struct BoundsGeometry {
        let center: CLLocationCoordinate2D
        let minLat: Double
        let maxLat: Double
        let latSpanMeters: Double
        let lonSpanMeters: Double
    }

    private static func boundsGeometry(
        for coordinates: [CLLocationCoordinate2D]
    ) -> BoundsGeometry? {
        let valid = coordinates.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard let first = valid.first else { return nil }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in valid.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latSpanMeters = (maxLat - minLat) * 111_000
        let lonSpanMeters = (maxLon - minLon) * 111_000 * cos(center.latitude * .pi / 180)

        return BoundsGeometry(
            center: center,
            minLat: minLat,
            maxLat: maxLat,
            latSpanMeters: latSpanMeters,
            lonSpanMeters: lonSpanMeters
        )
    }

    private static func averageCoordinate(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        let valid = coordinates.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard !valid.isEmpty else { return nil }

        let sums = valid.reduce((lat: 0.0, lon: 0.0)) { partial, coordinate in
            (partial.lat + coordinate.latitude, partial.lon + coordinate.longitude)
        }
        let count = Double(valid.count)
        return CLLocationCoordinate2D(
            latitude: sums.lat / count,
            longitude: sums.lon / count
        )
    }

    private static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        let clamped = max(0, min(1, fraction))
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * clamped,
            longitude: start.longitude + (end.longitude - start.longitude) * clamped
        )
    }

    private static func routeDetailSheetAwareCenter(
        center: CLLocationCoordinate2D,
        geometry: BoundsGeometry,
        maxSpanMeters: Double
    ) -> CLLocationCoordinate2D {
        let spanLatDegrees = max(geometry.maxLat - geometry.minLat, 0.0018)
        let sheetClearanceMeters = max(260, min(maxSpanMeters * 0.20, 760))
        let sheetClearanceDegrees = sheetClearanceMeters / 111_000
        return CLLocationCoordinate2D(
            latitude: center.latitude - (spanLatDegrees * 0.14) - sheetClearanceDegrees,
            longitude: center.longitude
        )
    }
}

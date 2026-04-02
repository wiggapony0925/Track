// Reusable map camera helpers for the Track NYC Transit App.
// Every view that sets `cameraPosition` should use these presets
// instead of constructing TrackCamera(...) inline.
// Usage:
//     cameraPosition = MapCameraPresets.center(on: coord, is3D: is3DMode)
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

    /// Standard camera fly animation (route open, direction change, recenter).
    static let flyAnimation: Animation = .spring(response: 0.6, dampingFraction: 0.85)

    /// Snappier animation for sheet transitions + quick recenters.
    static let snapAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.8)

    /// Longer smooth animation for 3D toggles and explore-NYC button.
    static let smoothAnimation: Animation = .easeInOut(duration: 0.8)

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

    // MARK: - Sheet Latitude Shift (shared formula)

    /// Computes the southward latitude shift needed to move the camera's
    /// visible center into the unobscured area above the bottom sheet.
    private static func sheetLatitudeShift(
        distance: Double,
        pitch: Double,
        sheetFraction: Double
    ) -> Double {
        let pitchRad = pitch * .pi / 180.0
        let altitude = distance * max(cos(pitchRad), 0.3)
        let halfFOV: Double = .pi / 8.0
        let fullSpanDeg = (2.0 * altitude * tan(halfFOV)) / 111_000.0
        return fullSpanDeg * sheetFraction * 0.5
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

    // MARK: - Walking Path + Sheet Integration

    /// Fits user and stop in the visible map area **above** the bottom sheet.
    static func fitWalkingPathAboveSheet(
        user userCoord: CLLocationCoordinate2D,
        stop stopCoord: CLLocationCoordinate2D,
        is3D: Bool,
        sheetFraction: Double
    ) -> TrackCameraPosition {
        return fitTwoPoints(from: userCoord, to: stopCoord, is3D: is3D)
    }

    // MARK: - Actual Walking Route Fit

    /// Fits a walking route bounding box in the visible map area **above** the bottom sheet.
    /// This provides a perfect fit for the actual walking path (including city block corners)
    /// rather than just drawing a straight line.
    ///
    /// - Parameters:
    ///   - latSpanMeters: North-south span of the route bounding box in meters.
    ///   - lonSpanMeters: East-west span of the route bounding box in meters.
    ///   - center: Geographic center of the bounding box.
    ///   - is3D: Whether 3D perspective is active.
    ///   - sheetFraction: Fraction of the screen covered by the bottom sheet.
    static func fitWalkingRouteAboveSheet(
        latSpanMeters: Double,
        lonSpanMeters: Double,
        center: CLLocationCoordinate2D,
        is3D: Bool,
        sheetFraction: Double
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

    // MARK: - Sheet Compensation

    /// Adjusts any camera position so the focal point appears in the visible
    /// area ABOVE the bottom sheet rather than behind it.
    static func sheetCompensated(
        _ position: TrackCameraPosition,
        sheetFraction: Double
    ) -> TrackCameraPosition {
        guard sheetFraction > 0.05 && sheetFraction < 0.95 else { return position }
        guard let camera = position.camera else { return position }

        let latShift = sheetLatitudeShift(
            distance: camera.distance,
            pitch: camera.pitch,
            sheetFraction: sheetFraction
        )

        return .camera(TrackCamera(
            centerCoordinate: CLLocationCoordinate2D(
                latitude: camera.centerCoordinate.latitude - latShift,
                longitude: camera.centerCoordinate.longitude
            ),
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        ))
    }
}

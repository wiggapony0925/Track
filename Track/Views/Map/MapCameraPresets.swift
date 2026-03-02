//
//  MapCameraPresets.swift
//  Track
//
//  Reusable map camera helpers for the Track NYC Transit App.
//  Every view that sets `cameraPosition` should use these presets
//  instead of constructing MapCamera(...) inline.
//
//  Usage:
//      cameraPosition = MapCameraPresets.center(on: coord, is3D: is3DMode)
//      cameraPosition = MapCameraPresets.fitWalkingPath(user: userCoord, stop: stopCoord, is3D: true)
//

import SwiftUI
import MapKit

enum MapCameraPresets {

    // MARK: - Settings (all from AppSettings → settings.json)

    private static var s: AppSettings { AppSettings.shared }

    // MARK: - Distances (meters → MapCamera altitude)

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
    static func center(on coordinate: CLLocationCoordinate2D, is3D: Bool) -> MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: coordinate,
            distance: defaultDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Center the map on a coordinate at a specific distance.
    static func center(on coordinate: CLLocationCoordinate2D, distance: Double, is3D: Bool) -> MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: coordinate,
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Focus on a vehicle marker — tighter zoom at `vehicleFocusDistance`.
    static func focusVehicle(at coordinate: CLLocationCoordinate2D, is3D: Bool) -> MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: coordinate,
            distance: vehicleFocusDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Wide overview for exploring NYC (slightly wider than default).
    static func explorer(is3D: Bool) -> MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: AppTheme.MapConfig.nycCenter,
            distance: explorerDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    // MARK: - Walking Path Geometry (shared computation)

    /// Intermediate result of bounding-box + adaptive padding analysis.
    /// Used by `fitWalkingPath` and `fitWalkingPathAboveSheet` to avoid
    /// duplicating the same geometry and tier-selection logic.
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
    ///
    /// Used by both `fitWalkingPathAboveSheet` and `sheetCompensated` so
    /// the FOV → shift math lives in exactly one place.
    ///
    /// Uses a conservative vertical half-FOV of 22.5° (`π/8`) rather than
    /// 30° — MapKit on tall iPhone screens (19.5:9 aspect) has a noticeably
    /// narrower vertical FOV than the often-cited 60° total.  Overestimating
    /// the FOV causes an excessive south-shift that pushes both the user's
    /// location and the transit stop off the visible area.
    private static func sheetLatitudeShift(
        distance: Double,
        pitch: Double,
        sheetFraction: Double
    ) -> Double {
        let pitchRad = pitch * .pi / 180.0
        let altitude = distance * max(cos(pitchRad), 0.3)
        let halfFOV: Double = .pi / 8.0   // ~22.5° — conservative for tall screens
        let fullSpanDeg = (2.0 * altitude * tan(halfFOV)) / 111_000.0
        return fullSpanDeg * sheetFraction * 0.5
    }

    // MARK: - Walking Path Fit

    /// Fit the user's walking path from their location to the nearest stop.
    ///
    /// Adaptive padding based on straight-line distance:
    /// - Very close (< 200m): 3.5× — tight street view
    /// - Medium (200–800m): 2.8× — comfortable walking view
    /// - Farther (> 800m): 2.2× — wider neighborhood view
    ///
    /// The center is biased 15% toward the stop so the user's blue dot
    /// sits in the lower third and the destination is prominent.
    static func fitWalkingPath(
        user userCoord: CLLocationCoordinate2D,
        stop stopCoord: CLLocationCoordinate2D,
        is3D: Bool
    ) -> MapCameraPosition {
        let geo = walkingGeometry(user: userCoord, stop: stopCoord)
        let distance = max(walkingMinAltitude, min(geo.spanMeters * geo.basePadding, walkingMaxAltitude))

        let bias = s.walkingCenterBias
        let biasedLat = geo.centerLat + (stopCoord.latitude - geo.centerLat) * bias
        let biasedLon = geo.centerLon + (stopCoord.longitude - geo.centerLon) * bias

        return .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: biasedLat, longitude: biasedLon),
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    /// Fit two arbitrary points with smart zoom clamping (midpoint center).
    /// Used by `centerMap(on:)` where we want to show both user and a target.
    static func fitTwoPoints(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        is3D: Bool
    ) -> MapCameraPosition {
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

        return .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
            distance: zoomDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }

    // MARK: - Walking Path + Sheet Integration

    /// Fits user and stop in the visible map area **above** the bottom sheet.
    ///
    /// When a sheet covers part of the screen, delegates to the proven
    /// `fitTwoPoints` zoom (min 2400 m, 4.5× padding) then applies
    /// `sheetCompensated` to shift the center south.  This is the same
    /// approach used by `centerMap(on:)` — it works reliably across
    /// every NYC distance range (50 m at-stop to 3+ km commuter rail)
    /// without fragile FOV guesswork.
    ///
    /// Falls back to `fitWalkingPath` when `sheetFraction ≈ 0`.
    static func fitWalkingPathAboveSheet(
        user userCoord: CLLocationCoordinate2D,
        stop stopCoord: CLLocationCoordinate2D,
        is3D: Bool,
        sheetFraction: Double
    ) -> MapCameraPosition {
        // TrackMapView already sets `.safeAreaPadding(.bottom, 350)` on the SwiftUI Map,
        // so MapKit natively centers geometry in the unobscured top area.
        // Calling sheetCompensated on top of that shifts the camera twice — causing the
        // "too far up" issue. Return the base fit directly.
        return fitTwoPoints(from: userCoord, to: stopCoord, is3D: is3D)
    }

    // MARK: - Actual Walking Route Fit

    /// Fits an exact MKRoute polyline bounding rect in the visible map area **above** the bottom sheet.
    /// This provides a perfect fit for the actual walking path (including city block corners)
    /// rather than just drawing a straight line.
    static func fitWalkingRouteAboveSheet(
        route: MKRoute,
        is3D: Bool,
        sheetFraction: Double
    ) -> MapCameraPosition {
        let rect = route.polyline.boundingMapRect
        
        let point1 = MKMapPoint(x: rect.midX, y: rect.minY)
        let point2 = MKMapPoint(x: rect.midX, y: rect.maxY)
        let latSpanMeters = point1.distance(to: point2)
        
        let point3 = MKMapPoint(x: rect.minX, y: rect.midY)
        let point4 = MKMapPoint(x: rect.maxX, y: rect.midY)
        let lonSpanMeters = point3.distance(to: point4)
        
        let maxSpanMeters = max(latSpanMeters, lonSpanMeters)
        
        // Use a slightly wider padding (3.2x instead of 2.8x) so it's not cutting off at the edges
        let distance = max(walkingMinAltitude, min(maxSpanMeters * 3.2, walkingMaxAltitude))
        
        // Exact geographic center of the route's bounds
        let centerCoord = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        
        let baseCamera = MapCameraPosition.camera(MapCamera(
            centerCoordinate: centerCoord,
            distance: distance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
        
        // TrackMapView already sets `.safeAreaPadding(.bottom, 350)`.
        // If we also apply `sheetCompensated`, the camera gets shifted *twice*, 
        // pushing the actual route out of the center and into the top notch!
        // Returning the unshifted baseCamera lets SwiftUI Map natively perfectly center it 
        // in the remaining unobscured top area.
        return baseCamera
    }

    // MARK: - Sheet Compensation

    /// Adjusts any camera position so the focal point appears in the visible
    /// area ABOVE the bottom sheet rather than behind it.
    ///
    /// Shifts the camera center **southward** by an amount derived from
    /// `sheetLatitudeShift` so the original target coordinate appears at
    /// the center of the unobscured map area.
    ///
    /// No zoom-out is applied — callers that need integrated zoom+shift
    /// should use `fitWalkingPathAboveSheet` instead.
    ///
    /// - Parameters:
    ///   - position: The camera position to adjust.
    ///   - sheetFraction: How much of the screen the sheet covers (0.0–1.0).
    /// - Returns: A new `MapCameraPosition` with the center shifted south.
    static func sheetCompensated(
        _ position: MapCameraPosition,
        sheetFraction: Double
    ) -> MapCameraPosition {
        guard sheetFraction > 0.05 && sheetFraction < 0.95 else { return position }
        guard let camera = position.camera else { return position }

        let latShift = sheetLatitudeShift(
            distance: camera.distance,
            pitch: camera.pitch,
            sheetFraction: sheetFraction
        )

        return .camera(MapCamera(
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

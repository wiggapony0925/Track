//
//  MapLibreSearchRadiusLayer.swift
//  Track
//
//  Renders the three concentric search radius circles on the MapLibre map
//  using MLNCircleStyleLayer / MLNFillStyleLayer with GeoJSON polygon sources.
//
//  Native GL circle/fill layer for the drag-to-search radius ring.
//  Uses the same color scheme: green (near), blue (farther), yellow (much farther).
//

import CoreLocation
import Foundation
import MapLibre

// MARK: - Search Radius Layer Manager

/// Manages the three search radius circle layers on the MapLibre map.
///
/// Circles are approximated as 64-point polygons in GeoJSON, which
/// MapLibre renders as fill + stroke layers with the same gradient
/// appearance.
enum MapLibreSearchRadiusManager {

    // MARK: - Layer/Source IDs

    private static let nearSourceID = "search-radius-near-source"
    private static let nearFillID = "search-radius-near-fill"
    private static let nearStrokeID = "search-radius-near-stroke"

    private static let fartherSourceID = "search-radius-farther-source"
    private static let fartherFillID = "search-radius-farther-fill"
    private static let fartherStrokeID = "search-radius-farther-stroke"

    private static let muchFartherSourceID = "search-radius-much-farther-source"
    private static let muchFartherFillID = "search-radius-much-farther-fill"
    private static let muchFartherStrokeID = "search-radius-much-farther-stroke"

    // MARK: - Update

    /// Updates or creates the search radius circle layers.
    ///
    /// - Parameters:
    ///   - style: The MapLibre style to add layers to.
    ///   - center: Center coordinate for the circles.
    ///   - nearRadius: Near-you radius in meters.
    ///   - fartherRadius: A-bit-farther radius in meters.
    ///   - muchFartherRadius: Much-farther radius in meters.
    ///   - visible: Whether the circles should be shown.
    static func update(
        style: MLNStyle,
        center: CLLocationCoordinate2D,
        nearRadius: Double,
        fartherRadius: Double,
        muchFartherRadius: Double,
        visible: Bool
    ) {
        guard visible else {
            // Hide all radius layers
            setLayerVisibility(style: style, layerIDs: [
                nearFillID, nearStrokeID,
                fartherFillID, fartherStrokeID,
                muchFartherFillID, muchFartherStrokeID,
            ], visible: false)
            return
        }

        // Much farther (outermost, drawn first)
        updateCircleLayer(
            style: style,
            sourceID: muchFartherSourceID,
            fillLayerID: muchFartherFillID,
            strokeLayerID: muchFartherStrokeID,
            center: center,
            radiusMeters: muchFartherRadius,
            fillColor: UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.06),
            strokeColor: UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.4),
            strokeWidth: 1.5,
            dashPattern: [8, 6]
        )

        // Farther
        updateCircleLayer(
            style: style,
            sourceID: fartherSourceID,
            fillLayerID: fartherFillID,
            strokeLayerID: fartherStrokeID,
            center: center,
            radiusMeters: fartherRadius,
            fillColor: UIColor(red: 214/255, green: 116/255, blue: 255/255, alpha: 0.08),
            strokeColor: UIColor(red: 214/255, green: 116/255, blue: 255/255, alpha: 0.50),
            strokeWidth: 1.5,
            dashPattern: [8, 6]
        )

        // Near (innermost, drawn last / on top)
        updateCircleLayer(
            style: style,
            sourceID: nearSourceID,
            fillLayerID: nearFillID,
            strokeLayerID: nearStrokeID,
            center: center,
            radiusMeters: nearRadius,
            fillColor: UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.08),
            strokeColor: UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.5),
            strokeWidth: 1.5,
            dashPattern: [8, 6]
        )
    }

    /// Removes all search radius layers from the style.
    static func removeAll(style: MLNStyle) {
        let layerIDs = [
            nearFillID, nearStrokeID,
            fartherFillID, fartherStrokeID,
            muchFartherFillID, muchFartherStrokeID,
        ]
        let sourceIDs = [nearSourceID, fartherSourceID, muchFartherSourceID]

        for id in layerIDs {
            if let layer = style.layer(withIdentifier: id) {
                style.removeLayer(layer)
            }
        }
        for id in sourceIDs {
            if let source = style.source(withIdentifier: id) {
                style.removeSource(source)
            }
        }
    }

    // MARK: - Private Helpers

    private static func updateCircleLayer(
        style: MLNStyle,
        sourceID: String,
        fillLayerID: String,
        strokeLayerID: String,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        fillColor: UIColor,
        strokeColor: UIColor,
        strokeWidth: CGFloat,
        dashPattern: [NSNumber]
    ) {
        let polygon = circlePolygon(center: center, radiusMeters: radiusMeters, segments: 64)

        if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
            source.shape = polygon
        } else {
            let source = MLNShapeSource(identifier: sourceID, shape: polygon, options: nil)
            style.addSource(source)

            // Fill
            let fill = MLNFillStyleLayer(identifier: fillLayerID, source: source)
            fill.fillColor = NSExpression(forConstantValue: fillColor)
            fill.fillOpacity = NSExpression(forConstantValue: NSNumber(value: 1.0))
            style.addLayer(fill)

            // Stroke
            let stroke = MLNLineStyleLayer(identifier: strokeLayerID, source: source)
            stroke.lineColor = NSExpression(forConstantValue: strokeColor)
            stroke.lineWidth = NSExpression(forConstantValue: NSNumber(value: Float(strokeWidth)))
            stroke.lineDashPattern = NSExpression(forConstantValue: dashPattern)
            style.addLayer(stroke)
        }

        // Ensure visible
        if let fill = style.layer(withIdentifier: fillLayerID) as? MLNFillStyleLayer {
            fill.isVisible = true
        }
        if let stroke = style.layer(withIdentifier: strokeLayerID) as? MLNLineStyleLayer {
            stroke.isVisible = true
        }
    }

    private static func setLayerVisibility(style: MLNStyle, layerIDs: [String], visible: Bool) {
        for id in layerIDs {
            if let layer = style.layer(withIdentifier: id) {
                layer.isVisible = visible
            }
        }
    }

    /// Creates a polygon approximating a circle at the given center and radius.
    ///
    /// Uses the Haversine formula to compute points along the circle perimeter,
    /// accounting for Earth's curvature (important at transit-scale radii).
    ///
    /// Complexity: O(segments) — typically 64 points.
    private static func circlePolygon(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        segments: Int
    ) -> MLNPolygon {
        let earthRadius: Double = 6_371_000.0
        let lat = center.latitude * .pi / 180.0
        let lon = center.longitude * .pi / 180.0
        let angularDistance = radiusMeters / earthRadius

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(segments + 1)

        for i in 0...segments {
            let bearing = Double(i) * 2.0 * .pi / Double(segments)
            let pointLat = asin(
                sin(lat) * cos(angularDistance)
                    + cos(lat) * sin(angularDistance) * cos(bearing)
            )
            let pointLon = lon + atan2(
                sin(bearing) * sin(angularDistance) * cos(lat),
                cos(angularDistance) - sin(lat) * sin(pointLat)
            )
            coordinates.append(CLLocationCoordinate2D(
                latitude: pointLat * 180.0 / .pi,
                longitude: pointLon * 180.0 / .pi
            ))
        }

        return MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
    }
}

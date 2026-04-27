import CoreLocation
import Testing
@testable import Track

@Suite("Map camera presets")
struct MapCameraPresetsTests {
    @Test func routeDetailFitIgnoresFarRouteGeometry() {
        let stop = CLLocationCoordinate2D(latitude: 40.7500, longitude: -74.0020)
        let nearbyRoute = CLLocationCoordinate2D(latitude: 40.7560, longitude: -74.0010)
        let farTerminal = CLLocationCoordinate2D(latitude: 40.8250, longitude: -73.9550)

        let position = MapCameraPresets.fitRouteDetailScene(
            user: nil,
            stop: stop,
            routePoints: [nearbyRoute, farTerminal],
            walkingPoints: [],
            is3D: false
        )

        guard let camera = position.camera else {
            Issue.record("Expected explicit route-detail camera")
            return
        }

        let center = CLLocation(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude
        )
        let stopLocation = CLLocation(latitude: stop.latitude, longitude: stop.longitude)

        #expect(center.distance(from: stopLocation) < 1_000)
        #expect(camera.distance < 2_500)
    }
}

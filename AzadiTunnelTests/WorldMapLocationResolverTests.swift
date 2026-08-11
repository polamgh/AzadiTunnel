import XCTest
@testable import AzadiTunnel

@MainActor
final class WorldMapLocationResolverTests: XCTestCase {
    func testExactEgressCoordinateWinsOverRegionFallback() {
        var statistics = TunnelStatistics()
        statistics.connectedServerRegion = "US"
        statistics.connectedLatitude = 35.6892
        statistics.connectedLongitude = 51.3890

        XCTAssertEqual(
            WorldMapLocationResolver.coordinate(for: statistics),
            WorldMapCoordinate(latitude: 35.6892, longitude: 51.3890)
        )
    }

    func testConnectedRegionProvidesOfflineFallback() {
        var statistics = TunnelStatistics()
        statistics.connectedServerRegion = "DE"

        XCTAssertEqual(
            WorldMapLocationResolver.coordinate(for: statistics),
            WorldMapCoordinate(latitude: 51.2, longitude: 10.4)
        )
    }

    func testMissingLocationDoesNotShowMarker() {
        XCTAssertNil(WorldMapLocationResolver.coordinate(for: TunnelStatistics()))
    }

    func testOriginUsesPreConnectIPCoordinate() {
        var statistics = TunnelStatistics()
        statistics.originLatitude = 35.6892
        statistics.originLongitude = 51.3890

        XCTAssertEqual(
            WorldMapLocationResolver.originCoordinate(for: statistics),
            WorldMapCoordinate(latitude: 35.6892, longitude: 51.3890)
        )
    }

    func testOriginRejectsInvalidCoordinate() {
        var statistics = TunnelStatistics()
        statistics.originLatitude = 120
        statistics.originLongitude = 51.3890

        XCTAssertNil(WorldMapLocationResolver.originCoordinate(for: statistics))
    }
}

import XCTest
@testable import AzadiTunnel

final class GeoHashTests: XCTestCase {
    func testTehranApproximateGeohash() {
        // Tehran city center — precision 4 is coarse enough for IP-derived origin hints.
        XCTAssertEqual(
            GeoHash.encode(latitude: 35.6892, longitude: 51.3890, precision: 4),
            "tnke"
        )
    }

    func testInvalidPrecisionRejected() {
        XCTAssertNil(GeoHash.encode(latitude: 35.0, longitude: 51.0, precision: 0))
        XCTAssertNil(GeoHash.encode(latitude: 35.0, longitude: 51.0, precision: 13))
    }
}

final class PsiphonDeviceOriginConfigTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearOriginGeo()
    }

    override func tearDown() {
        clearOriginGeo()
        super.tearDown()
    }

    func testApplyDeviceRegionAndLocationFromStoredOrigin() {
        TunnelStatisticsStore.setOriginGeo(
            ip: "1.2.3.4",
            city: "Tehran",
            country: "Iran",
            countryCode: "IR",
            latitude: 35.6892,
            longitude: 51.3890
        )

        var dict: [String: Any] = [:]
        PsiphonDeviceOriginConfig.apply(to: &dict)

        XCTAssertEqual(dict["DeviceRegion"] as? String, "IR")
        XCTAssertEqual(dict["DeviceLocation"] as? String, "tnke")
    }

    func testMissingOriginRemovesDeviceHints() {
        var dict: [String: Any] = [
            "DeviceRegion": "US",
            "DeviceLocation": "abc1"
        ]
        PsiphonDeviceOriginConfig.apply(to: &dict)
        XCTAssertNil(dict["DeviceRegion"])
        XCTAssertNil(dict["DeviceLocation"])
    }

    private func clearOriginGeo() {
        var stats = TunnelStatisticsStore.load()
        stats.originPublicIP = nil
        stats.originCity = nil
        stats.originCountry = nil
        stats.originCountryCode = nil
        stats.originLatitude = nil
        stats.originLongitude = nil
        stats.originCapturedAt = nil
        TunnelStatisticsStore.save(stats)
    }
}

final class PsiphonAndroidParityConfigTests: XCTestCase {
    func testAutoModeIncludesCdnHintsAndKeepsTactics() throws {
        var settings = AppSettings()
        settings.protocolSelection = .auto
        let json = try PsiphonConfigComposer.compose(baseJSON: baseConfigJSON(), settings: settings)
        let dict = try decode(json)

        XCTAssertTrue(AdaptiveTransportPolicy.includesCdnFrontingHints(for: .auto))
        XCTAssertNotNil(dict["FrontedMeekDialOverrides"])
        XCTAssertEqual(dict["FrontedMeekDialOverridesProbability"] as? Double, 1.0)
        XCTAssertEqual(dict["FrontedMeekCDNScanUseBuiltInSpec"] as? Bool, true)
        XCTAssertNil(dict["DisableTactics"])
    }

    func testDirectModeDisablesTacticsButKeepsCdnHints() throws {
        var settings = AppSettings()
        settings.protocolSelection = .direct
        let json = try PsiphonConfigComposer.compose(baseJSON: baseConfigJSON(), settings: settings)
        let dict = try decode(json)

        XCTAssertNotNil(dict["FrontedMeekDialOverrides"])
        XCTAssertEqual(dict["DisableTactics"] as? Bool, true)
        XCTAssertEqual(dict["LimitTunnelProtocols"] as? [String], PsiphonProtocolSets.direct)
    }

    func testExplicitCDNDefaultsToStaticDialOverridesLikeAndroid() throws {
        var settings = AppSettings()
        settings.protocolSelection = .cdnFronting
        settings.cdnFrontingAttemptStrategy = nil
        let json = try PsiphonConfigComposer.compose(baseJSON: baseConfigJSON(), settings: settings)
        let dict = try decode(json)

        let overrides = try XCTUnwrap(dict["FrontedMeekDialOverrides"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(overrides.count, 11)
        XCTAssertEqual(dict["FrontedMeekDialOverridesProbability"] as? Double, 1.0)
        XCTAssertEqual(dict["FrontedMeekCDNScanUseBuiltInSpec"] as? Bool, true)
        XCTAssertEqual(dict["DisableTactics"] as? Bool, true)
        XCTAssertEqual(
            dict["LimitTunnelProtocols"] as? [String],
            [
                "FRONTED-MEEK-OSSH",
                "FRONTED-MEEK-HTTP-OSSH",
                "FRONTED-MEEK-QUIC-OSSH"
            ]
        )
    }

    func testDirectLimitProtocolsMatchAndroidWithoutCDNFamily() throws {
        var settings = AppSettings()
        settings.protocolSelection = .direct
        let json = try PsiphonConfigComposer.compose(baseJSON: baseConfigJSON(), settings: settings)
        let dict = try decode(json)
        let limits = try XCTUnwrap(dict["LimitTunnelProtocols"] as? [String])
        XCTAssertEqual(limits, PsiphonProtocolSets.direct)
        XCTAssertFalse(limits.contains { $0.contains("CDN") })
    }

    func testAdditionalParametersSurviveCompose() throws {
        let base = """
        {"PropagationChannelId":"07D1ACD69B3AC7A2","SponsorId":"EE0B7486ACAE75AA","AdditionalParameters":"{\\"DeviceLocationPrecision\\":4}"}
        """
        let json = try PsiphonConfigComposer.compose(baseJSON: base, settings: AppSettings())
        let dict = try decode(json)
        XCTAssertEqual(dict["AdditionalParameters"] as? String, "{\"DeviceLocationPrecision\":4}")
    }

    private func baseConfigJSON() -> String {
        """
        {"PropagationChannelId":"07D1ACD69B3AC7A2","SponsorId":"EE0B7486ACAE75AA"}
        """
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class PsiphonEgressRegionStoreTests: XCTestCase {
    override func tearDown() {
        UserDefaults(suiteName: AppGroupConstants.suiteName)?
            .removeObject(forKey: AppGroupConstants.psiphonKnownEgressRegionsKey)
        SharedSettingsStore.shared.egressRegionUnavailable = false
        var settings = SharedSettingsStore.shared.appSettings
        settings.egressRegion = ""
        SharedSettingsStore.shared.appSettings = settings
        super.tearDown()
    }

    func testKnownRegionsPreferPsiphonReportedList() {
        PsiphonEgressRegionStore.updateAvailableRegions(["DE", "FR"])
        let regions = PsiphonEgressRegionStore.knownRegions()
        XCTAssertEqual(regions, ["DE", "FR"])
        XCTAssertFalse(regions.contains("US"))
        XCTAssertFalse(regions.contains("CH"))
    }

    func testUnavailableSelectedRegionResetsToAuto() {
        var settings = SharedSettingsStore.shared.appSettings
        settings.egressRegion = "DE"
        SharedSettingsStore.shared.appSettings = settings

        _ = PsiphonEgressRegionStore.updateAvailableRegions(["US", "FR"])

        XCTAssertEqual(SharedSettingsStore.shared.appSettings.egressRegion, "")
        XCTAssertTrue(SharedSettingsStore.shared.egressRegionUnavailable)
    }

    func testUnavailableRegionAlsoClearsRecoveryOverlay() {
        var durable = SharedSettingsStore.shared.appSettings
        durable.egressRegion = "CH"
        SharedSettingsStore.shared.appSettings = durable

        var trial = durable
        trial.protocolSelection = .cdnFronting
        trial.egressRegion = "CH"
        SharedSettingsStore.shared.applyRecoveryTrialSettings(trial)

        _ = PsiphonEgressRegionStore.updateAvailableRegions(["DE", "FR", "GB", "JP", "US"])

        XCTAssertEqual(SharedSettingsStore.shared.appSettings.egressRegion, "")
        XCTAssertEqual(SharedSettingsStore.shared.recoveryTrialSettings?.egressRegion, "")
        SharedSettingsStore.shared.clearRecoveryTrialSettings()
    }
}

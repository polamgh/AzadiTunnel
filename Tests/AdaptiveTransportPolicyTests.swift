import XCTest
@testable import AdaptiveTransportPolicy

final class AdaptiveTransportPolicyTests: XCTestCase {
    func testAutoStartsAggressiveThenCDNThenDirect() {
        let candidates = AdaptiveTransportPolicy.candidates(for: .auto)

        XCTAssertEqual(
            candidates.map(\.transport),
            [.autoBeast, .cdn, .direct]
        )
        XCTAssertEqual(candidates.first?.selection, .auto)
        XCTAssertEqual(candidates.first?.beast, true)
        XCTAssertEqual(candidates.first?.tacticsEnabled, true)
        XCTAssertEqual(candidates.first?.usesStaticCDNOverrides, false)
    }

    func testProtocolSelectionRawValuesPreserveExplicitCDNMode() {
        XCTAssertEqual(AdaptiveTransportPolicy.selection(for: "cdnFronting"), .cdnFronting)
        XCTAssertEqual(AdaptiveTransportPolicy.selection(for: "cdn_fronting"), .cdnFronting)

        let explicitCDN = AdaptiveTransportPolicy.candidates(for: .cdnFronting)
        XCTAssertEqual(explicitCDN.first?.selection.rawValue, "cdnFronting")
    }

    func testTacticsStayEnabledForEveryAdaptiveCandidate() {
        for selection in [
            AdaptiveTransportPolicy.Selection.auto,
            .cdnFronting,
            .direct,
            .conduit
        ] {
            XCTAssertTrue(AdaptiveTransportPolicy.keepsTacticsEnabled(for: selection))
        }

        let candidates = AdaptiveTransportPolicy.candidates(for: .auto, includePublicConduit: true)
        XCTAssertTrue(candidates.allSatisfy(\.tacticsEnabled))
    }

    func testStaticCDNOverridesAreScopedToExplicitCDN() {
        XCTAssertTrue(AdaptiveTransportPolicy.includesCdnFrontingHints(for: .auto))
        XCTAssertTrue(AdaptiveTransportPolicy.includesCdnFrontingHints(for: .direct))
        XCTAssertTrue(AdaptiveTransportPolicy.includesCdnFrontingHints(for: .cdnFronting))
        XCTAssertFalse(AdaptiveTransportPolicy.includesCdnFrontingHints(for: .conduit))

        XCTAssertFalse(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: .auto))
        XCTAssertFalse(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: .direct))
        XCTAssertTrue(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: .cdnFronting))
        XCTAssertFalse(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: "auto"))
        XCTAssertFalse(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: "direct"))
        XCTAssertTrue(AdaptiveTransportPolicy.usesStaticCDNOverrides(for: "cdnFronting"))

        let candidates = AdaptiveTransportPolicy.candidates(for: .auto, includePublicConduit: true)
        XCTAssertEqual(candidates.filter(\.usesStaticCDNOverrides).map(\.selection), [.cdnFronting])
    }

    func testPublicConduitIsOptionalAndAlwaysLast() {
        let withoutConduit = AdaptiveTransportPolicy.candidates(for: .auto)
        XCTAssertFalse(withoutConduit.contains { $0.transport == .conduitPublic })

        let withConduit = AdaptiveTransportPolicy.candidates(for: .auto, includePublicConduit: true)
        XCTAssertEqual(withConduit.last?.transport, .conduitPublic)
        XCTAssertEqual(withConduit.last?.selection, .conduit)

        XCTAssertEqual(
            AdaptiveTransportPolicy.candidates(for: .direct, includePublicConduit: true).map(\.transport),
            [.direct]
        )
        XCTAssertTrue(AdaptiveTransportPolicy.candidates(for: .conduit).isEmpty)
    }

    func testBestServerCacheExpires() {
        let savedAt = Date(timeIntervalSince1970: 1_000)
        let profile = NetworkProfile(interfaceClass: .wifi, supportsIPv6: false)
        let snapshot = NetworkPathSnapshot(profile: profile, generation: 1)
        let selection = BestServerSelection(
            transport: FallbackStep.autoBeast.rawValue,
            selectedAt: savedAt
        )
        let scoped = BestServerCachePolicy.scoped(selection, for: snapshot, now: savedAt)

        XCTAssertTrue(BestServerCachePolicy.isReusable(scoped, for: snapshot, now: savedAt))
        XCTAssertTrue(
            BestServerCachePolicy.isReusable(
                scoped,
                for: snapshot,
                now: savedAt.addingTimeInterval(BestServerCachePolicy.maxAge - 1)
            )
        )
        XCTAssertFalse(
            BestServerCachePolicy.isReusable(
                scoped,
                for: snapshot,
                now: savedAt.addingTimeInterval(BestServerCachePolicy.maxAge)
            )
        )
    }

    func testBestServerCacheMissesOnPathGenerationProfileChangeAndLegacyRecord() {
        let savedAt = Date(timeIntervalSince1970: 2_000)
        let wifi = NetworkProfile(interfaceClass: .wifi, supportsIPv6: true)
        let cellular = NetworkProfile(interfaceClass: .cellular, isExpensive: true, supportsIPv6: true)
        let wifiSnapshot = NetworkPathSnapshot(profile: wifi, generation: 7)
        let changedInterfaceSnapshot = NetworkPathSnapshot(profile: cellular, generation: 7)
        let changedPathSnapshot = NetworkPathSnapshot(profile: wifi, generation: 8)
        let selection = BestServerSelection(
            transport: FallbackStep.cdn.rawValue,
            selectedAt: savedAt
        )
        let scoped = BestServerCachePolicy.scoped(selection, for: wifiSnapshot, now: savedAt)

        XCTAssertTrue(BestServerCachePolicy.isReusable(scoped, for: wifiSnapshot, now: savedAt))
        XCTAssertFalse(BestServerCachePolicy.isReusable(scoped, for: changedInterfaceSnapshot, now: savedAt))
        XCTAssertFalse(BestServerCachePolicy.isReusable(scoped, for: changedPathSnapshot, now: savedAt))

        let legacy = BestServerSelection(transport: FallbackStep.direct.rawValue, selectedAt: savedAt)
        XCTAssertFalse(BestServerCachePolicy.isReusable(legacy, for: wifiSnapshot, now: savedAt))
        XCTAssertFalse(BestServerCachePolicy.isReusable(scoped, for: wifi, now: savedAt))
    }

    func testBestServerStoreIsSessionScopedToCurrentPathSnapshot() {
        ConnectionDiagnosticsStore.clearBestServer()
        defer { ConnectionDiagnosticsStore.clearBestServer() }

        let savedAt = Date(timeIntervalSince1970: 3_000)
        let snapshot = NetworkPathSnapshot(
            profile: NetworkProfile(interfaceClass: .wifi),
            generation: 11
        )
        let changedPath = NetworkPathSnapshot(
            profile: snapshot.profile,
            generation: 12
        )
        let selection = BestServerSelection(
            transport: FallbackStep.direct.rawValue,
            selectedAt: savedAt
        )

        ConnectionDiagnosticsStore.saveBestServer(selection, for: snapshot, now: savedAt)
        XCTAssertNotNil(ConnectionDiagnosticsStore.loadBestServer(for: snapshot, now: savedAt))
        XCTAssertNil(ConnectionDiagnosticsStore.loadBestServer(for: changedPath, now: savedAt))
        XCTAssertNil(ConnectionDiagnosticsStore.loadBestServer())
    }
}

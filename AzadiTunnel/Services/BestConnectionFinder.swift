import Foundation
import Combine

/// "Find Best Connection" orchestrator.
///
/// Drives the EXISTING `VPNController.connect(skipFallbackChain:)` across a list of
/// protocol × country candidates, measures real usable speed for each, and saves the first option
/// that reaches the minimum threshold. It does not modify the connection system: it only sets the
/// same `protocolSelection` / `egressRegion` the user could set manually, connects through the
/// normal path, and restores the user's original manual settings when the scan ends.
///
/// Safe + reversible:
/// - The saved "best" is stored separately (`SharedSettingsStore.bestConnection`); the user's manual
///   protocol/region are snapshotted before the scan and restored after.
/// - Everything is cancellable. Nothing here touches routing, protocols, or tunnel internals.
@MainActor
final class BestConnectionFinder: ObservableObject {
    static let shared = BestConnectionFinder()

    /// Minimum usable download speed (Mbps) for a candidate to be accepted.
    static let minimumMbps: Double = 5.0

    @Published private(set) var isRunning = false
    /// e.g. "Testing CDN fronting - Germany"
    @Published private(set) var progressLine = ""
    /// e.g. "Speed: 3.2 Mbps" or the final summary.
    @Published private(set) var detailLine = ""
    /// Lets the UI refresh the saved-best button without polling the store.
    @Published private(set) var savedRevision = 0

    private var task: Task<Void, Never>?
    private let vpn = VPNController.shared

    /// Per-candidate connect timeout (s). CDN fronting needs the most; failures move on quickly.
    private let connectTimeout: Double = 30
    private let disconnectTimeout: Double = 8

    private init() {}

    var savedBest: BestConnectionRecord? { SharedSettingsStore.shared.bestConnection }

    // MARK: - Public control

    func start() {
        guard !isRunning else { return }
        guard SharedSettingsStore.shared.hasActivePsiphonConfig else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    func clearSaved() {
        SharedSettingsStore.shared.clearBestConnection()
        SharedLogger.shared.log(.bestConnCleared)
        savedRevision &+= 1
    }

    /// Reconnect directly to the previously saved best (sets its protocol/region, then connects).
    func connectToSavedBest() async {
        guard let best = SharedSettingsStore.shared.bestConnection else { return }
        applyCandidate(protocolSelection: best.protocolSelection, region: best.region, logKey: "best_connection_apply")
        SharedLogger.shared.log(
            .bestConnConnectSaved,
            detail: "proto=\(best.protocolSelection.rawValue) region=\(regionLog(best.region)) saved_mbps=\(String(format: "%.1f", best.mbps))"
        )
        if vpn.status != .disconnected {
            await vpn.disconnect()
            await waitForDisconnect()
        }
        await vpn.connect(skipFallbackChain: true)
    }

    // MARK: - Scan

    private func run() async {
        isRunning = true
        progressLine = ""
        detailLine = ""
        SharedLogger.shared.log(.bestConnScanStarted, detail: "min_mbps=\(Int(Self.minimumMbps))")

        // Snapshot the user's manual selection so we can restore it afterwards.
        let original = SharedSettingsStore.shared.appSettings
        let originalProtocol = original.protocolSelection
        let originalRegion = original.egressRegion

        var found = false
        defer {
            // Always restore the user's manual protocol/region. If we ended connected to the best,
            // the live tunnel keeps running; only the stored manual selection is reverted.
            applyCandidate(protocolSelection: originalProtocol, region: originalRegion, logKey: "best_connection_restore")
            isRunning = false
            savedRevision &+= 1
        }

        candidateLoop: for candidate in candidates() {
            if Task.isCancelled {
                SharedLogger.shared.log(.bestConnScanCancelled)
                await stopProbe()
                break
            }

            let protoName = SettingsLabels.protocolName(candidate.protocolSelection)
            let countryName = candidate.region.isEmpty ? L10n.t(.regionAny) : RegionDisplayNames.pickerLabel(for: candidate.region)
            progressLine = "\(L10n.t(.findBestTestingPrefix)) \(protoName) - \(countryName)"
            detailLine = ""
            SharedLogger.shared.log(
                .bestConnTesting,
                detail: "\(candidate.protocolSelection.rawValue) - \(regionLog(candidate.region))"
            )

            // Clean slate, then apply this candidate and connect through the normal path.
            if vpn.status != .disconnected {
                await vpn.disconnect()
                await waitForDisconnect()
            }
            applyCandidate(protocolSelection: candidate.protocolSelection, region: candidate.region, logKey: "best_connection_probe")

            let connected = await connectAndWait()
            if Task.isCancelled { await stopProbe(); SharedLogger.shared.log(.bestConnScanCancelled); break }

            if !connected {
                detailLine = L10n.t(.findBestFailed)
                SharedLogger.shared.log(
                    .bestConnConnectFailed,
                    detail: "\(candidate.protocolSelection.rawValue) - \(regionLog(candidate.region))"
                )
                await stopProbe()
                continue
            }

            // Connected — measure real usable speed.
            let mbps = await TunnelSpeedTester.measureMbps()
            let mbpsText = String(format: "%.1f", mbps)
            detailLine = "\(L10n.t(.findBestSpeed)) \(mbpsText) Mbps"
            SharedLogger.shared.log(
                .bestConnSpeed,
                detail: "\(mbpsText) Mbps proto=\(candidate.protocolSelection.rawValue) region=\(regionLog(candidate.region))"
            )

            if mbps >= Self.minimumMbps {
                SharedSettingsStore.shared.saveBestConnection(
                    protocolSelection: candidate.protocolSelection,
                    region: candidate.region,
                    mbps: mbps
                )
                SharedLogger.shared.log(
                    .bestConnSaved,
                    detail: "proto=\(candidate.protocolSelection.rawValue) region=\(regionLog(candidate.region)) mbps=\(mbpsText)"
                )
                progressLine = "\(protoName) - \(countryName)"
                detailLine = "\(L10n.t(.findBestSavedPrefix)) \(mbpsText) Mbps"
                found = true
                // Leave the device connected to this working best.
                break candidateLoop
            } else {
                SharedLogger.shared.log(
                    .bestConnBelowThreshold,
                    detail: "\(mbpsText) Mbps < \(Int(Self.minimumMbps)) proto=\(candidate.protocolSelection.rawValue) region=\(regionLog(candidate.region))"
                )
                await stopProbe()
            }
        }

        if !found {
            progressLine = ""
            detailLine = L10n.t(.findBestNoneFound)
            SharedLogger.shared.log(.bestConnScanNone)
            // No winner — make sure we are not left half-connected to the last failed candidate.
            if vpn.status != .disconnected { await stopProbe() }
        }
        SharedLogger.shared.log(.bestConnScanFinished, detail: "found=\(found)")
    }

    // MARK: - Candidates

    private struct Candidate {
        let protocolSelection: AppSettings.ProtocolSelection
        let region: String
    }

    /// Curated, bounded matrix: a few reliable protocols × a few fast egress countries. Kept small
    /// so the scan finishes in reasonable time; it stops at the first option that passes anyway.
    private func candidates() -> [Candidate] {
        var protocols: [AppSettings.ProtocolSelection] = [.cdnFronting, .direct, .auto]
        if SharedSettingsStore.shared.conduitConnectAllowed {
            protocols.append(.conduit)
        }
        let preferredCountries = ["DE", "NL", "GB", "FR", "SE", "US"]
        let countries = preferredCountries.filter { PsiphonRegionList.all.contains($0) }

        var list: [Candidate] = []
        for proto in protocols {
            for country in countries {
                list.append(Candidate(protocolSelection: proto, region: country))
            }
        }
        return list
    }

    // MARK: - Helpers (all go through existing VPNController / settings APIs)

    private func applyCandidate(protocolSelection: AppSettings.ProtocolSelection, region: String, logKey: String) {
        var settings = SharedSettingsStore.shared.appSettings
        settings.protocolSelection = protocolSelection
        settings.egressRegion = region
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: logKey)
    }

    private func connectAndWait() async -> Bool {
        SharedSettingsStore.shared.lastInternetTestOK = false
        await vpn.connect(skipFallbackChain: true)
        let deadline = Date().addingTimeInterval(connectTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            vpn.syncStatusFromSharedStore()
            if vpn.status == .connected && SharedSettingsStore.shared.lastInternetTestOK {
                return true
            }
            if vpn.status == .error { return false }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }

    private func stopProbe() async {
        await vpn.disconnect()
        await waitForDisconnect()
    }

    private func waitForDisconnect() async {
        let deadline = Date().addingTimeInterval(disconnectTimeout)
        while Date() < deadline {
            vpn.syncStatusFromSharedStore()
            if vpn.status == .disconnected { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func regionLog(_ region: String) -> String {
        region.isEmpty ? "any" : region
    }
}

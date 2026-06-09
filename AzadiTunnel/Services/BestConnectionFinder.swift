import Foundation
import Combine
import NetworkExtension

/// "Find Best Connection" orchestrator.
///
/// Drives the EXISTING `VPNController.connect(skipFallbackChain:)` across an ordered list of
/// protocol × country candidates, measures real usable speed for each, and collects EVERY option
/// that reaches the user-selected minimum. The fastest is kept as the saved "best".
///
/// Order: all Direct (every country) first, then CDN fronting, then Conduit (if available).
///
/// It does not modify the connection system: it only sets the same `protocolSelection` /
/// `egressRegion` the user could set manually, connects through the normal path, and restores the
/// user's original manual settings when the scan ends.
///
/// Safe + reversible:
/// - Results + saved best are stored separately (`SharedSettingsStore`); the user's manual
///   protocol/region are snapshotted before the scan and restored after.
/// - The scan runs through every candidate (it does NOT stop at the first match) and is fully
///   cancellable — cancelling keeps whatever was found so far. Nothing here touches routing,
///   protocols, or tunnel internals.
@MainActor
final class BestConnectionFinder: ObservableObject {
    static let shared = BestConnectionFinder()

    static let defaultMinMbps = 5

    @Published private(set) var isRunning = false
    /// e.g. "Testing Direct - Germany"
    @Published private(set) var progressLine = ""
    /// e.g. "Speed: 3.2 Mbps" or the final summary.
    @Published private(set) var detailLine = ""
    /// Working connections found so far, sorted fastest-first. Mirrors the persisted list.
    @Published private(set) var results: [FoundConnection] = []
    /// Lets the UI refresh derived state (saved best button) without polling the store.
    @Published private(set) var savedRevision = 0
    /// True while the scan is paused waiting for the user's "keep searching / stop here" decision
    /// after the milestone count was reached. The UI shows an alert and calls `resolveContinuePrompt`.
    @Published private(set) var awaitingContinuePrompt = false

    /// Ask the user whether to keep going once this many working connections are found.
    static let promptAfterFound = 5

    private var task: Task<Void, Never>?
    private let vpn = VPNController.shared
    private var continueResume: CheckedContinuation<Bool, Never>?
    private var askedMilestone = false

    /// Per-candidate connect timeout (s). CDN fronting needs the most; failures move on quickly.
    private let connectTimeout: Double = 28
    /// How long to wait for the previous tunnel to FULLY tear down before the next probe.
    private let disconnectTimeout: Double = 15
    /// Extra settle time after the NE connection reports `.disconnected`, so iOS releases the
    /// session before we start the next tunnel (prevents the every-other-candidate race).
    private let postDisconnectSettle: UInt64 = 900_000_000

    private init() {
        results = SharedSettingsStore.shared.bestConnectionResults
    }

    var savedBest: BestConnectionRecord? { SharedSettingsStore.shared.bestConnection }

    var minMbps: Int {
        get { SharedSettingsStore.shared.bestConnectionMinMbps }
        set {
            SharedSettingsStore.shared.bestConnectionMinMbps = newValue
            savedRevision &+= 1
        }
    }

    // MARK: - Public control

    func start() {
        guard !isRunning else { return }
        guard SharedSettingsStore.shared.hasActivePsiphonConfig else { return }
        task = Task { await run() }
    }

    func cancel() {
        // If we're paused on the milestone prompt, release it (as "stop") so run() can unwind.
        if continueResume != nil { resolveContinuePrompt(keepGoing: false) }
        task?.cancel()
    }

    /// Called by the UI from the "5 found — keep searching / stop here?" alert.
    func resolveContinuePrompt(keepGoing: Bool) {
        guard let cont = continueResume else { return }
        continueResume = nil
        awaitingContinuePrompt = false
        cont.resume(returning: keepGoing)
    }

    /// After the milestone count is first reached, pause and ask the user whether to keep scanning.
    /// Returns `true` when the caller should STOP.
    private func reachedMilestoneAndShouldStop() async -> Bool {
        guard !askedMilestone, results.count >= Self.promptAfterFound else { return false }
        askedMilestone = true
        if Task.isCancelled { return true }
        SharedLogger.shared.log(.bestConnMilestonePrompt, detail: "found=\(results.count)")
        let keepGoing = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continueResume = cont
            awaitingContinuePrompt = true
        }
        awaitingContinuePrompt = false
        SharedLogger.shared.log(keepGoing ? .bestConnMilestoneContinue : .bestConnMilestoneStop, detail: "found=\(results.count)")
        return !keepGoing
    }

    func clearSaved() {
        SharedSettingsStore.shared.clearBestConnection()
        results = []
        SharedLogger.shared.log(.bestConnCleared)
        savedRevision &+= 1
    }

    /// Reconnect directly to the fastest found combination (with all its options).
    func connectToSavedBest() async {
        guard let best = results.first else { return }
        await connect(to: best)
    }

    /// Connect to one of the listed found connections, applying ALL of its options.
    func connect(to result: FoundConnection) async {
        guard !isRunning, let candidate = candidate(from: result) else { return }
        applyCandidate(candidate, logKey: "best_connection_apply")
        SharedLogger.shared.log(.bestConnConnectSaved, detail: candidateLog(candidate) + " saved_mbps=\(String(format: "%.1f", result.mbps))")
        await ensureFullyDisconnected()
        await vpn.connect(skipFallbackChain: true)
    }

    private func candidate(from r: FoundConnection) -> Candidate? {
        guard let proto = r.protocolSelection else { return nil }
        return Candidate(
            protocolSelection: proto,
            region: r.region,
            beastMode: r.beastMode,
            dnsMode: r.dnsMode,
            dnsProvider: r.dnsProvider
        )
    }

    // MARK: - Scan

    private func run() async {
        isRunning = true
        progressLine = ""
        detailLine = ""
        let threshold = Double(SharedSettingsStore.shared.bestConnectionMinMbps)

        // Fresh scan: clear previous results + best.
        SharedSettingsStore.shared.clearBestConnection()
        results = []
        askedMilestone = false
        savedRevision &+= 1
        SharedLogger.shared.log(.bestConnScanStarted, detail: "min_mbps=\(Int(threshold))")

        // Snapshot the user's FULL settings (protocol, region, beast, secure DNS) and restore them
        // verbatim afterwards — the scan toggles all of these and must leave nothing changed.
        let original = SharedSettingsStore.shared.appSettings

        var cancelled = false
        defer {
            SharedSettingsStore.shared.updateAppSettings(original, logKey: "best_connection_restore")
            isRunning = false
            savedRevision &+= 1
        }

        // Phase 1 — sweep EVERY country (auto-selected) × protocol × Beast on/off, with DNS off, to
        // find the fastest country+protocol combination.
        SharedLogger.shared.logRaw("BEST_CONNECTION_PHASE", detail: "phase=1 dimension=country_protocol_beast")
        for candidate in phase1Candidates() {
            if await probe(candidate, threshold: threshold) { cancelled = true; break }
            if await reachedMilestoneAndShouldStop() { cancelled = true; break }
        }

        // Phase 2 — on the fastest result so far, sweep Secure DNS (DoH/DoT × Cloudflare/Google).
        if !cancelled, let best = results.first, let base = candidate(from: best) {
            SharedLogger.shared.logRaw("BEST_CONNECTION_PHASE", detail: "phase=2 base=\(candidateLog(base)) dimension=secure_dns")
            for candidate in phase2Candidates(base: base) {
                if await probe(candidate, threshold: threshold) { cancelled = true; break }
                if await reachedMilestoneAndShouldStop() { cancelled = true; break }
            }
        }

        // Leave the device disconnected so the user picks from the list.
        if vpn.status != .disconnected { await stopProbe() }

        if cancelled {
            SharedLogger.shared.log(.bestConnScanCancelled, detail: "found=\(results.count)")
        }
        progressLine = ""
        if results.isEmpty {
            detailLine = L10n.t(.findBestNoneFound)
            SharedLogger.shared.log(.bestConnScanNone)
        } else {
            detailLine = "\(L10n.t(.findBestFoundCountPrefix)) \(results.count)"
        }
        SharedLogger.shared.log(.bestConnScanFinished, detail: "found=\(results.count) cancelled=\(cancelled)")
    }

    /// Test one candidate end-to-end (disconnect → apply → connect → measure → record).
    /// Returns `true` if the scan was cancelled and the caller should stop.
    private func probe(_ candidate: Candidate, threshold: Double) async -> Bool {
        if Task.isCancelled { return true }

        progressLine = "\(L10n.t(.findBestTestingPrefix)) \(candidateDisplay(candidate))"
        detailLine = ""
        SharedLogger.shared.log(.bestConnTesting, detail: candidateLog(candidate))

        // Clean slate: FULLY tear down the previous tunnel before the next probe. Without this the
        // optimistic-disconnect display status reads `.disconnected` while iOS is still
        // `.disconnecting`, so the next connect is swallowed — making every other candidate fail.
        await ensureFullyDisconnected()
        if Task.isCancelled { return true }
        applyCandidate(candidate, logKey: "best_connection_probe")

        let connected = await connectAndWait()
        if Task.isCancelled { return true }

        if !connected {
            detailLine = L10n.t(.findBestFailed)
            SharedLogger.shared.log(.bestConnConnectFailed, detail: candidateLog(candidate))
            return false
        }

        let mbps = await TunnelSpeedTester.measureMbps()
        if Task.isCancelled { return true }
        let mbpsText = String(format: "%.1f", mbps)
        detailLine = "\(L10n.t(.findBestSpeed)) \(mbpsText) Mbps"
        SharedLogger.shared.log(.bestConnSpeed, detail: "\(mbpsText) Mbps " + candidateLog(candidate))

        if mbps >= threshold {
            record(candidate.asFoundConnection(mbps: mbps))
            SharedLogger.shared.log(.bestConnSaved, detail: candidateLog(candidate) + " mbps=\(mbpsText)")
        } else {
            SharedLogger.shared.log(.bestConnBelowThreshold, detail: "\(mbpsText) Mbps < \(Int(threshold)) " + candidateLog(candidate))
        }
        return false
    }

    /// Add a passing result, keep the list sorted fastest-first, persist, and update the saved best.
    private func record(_ entry: FoundConnection) {
        var list = results.filter { $0.id != entry.id }
        list.append(entry)
        list.sort { $0.mbps > $1.mbps }
        results = list
        SharedSettingsStore.shared.bestConnectionResults = list
        if let best = list.first, let proto = best.protocolSelection {
            SharedSettingsStore.shared.saveBestConnection(protocolSelection: proto, region: best.region, mbps: best.mbps)
        }
        savedRevision &+= 1
    }

    // MARK: - Candidates

    /// A full combination of every server option the scan varies.
    private struct Candidate {
        let protocolSelection: AppSettings.ProtocolSelection
        let region: String
        let beastMode: Bool
        let dnsMode: SecureDNSMode
        let dnsProvider: SecureDNSProvider

        func asFoundConnection(mbps: Double) -> FoundConnection {
            FoundConnection(
                protocolSelection: protocolSelection,
                region: region,
                beastMode: beastMode,
                dnsMode: dnsMode,
                dnsProvider: dnsProvider,
                mbps: mbps
            )
        }
    }

    private var scanProtocols: [AppSettings.ProtocolSelection] {
        var protocols: [AppSettings.ProtocolSelection] = [.direct, .cdnFronting]
        if SharedSettingsStore.shared.conduitConnectAllowed {
            protocols.append(.conduit)
        }
        return protocols
    }

    /// Countries the scan picks automatically: "Any" first (Psiphon auto-selects the fastest egress),
    /// then every region except Iran.
    private var scanCountries: [String] {
        [""] + PsiphonRegionList.all.filter { $0 != "IR" }
    }

    /// Phase 1: EVERY country (auto) × protocol (Direct → CDN → Conduit) × Beast (off/on), DNS off.
    /// Finds the fastest country+protocol combination without the DNS dimension.
    private func phase1Candidates() -> [Candidate] {
        var list: [Candidate] = []
        for proto in scanProtocols {
            for country in scanCountries {
                for beast in [true, false] {
                    list.append(Candidate(
                        protocolSelection: proto,
                        region: country,
                        beastMode: beast,
                        dnsMode: .off,
                        dnsProvider: .cloudflare
                    ))
                }
            }
        }
        return list
    }

    /// Phase 2: keep the winning protocol+country+beast and sweep Secure DNS (DoH/DoT × CF/Google).
    private func phase2Candidates(base: Candidate) -> [Candidate] {
        let dnsVariants: [(SecureDNSMode, SecureDNSProvider)] = [
            (.doh, .cloudflare),
            (.doh, .google),
            (.dot, .cloudflare),
            (.dot, .google),
        ]
        return dnsVariants.map { mode, provider in
            Candidate(
                protocolSelection: base.protocolSelection,
                region: base.region,
                beastMode: base.beastMode,
                dnsMode: mode,
                dnsProvider: provider
            )
        }
    }

    // MARK: - Helpers (all go through existing VPNController / settings APIs)

    private func applyCandidate(_ candidate: Candidate, logKey: String) {
        var settings = SharedSettingsStore.shared.appSettings
        settings.protocolSelection = candidate.protocolSelection
        settings.egressRegion = candidate.region
        settings.beastModeEnabled = candidate.beastMode
        settings.secureDNSMode = candidate.dnsMode
        settings.secureDNSProvider = candidate.dnsProvider
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: logKey)
    }

    /// Human-readable combo for the progress line, e.g. "Direct - Germany · Beast on · DoH Cloudflare".
    private func candidateDisplay(_ c: Candidate) -> String {
        let proto = SettingsLabels.protocolName(c.protocolSelection)
        let country = c.region.isEmpty ? L10n.t(.regionAny) : RegionDisplayNames.pickerLabel(for: c.region)
        return "\(proto) - \(country) · \(beastLabel(c.beastMode)) · \(dnsLabel(c.dnsMode, c.dnsProvider))"
    }

    /// Compact combo for logs.
    private func candidateLog(_ c: Candidate) -> String {
        "proto=\(c.protocolSelection.rawValue) region=\(regionLog(c.region)) beast=\(c.beastMode ? "on" : "off") dns=\(dnsLogValue(c.dnsMode, c.dnsProvider))"
    }

    private func beastLabel(_ on: Bool) -> String {
        "\(L10n.t(.settingsBeastMode)) \(on ? L10n.t(.findBestOn) : L10n.t(.findBestOff))"
    }

    private func dnsLabel(_ mode: SecureDNSMode, _ provider: SecureDNSProvider) -> String {
        switch mode {
        case .off: return "DNS \(L10n.t(.findBestOff))"
        case .doh: return "DoH \(providerName(provider))"
        case .dot: return "DoT \(providerName(provider))"
        }
    }

    private func providerName(_ provider: SecureDNSProvider) -> String {
        switch provider {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .adguard: return "AdGuard"
        case .custom: return "Custom"
        }
    }

    private func dnsLogValue(_ mode: SecureDNSMode, _ provider: SecureDNSProvider) -> String {
        mode == .off ? "off" : "\(mode.rawValue):\(provider.rawValue)"
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
        await ensureFullyDisconnected()
    }

    /// Disconnect if needed, then block until the REAL NE connection status is `.disconnected`
    /// (plus a short settle), so the next `connect()` starts from a clean tunnel state.
    private func ensureFullyDisconnected() async {
        let raw = vpn.rawTunnelStatus
        if raw != .disconnected && raw != .invalid {
            await vpn.disconnect()
        }
        let deadline = Date().addingTimeInterval(disconnectTimeout)
        while Date() < deadline {
            // Read the raw NE status — NOT vpn.status, which flips to .disconnected optimistically.
            let s = vpn.rawTunnelStatus
            if s == .disconnected || s == .invalid {
                try? await Task.sleep(nanoseconds: postDisconnectSettle)
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func regionLog(_ region: String) -> String {
        region.isEmpty ? "any" : region
    }
}

import Foundation

/// Runtime check that vendored PsiphonTunnel was built with in-proxy (no secrets).
enum PsiphonInproxyBuildInfo {
    private static let probeStrings = [
        "INPROXY-WEBRTC",
        "inproxy-broker",
        "InproxyBrokerClientManager",
        "no broker specs"
    ]

    static func logFrameworkProbe() {
        guard let path = PsiphonTunnelBinary.path else {
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_BUILD", detail: "enabled=unknown")
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_BUILD_TAGS", detail: "framework_path_missing")
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_SYMBOLS_FOUND", detail: "false")
            return
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
              !data.isEmpty else {
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_BUILD", detail: "enabled=unknown")
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_BUILD_TAGS", detail: "read_failed")
            SharedLogger.shared.logRaw("PSIPHON_INPROXY_SYMBOLS_FOUND", detail: "false")
            return
        }

        let found = probeStrings.filter { data.range(of: Data($0.utf8), options: [], in: 0..<data.count) != nil }
        let symbolsOK = found.count >= 3
        SharedLogger.shared.logRaw("PSIPHON_INPROXY_BUILD", detail: "enabled=\(symbolsOK)")
        SharedLogger.shared.logRaw(
            "PSIPHON_INPROXY_BUILD_TAGS",
            detail: "fork=shirokhorshid/psiphon-tunnel-core constraint=!PSIPHON_DISABLE_INPROXY default_on"
        )
        SharedLogger.shared.logRaw(
            "PSIPHON_INPROXY_SYMBOLS_FOUND",
            detail: symbolsOK ? "true" : "false"
        )
        SharedLogger.shared.logRaw(
            "PSIPHON_INPROXY_PROBE",
            detail: "hits=\(found.count)/\(probeStrings.count) keys=\(found.joined(separator: ","))"
        )
    }
}

private enum PsiphonTunnelBinary {
    static var path: String? {
        for bundle in Bundle.allFrameworks + [Bundle.main] {
            guard bundle.bundleURL.lastPathComponent == "PsiphonTunnel.framework",
                  let exec = bundle.executableURL?.path,
                  FileManager.default.isReadableFile(atPath: exec) else { continue }
            return exec
        }
        let hostRelative = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent
            .appending("/Frameworks/PsiphonTunnel.framework/PsiphonTunnel")
        return FileManager.default.isReadableFile(atPath: hostRelative) ? hostRelative : nil
    }
}

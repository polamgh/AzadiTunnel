import Foundation

/// Merges user settings into Psiphon JSON without logging field values.
enum PsiphonConfigComposer {
    static func compose(baseJSON: String, settings: AppSettings) throws -> String {
        guard let data = baseJSON.data(using: .utf8),
              var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PsiphonConfigValidationError.invalidJSON
        }

        if !settings.egressRegion.isEmpty {
            dict["EgressRegion"] = settings.egressRegion
        } else {
            dict.removeValue(forKey: "EgressRegion")
        }

        if settings.upstreamProxyEnabled, !settings.upstreamProxyHost.isEmpty {
            let port = max(1, min(65535, settings.upstreamProxyPort))
            var url = "http://\(settings.upstreamProxyHost):\(port)"
            if !settings.upstreamProxyUsername.isEmpty {
                let user = settings.upstreamProxyUsername.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
                let pass = settings.upstreamProxyPassword.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
                url = "http://\(user):\(pass)@\(settings.upstreamProxyHost):\(port)"
            }
            dict["UpstreamProxyURL"] = url
        } else {
            dict.removeValue(forKey: "UpstreamProxyURL")
        }

        dict["DisableTimeouts"] = settings.disableTimeouts
        dict["EmitBytesTransferred"] = true

        PsiphonShiroTunnelConfig.apply(to: &dict, settings: settings)
        PsiphonShiroCDNFrontingConfig.apply(to: &dict, settings: settings)

        // Beast + Auto: try all protocols/servers (Android default). Beast + fixed mode: keep protocol limit.
        if let limitProtocols = PsiphonProtocolSets.expectedLimitJSON(for: settings) {
            dict["LimitTunnelProtocols"] = limitProtocols
        } else {
            dict.removeValue(forKey: "LimitTunnelProtocols")
        }

        PsiphonConduitConfig.apply(to: &dict, settings: settings)

        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        return text
    }

    /// Parses effective protocol limit from composed JSON for logging/tests.
    static func hasPersonalConduitCompartment(in composedJSON: String) -> Bool {
        guard let data = composedJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let id = dict["InproxyClientPersonalCompartmentID"] as? String ?? ""
        return !id.isEmpty
    }

    static func parseLimitProtocols(from composedJSON: String) -> String {
        guard let data = composedJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "invalid"
        }
        if let limits = dict["LimitTunnelProtocols"] as? [String], !limits.isEmpty {
            return limits.joined(separator: ",")
        }
        return "all"
    }
}

private extension CharacterSet {
    static let urlUserAllowed: CharacterSet = {
        var set = CharacterSet.urlHostAllowed
        set.insert(charactersIn: "-._~")
        return set
    }()

    static let urlPasswordAllowed: CharacterSet = {
        var set = CharacterSet.urlPasswordAllowed
        set.insert(charactersIn: "-._~")
        return set
    }()
}

import Foundation

struct IPGeoLocation: Sendable {
    let ip: String
    let city: String
    let country: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
}

/// Uses two key-free HTTPS providers in parallel. This keeps the pre-connect
/// lookup useful on networks where one geolocation provider is filtered.
enum IPGeolocationLookup {
    private enum Provider: Sendable {
        case ipWho
        case ipAPI
    }

    static func currentLocation() async -> IPGeoLocation? {
        await firstValidResult(for: nil)
    }

    static func location(for ip: String) async -> IPGeoLocation? {
        guard let normalizedIP = PublicIPAddress.normalized(ip) else { return nil }
        return await firstValidResult(for: normalizedIP)
    }

    private static func firstValidResult(for ip: String?) async -> IPGeoLocation? {
        await withTaskGroup(of: IPGeoLocation?.self) { group in
            group.addTask { await fetch(provider: .ipWho, ip: ip) }
            group.addTask { await fetch(provider: .ipAPI, ip: ip) }

            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func fetch(provider: Provider, ip: String?) async -> IPGeoLocation? {
        let url: URL?
        switch provider {
        case .ipWho:
            let root = URL(string: "https://ipwho.is")!
            url = ip.map { root.appendingPathComponent($0) } ?? root.appendingPathComponent("")
        case .ipAPI:
            let root = URL(string: "https://ipapi.co")!
            if let ip {
                url = root.appendingPathComponent(ip).appendingPathComponent("json")
            } else {
                url = root.appendingPathComponent("json")
            }
        }
        guard let url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if case .ipWho = provider,
               (json["success"] as? Bool) == false { return nil }
            if (json["error"] as? Bool) == true { return nil }

            let responseIP = (json["ip"] as? String) ?? ip ?? ""
            guard let normalizedIP = PublicIPAddress.normalized(responseIP),
                  let latitude = (json["latitude"] as? NSNumber)?.doubleValue,
                  let longitude = (json["longitude"] as? NSNumber)?.doubleValue,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { return nil }

            let city = json["city"] as? String ?? ""
            let country: String
            let countryCode: String
            switch provider {
            case .ipWho:
                country = json["country"] as? String ?? ""
                countryCode = json["country_code"] as? String ?? ""
            case .ipAPI:
                country = json["country_name"] as? String ?? ""
                countryCode = (json["country_code"] as? String)
                    ?? (json["country"] as? String)
                    ?? ""
            }

            return IPGeoLocation(
                ip: normalizedIP,
                city: city,
                country: country,
                countryCode: countryCode,
                latitude: latitude,
                longitude: longitude
            )
        } catch {
            return nil
        }
    }
}

actor OriginGeoLookup {
    static let shared = OriginGeoLookup()

    private var inFlight: Task<IPGeoLocation?, Never>?

    /// Capture while the physical connection is still active. The lookup is
    /// joined by concurrent callers so a quick Connect tap does not start a
    /// second request or accidentally resolve the VPN egress as the origin.
    func captureBeforeConnect(maxAge: TimeInterval = 60) async {
        let stored = TunnelStatisticsStore.load()
        if let capturedAt = stored.originCapturedAt,
           Date().timeIntervalSince(capturedAt) < maxAge,
           stored.originLatitude != nil,
           stored.originLongitude != nil,
           PublicIPAddress.normalized(stored.originPublicIP ?? "") != nil {
            return
        }

        let task: Task<IPGeoLocation?, Never>
        if let inFlight {
            task = inFlight
        } else {
            let created = Task.detached(priority: .utility) {
                await IPGeolocationLookup.currentLocation()
            }
            inFlight = created
            task = created
        }

        let result = await task.value
        inFlight = nil
        guard let result else {
            SharedLogger.shared.logRaw("ORIGIN_GEO_FAILED", detail: "providers=ipwho,ipapi")
            return
        }
        TunnelStatisticsStore.setOriginGeo(
            ip: result.ip,
            city: result.city,
            country: result.country,
            countryCode: result.countryCode,
            latitude: result.latitude,
            longitude: result.longitude
        )
        SharedLogger.shared.logRaw(
            "ORIGIN_GEO_READY",
            detail: "country=\(result.countryCode.uppercased())"
        )
    }
}

/// Resolves city/country for the current egress IP (shown under region on dashboard).
enum EgressGeoLookup {
    static func refreshIfNeeded() async {
        let stats = TunnelStatisticsStore.load()
        guard !stats.lastPublicIP.isEmpty else { return }
        guard let result = await IPGeolocationLookup.location(for: stats.lastPublicIP) else {
            return
        }
        TunnelStatisticsStore.setEgressGeo(
            city: result.city,
            country: result.country,
            countryCode: result.countryCode,
            latitude: result.latitude,
            longitude: result.longitude
        )
    }
}

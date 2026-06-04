import Foundation

/// Resolves city/country for the current egress IP (shown under region on dashboard).
enum EgressGeoLookup {
    static func refreshIfNeeded() async {
        let stats = TunnelStatisticsStore.load()
        guard !stats.lastPublicIP.isEmpty else { return }
        let ip = stats.lastPublicIP
        guard let url = URL(string: "https://ipwho.is/\(ip)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["success"] as? Bool) == true else { return }
            let city = json["city"] as? String ?? ""
            let country = json["country"] as? String ?? ""
            TunnelStatisticsStore.setEgressGeo(city: city, country: country)
        } catch {
            // Optional enrichment — ignore failures.
        }
    }
}

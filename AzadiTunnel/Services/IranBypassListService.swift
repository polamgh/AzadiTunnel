import Foundation

/// Downloads and caches the Iran IPv4 CIDR list used by the "Bypass Iranian IPs" feature.
///
/// Source is a GitHub-hosted, plain-text "one CIDR per line" file. The list is cached in App Group
/// storage so the packet-tunnel extension can read it offline at connect time. If the download
/// fails we keep whatever cache exists; the extension falls back to the cache (or connects normally
/// and logs a warning when there is no cache at all).
enum IranBypassListService {
    /// Remote sources tried in order. We deliberately lead with the jsdelivr CDN (a GitHub mirror)
    /// and an independent host (iwik.org), because `raw.githubusercontent.com` is frequently
    /// unreachable / returns non-200 from inside Iran. Each returns one CIDR per line (comments OK).
    private static let sourceURLs: [URL] = [
        URL(string: "https://cdn.jsdelivr.net/gh/ipverse/rir-ip@master/country/ir/ipv4-aggregated.txt")!,
        URL(string: "https://www.iwik.org/ipcountry/IR.cidr")!,
        URL(string: "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ir/ipv4-aggregated.txt")!,
    ]

    /// Refetch only when the cache is missing or older than this (unless `force`).
    private static let maxCacheAge: TimeInterval = 24 * 60 * 60

    enum RefreshResult {
        case updated(count: Int)
        case skippedFresh(count: Int)
        case usedCache(count: Int)
        case failedNoCache
    }

    /// Fetch + cache the list. Returns what happened so callers can surface it in the UI.
    @discardableResult
    static func refresh(force: Bool) async -> RefreshResult {
        let store = SharedSettingsStore.shared
        let cachedCount = store.bypassIranListCount

        if !force, let updated = store.bypassIranListUpdatedAt,
           Date().timeIntervalSince(updated) < maxCacheAge, cachedCount > 0 {
            return .skippedFresh(count: cachedCount)
        }

        SharedLogger.shared.log(.bypassIranListFetchStarted, detail: "force=\(force) sources=\(sourceURLs.count)")
        // Try each source in order; only the first success replaces the cache.
        for url in sourceURLs {
            if let lines = await download(url) {
                store.storeBypassIranCidrLines(lines)
                SharedLogger.shared.log(.bypassIranListFetchOk, detail: "count=\(lines.count) host=\(url.host ?? "?")")
                return .updated(count: lines.count)
            }
        }

        // All remote sources failed — keep the existing cache untouched if present…
        if cachedCount > 0 {
            SharedLogger.shared.log(.bypassIranListCacheUsed, detail: "count=\(cachedCount) reason=fetch_failed")
            return .usedCache(count: cachedCount)
        }
        // …otherwise the bundled list still covers routing (the extension uses it as a floor).
        SharedLogger.shared.log(.bypassIranListFetchFailed, detail: "reason=no_cache_using_bundled count=\(BundledIranCIDR.count)")
        return .usedCache(count: BundledIranCIDR.count)
    }

    private static func download(_ url: URL) async -> [String]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                SharedLogger.shared.log(.bypassIranListFetchFailed, detail: "url=\(url.host ?? "?") status=non_200")
                return nil
            }
            let lines = BypassRoutes.tokenize(text).filter { BypassRoutes.parse($0) != nil }
            guard !lines.isEmpty else {
                SharedLogger.shared.log(.bypassIranListFetchFailed, detail: "url=\(url.host ?? "?") reason=empty_or_unparseable")
                return nil
            }
            return lines
        } catch {
            SharedLogger.shared.log(.bypassIranListFetchFailed, detail: "url=\(url.host ?? "?") error=\(error.localizedDescription)")
            return nil
        }
    }
}

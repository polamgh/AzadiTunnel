import Foundation

enum ByteCountFormatter {
    /// Human-readable total (prefers KB/MB/GB).
    static func formatTotal(_ bytes: UInt64) -> String {
        let d = Double(bytes)
        if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.2f MB", d / 1_048_576) }
        if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
        if bytes == 0 { return "0 KB" }
        return "\(bytes) B"
    }

    static func formatSpeed(_ bps: UInt64) -> String {
        guard bps > 0 else { return "0 KB/s" }
        let d = Double(bps)
        if d >= 1_000_000 { return String(format: "%.1f MB/s", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1f KB/s", d / 1_000) }
        return String(format: "%.0f B/s", d)
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

import Foundation

/// A saved "best connection" found by the Find Best Connection scan: a protocol + egress region
/// that reached the minimum usable speed. Persisted separately from the user's manual selection so
/// the existing manual connection system is never modified.
struct BestConnectionRecord: Equatable {
    let protocolSelection: AppSettings.ProtocolSelection
    /// Egress region code (e.g. "DE"); empty means "Any".
    let region: String
    /// Measured usable download speed in Mbps at save time.
    let mbps: Double
    let updatedAt: Date?
}

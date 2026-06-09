import Foundation

enum SmartRecoveryLabels {
    static func phaseName(_ phase: SmartRecoveryPhase?) -> String {
        guard let phase else { return L10n.t(.smartRecoveryWorking) }
        switch phase {
        case .savedBest: return L10n.t(.smartRecoveryPhaseSavedBest)
        case .transportChain: return L10n.t(.smartRecoveryPhaseTransportChain)
        case .clearEgress: return L10n.t(.smartRecoveryPhaseClearEgress)
        case .egressRegion: return L10n.t(.smartRecoveryPhaseEgressRegion)
        case .beastAuto: return L10n.t(.smartRecoveryPhaseBeastAuto)
        case .messagingCompat: return L10n.t(.smartRecoveryPhaseMessagingCompat)
        case .secureDnsOff: return L10n.t(.smartRecoveryPhaseSecureDnsOff)
        case .conduitPublic: return L10n.t(.smartRecoveryPhaseConduitPublic)
        case .conduitUncensor: return L10n.t(.smartRecoveryPhaseConduitUncensor)
        case .directReconnect: return L10n.t(.smartRecoveryPhaseDirectReconnect)
        }
    }
}

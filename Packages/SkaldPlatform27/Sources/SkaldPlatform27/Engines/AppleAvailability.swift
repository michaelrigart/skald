import FoundationModels
import SkaldCore

public enum AppleAvailability {
    public static func current() -> UnavailableReason? {
        map(SystemLanguageModel.default.availability)
    }

    public static func map(_ availability: SystemLanguageModel.Availability) -> UnavailableReason? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .modelNotReady
        }
    }
}

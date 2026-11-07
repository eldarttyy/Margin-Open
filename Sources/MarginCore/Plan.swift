import Foundation

/// Which features are on. Free is volume and skipping tracks. Pro is the paid
/// build of Margin.
public enum Plan: String, Codable, Sendable {
    case free, pro
}

public extension Action {
    var isFree: Bool { kind == .none || kind == .nextTrack || kind == .previousTrack }
}

public extension ZoneBinding {
    /// Whether the free plan includes this binding.
    var isFree: Bool {
        switch mode {
        case .off: return true
        case .slider: return slider == .volume
        case .stepper: return forward.isFree && backward.isFree
        case .buttons: return tap.isFree && hold.isFree && doubleTap.isFree
        case .semantic: return false
        }
    }
}

public extension MarginConfig {
    /// The config the app actually runs. Everything downstream reads this, so
    /// the plan is decided in one place and a saved Pro setup returns intact on
    /// upgrading.
    func limited(to plan: Plan) -> MarginConfig {
        guard plan == .free else { return self }
        var limited = self
        limited.apps = []
        limited.smartEdges = false
        limited.capsLayer = false
        for zone in ZoneID.allCases where base[zone]?.isFree == false {
            limited.base[zone] = ZoneBinding(mode: .off)
        }
        return limited
    }
}

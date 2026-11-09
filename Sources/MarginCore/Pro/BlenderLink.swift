import Foundation

/// Where the Blender connection stands. Margin installs its connector by
/// itself, so only `restartNeeded` and `failed` ever ask anything of the person.
public enum BlenderLink: Equatable, Sendable {
    case connected, notInstalled, off, closed, starting, restartNeeded, busy, failed

    /// Blender can take this long to start with a large file.
    private static let startupGrace = 45.0

    public static func status(
        hasApp: Bool, enabled: Bool, connected: Bool, connectorWritten: Date?, launched: Date?, now: Date = Date()
    ) -> BlenderLink {
        if connected { return .connected }
        if !hasApp { return .notInstalled }
        if !enabled { return .off }
        guard let launched else { return .closed }
        guard let connectorWritten else { return .failed }
        if connectorWritten > launched { return .restartNeeded }
        return now.timeIntervalSince(launched) < startupGrace ? .starting : .busy
    }

    public var title: String {
        switch self {
        case .connected: return "Blender is connected"
        case .notInstalled: return "Blender isn't on this Mac"
        case .off: return "Connector removed"
        case .closed: return "Connects by itself when you open Blender"
        case .starting: return "Connecting to Blender…"
        case .restartNeeded: return "Restart Blender once to finish connecting"
        case .busy: return "Blender is busy. It reconnects by itself"
        case .failed: return "Margin couldn't add its connector to Blender"
        }
    }

    /// True when the person has to do something.
    public var needsAttention: Bool { self == .restartNeeded || self == .failed }
}

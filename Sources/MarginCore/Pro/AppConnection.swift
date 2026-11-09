import Foundation

/// What an app needs before Margin can work with it, so Setup can say plainly.
public enum AppConnection: Equatable, Sendable {
    /// Margin's connector, which it installs by itself.
    case connector
    /// Margin appears as a MIDI controller. The app has to be told once.
    case midi(steps: [String])
    /// Keyboard shortcuts and menu commands. Only needs Accessibility.
    case ready

    public static func of(bundleID: String) -> AppConnection? {
        if Packs.blender.bundleIDs.contains(bundleID) { return .connector }
        if Packs.pack(forBundleID: bundleID)?.name == "Music production" {
            switch bundleID {
            case "com.ableton.live":
                return .midi(steps: [
                    "In Live, open Settings, then Link, Tempo & MIDI.",
                    "Under Input Ports, turn on Remote for Margin.",
                    "Press MIDI Map, click a control, slide an edge, then press MIDI Map again.",
                ])
            case "com.apple.logic10":
                return .midi(steps: [
                    "Click the Logic control you want.",
                    "Choose Logic Pro > Control Surfaces > Learn Assignment.",
                    "Slide an edge, then close the window.",
                ])
            default:
                return .midi(steps: [
                    "Find MIDI Learn in the app.",
                    "Click the control you want.",
                    "Slide an edge. The app will list it as Margin.",
                ])
            }
        }
        return FeatureCatalog.hasBuiltIn(bundleID) || Packs.pack(forBundleID: bundleID) != nil ? .ready : nil
    }
}

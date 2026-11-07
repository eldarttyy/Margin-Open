import Foundation

/// A meaning an edge can carry, independent of how any one app performs it.
/// Forward is up or right.
public enum SemanticAction: String, Codable, CaseIterable, Sendable {
    case scroll, zoom, undoScrub, tabs, valueUnderPointer, textSize
    case seek, playbackSpeed, brushSize, timeline

    public var title: String {
        switch self {
        case .scroll: return "Scroll"
        case .zoom: return "Zoom"
        case .undoScrub: return "Undo history"
        case .tabs: return "Tabs"
        case .valueUnderPointer: return "Value under pointer"
        case .textSize: return "Text size"
        case .seek: return "Seek"
        case .playbackSpeed: return "Playback speed"
        case .brushSize: return "Brush size"
        case .timeline: return "Timeline"
        }
    }

    public var isContinuous: Bool { self == .scroll || self == .valueUnderPointer }

    public var defaultStep: Double {
        switch self {
        case .undoScrub: return 0.07
        case .tabs: return 0.14
        case .timeline: return 0.02
        case .brushSize: return 0.03
        default: return 0.08
        }
    }

    /// Menu titles that perform each direction, most specific first.
    public var menuTitles: (forward: [String], backward: [String])? {
        switch self {
        case .zoom:
            return (["zoom in", "actual size larger"], ["zoom out"])
        case .tabs:
            // Apps without tabs still have a next thing, under their own name.
            return (["show next tab", "next tab", "select next tab", "go to next conversation", "next chat",
                     "next editor", "next session", "go to next mailbox", "next document", "show next scene"],
                    ["show previous tab", "previous tab", "select previous tab", "go to previous conversation", "previous chat",
                     "previous editor", "previous session", "go to previous mailbox", "previous document", "show previous scene"])
        case .textSize:
            return (["bigger", "increase font size", "make text bigger", "make larger", "increase text size"],
                    ["smaller", "decrease font size", "make text smaller", "make smaller", "decrease text size"])
        default:
            return nil
        }
    }

    /// The shortcut pair to fall back on, or nil if menus are the only way.
    public var keys: (forward: String, backward: String)? {
        switch self {
        case .zoom: return ("cmd+=", "cmd+-")
        case .undoScrub: return ("cmd+shift+z", "cmd+z")
        case .tabs: return ("ctrl+tab", "ctrl+shift+tab")
        case .seek: return ("l", "j")
        case .playbackSpeed: return ("shift+.", "shift+,")
        case .brushSize: return ("]", "[")
        case .timeline: return ("right", "left")
        case .textSize: return ("cmd+=", "cmd+-")
        case .scroll, .valueUnderPointer: return nil
        }
    }
}

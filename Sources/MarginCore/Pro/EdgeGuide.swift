import Foundation

/// One zone of an app's edges in plain words, for the first-launch toast and
/// the list under the trackpad map: "Top edge · Editors · → Next editor   ← Previous editor".
public struct EdgeGuideRow: Equatable, Sendable {
    public var zone: ZoneID
    /// What the zone controls, such as "Editors" or "Volume".
    public var what: String
    /// How to use it, such as "→ Next editor   ← Previous editor" or "Tap: Toggle sidebar".
    public var how: String
    public var layer: Layer
}

public extension MarginConfig {
    /// Every zone that does something in this app, edges before corners.
    func guide(for context: AppContext) -> [EdgeGuideRow] {
        let resolved = resolve(context)
        return EdgeGuide.order.compactMap { zone in
            guard let item = resolved[zone], item.binding.isActive else { return nil }
            return EdgeGuideRow(zone: zone, what: item.binding.label,
                                how: EdgeGuide.how(item.binding, on: zone, bundleID: context.bundleID),
                                layer: item.layer)
        }
    }
}

public enum EdgeGuide {
    /// The order people scan a trackpad: the sides, the top and bottom, then the corners.
    public static let order: [ZoneID] = [.rightEdge, .leftEdge, .topEdge, .bottomEdge, .topLeft, .topRight, .bottomLeft, .bottomRight]

    /// How to use a binding on a zone, in a short line.
    public static func how(_ binding: ZoneBinding, on zone: ZoneID, bundleID: String?) -> String {
        let (ahead, back) = zone.slidesVertically ? ("↑", "↓") : ("→", "←")
        let slide = zone.slidesVertically ? "Slide ↑↓" : "Slide ←→"
        func pair(_ forward: String?, _ backward: String?) -> String {
            [forward.map { "\(ahead) \($0)" }, backward.map { "\(back) \($0)" }].compactMap { $0 }.joined(separator: "   ")
        }

        switch binding.mode {
        case .off:
            return ""
        case .slider:
            return slide
        case .semantic:
            if binding.semantic.isContinuous { return slide }
            let (forward, backward) = directions(binding.semantic)
            return pair(forward, backward)
        case .stepper:
            let text = pair(title(binding.forward, bundleID: bundleID), title(binding.backward, bundleID: bundleID))
            return text.isEmpty ? "\(slide), one step at a time" : text
        case .buttons:
            let parts: [(String, Action)] = [("Tap", binding.tap), ("Double-tap", binding.doubleTap), ("Hold", binding.hold)]
            return parts.compactMap { gesture, action in title(action, bundleID: bundleID).map { "\(gesture): \($0)" } }
                .joined(separator: "   ")
        }
    }

    /// What each direction of a stepped meaning does.
    static func directions(_ semantic: SemanticAction) -> (String, String) {
        switch semantic {
        case .zoom: return ("Zoom in", "Zoom out")
        case .undoScrub: return ("Redo", "Undo")
        case .tabs: return ("Next tab", "Previous tab")
        case .textSize: return ("Bigger text", "Smaller text")
        case .seek, .timeline: return ("Forward", "Back")
        case .playbackSpeed: return ("Faster", "Slower")
        case .brushSize: return ("Bigger brush", "Smaller brush")
        case .scroll, .valueUnderPointer: return ("Forward", "Back")
        }
    }

    /// An action as a person would name it. A shortcut takes the app's own name
    /// for it when Margin knows one, so "opt+cmd+right" reads "Next editor".
    static func title(_ action: Action, bundleID: String?) -> String? {
        switch action.kind {
        case .none:
            return nil
        case .keyCombo:
            let known = bundleID.flatMap(AppShortcuts.entry(forBundleID:))?.items.first { $0.combo == action.value }?.title
            return known ?? symbols(action.value)
        case .menuItem:
            return action.value.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces) ?? action.value
        case .plugin:
            return action.value.replacingOccurrences(of: "_", with: " ").capitalized
        case .openApp, .shortcut:
            return "\(action.kind.title): \(action.value)"
        default:
            return action.kind.title
        }
    }

    /// "opt+cmd+right" as the Mac writes it, "⌥⌘→".
    static func symbols(_ combo: String) -> String {
        let names: [String: String] = [
            "cmd": "⌘", "shift": "⇧", "opt": "⌥", "alt": "⌥", "ctrl": "⌃",
            "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space",
            "return": "↩", "tab": "⇥", "esc": "⎋", "pageup": "Page Up", "pagedown": "Page Down",
        ]
        // "cmd++" is cmd and the plus key, so a trailing plus is a key, not a joiner.
        var parts = combo.split(separator: "+").map(String.init)
        if combo.hasSuffix("++") { parts.append("+") }
        return parts.map { names[$0] ?? $0.uppercased() }.joined()
    }
}

/// Decides when the first-launch toast appears: once per app, and once more
/// whenever Margin's own defaults for that app change, such as after an update
/// adds a pack. The person's own edits never bring it back.
public struct ToastMemory: Equatable, Sendable {
    /// App or site ID to the fingerprint of the edges it was last shown with.
    public var shown: [String: String]

    public init(shown: [String: String] = [:]) { self.shown = shown }

    /// What Margin itself would put on this app's edges, from its shipped
    /// defaults alone. Nothing you set, here or for every app, is part of it.
    public static func fingerprint(for context: AppContext) -> String {
        MarginConfig.standard.guide(for: context)
            .map { "\($0.zone.rawValue)=\($0.what)|\($0.how)" }
            .joined(separator: ";")
    }

    /// True when the toast should show, and records it as shown.
    public mutating func shouldShow(_ id: String, fingerprint print: String) -> Bool {
        guard !print.isEmpty else { return false }
        // Seen before this memory kept fingerprints: remember today's edges
        // without showing, so an update doesn't replay every app at once.
        if shown[id] == "" {
            shown[id] = print
            return false
        }
        guard shown[id] != print else { return false }
        shown[id] = print
        return true
    }

    /// Carries over the old list of seen apps, which had no fingerprints.
    public mutating func adopt(legacy ids: [String]) {
        for id in ids where shown[id] == nil { shown[id] = "" }
    }
}

import Foundation

/// A button, toggle, tab or slider in an app's window, as Accessibility
/// reports it. Anything a mouse can click becomes something a zone can do.
public struct ScreenControl: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case button, toggle, tab, slider, popUp, link

        /// Accessibility roles, and subroles where they say more than the role.
        public init?(role: String, subrole: String) {
            switch subrole {
            case "AXTabButton": self = .tab; return
            case "AXToggleButton", "AXSwitch": self = .toggle; return
            case "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton": return nil
            default: break
            }
            switch role {
            case "AXButton", "AXMenuButton", "AXDisclosureTriangle": self = .button
            case "AXCheckBox": self = .toggle
            case "AXRadioButton", "AXTab": self = .tab
            case "AXSlider", "AXIncrementor": self = .slider
            case "AXPopUpButton": self = .popUp
            case "AXLink": self = .link
            default: return nil
            }
        }

        var noun: String {
            switch self {
            case .button: return "button"
            case .toggle: return "switch toggle checkbox"
            case .tab: return "tab section"
            case .slider: return "slider value"
            case .popUp: return "menu dropdown"
            case .link: return "link"
            }
        }
    }

    public var kind: Kind
    public var label: String

    public init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    /// The label without what changes while the app runs: VS Code's "Source
    /// Control (⌃⇧G) - 93 pending changes" is "source control", and numbers
    /// such as counts and dates drop out.
    public var key: String { Self.key(label) }

    /// The name before a colon, for a control that shows its setting: Claude's
    /// "Model: Opus 5.5 Medium" is "model" whichever model is picked.
    public var stem: String? { Self.stem(label) }

    public static func stem(_ label: String) -> String? {
        guard let colon = firstLine(label).range(of: ": ") else { return nil }
        let name = key(String(firstLine(label)[..<colon.lowerBound]))
        return name.isEmpty ? nil : name
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    public static func key(_ label: String) -> String {
        var text = firstLine(label).lowercased()
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        while let open = text.range(of: "("), let close = text.range(of: ")", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let kept = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ")
            .filter { !$0.allSatisfy(\.isNumber) }.joined(separator: " ")
    }

    /// The label as a title: no shortcut hint or count after it.
    public var title: String {
        var text = Self.firstLine(label)
        // "Model: Opus 5.5" is the model picker, whichever model it shows.
        if let colon = text.range(of: ": "), !text[..<colon.lowerBound].isEmpty { text = String(text[..<colon.lowerBound]) }
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        if let open = text.range(of: " ("), text.hasSuffix(")") { text = String(text[..<open.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Finder names its buttons "back" and "icon view".
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What a zone stores to reach a control again: the app, the kind of control,
/// its label and what to do with it. Saved as text in an `Action`'s value.
public struct ScreenTarget: Equatable, Sendable {
    public enum Verb: String, Sendable { case press, increment, decrement }

    public var verb: Verb
    public var bundleID: String
    public var kind: ScreenControl.Kind
    public var label: String

    public init(_ verb: Verb = .press, bundleID: String, kind: ScreenControl.Kind, label: String) {
        self.verb = verb
        self.bundleID = bundleID
        self.kind = kind
        self.label = label
    }

    /// The label goes last, so a `|` inside it survives.
    public var text: String { [verb.rawValue, bundleID, kind.rawValue, label].joined(separator: "|") }

    public init?(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let verb = Verb(rawValue: parts[0]), !parts[1].isEmpty,
              let kind = ScreenControl.Kind(rawValue: parts[2]), !ScreenControl.key(parts[3]).isEmpty else { return nil }
        self.init(verb, bundleID: parts[1], kind: kind, label: parts[3])
    }

    public var action: Action { Action(.screenControl, text) }

    /// The best match among an app's controls, in the order they were read.
    /// The exact label wins, then the same words with counts and hints
    /// dropped, then a label that grew words, such as "Pause" becoming
    /// "Pause (k)", then the same name before a colon. A toggle or tab may be
    /// found as the other.
    public func match(in controls: [ScreenControl]) -> Int? {
        let key = ScreenControl.key(label)
        let kinds: Set<ScreenControl.Kind> = [.toggle, .tab, .button].contains(kind) ? [kind, .toggle, .tab, .button] : [kind]
        let sameKind = { (control: ScreenControl) in control.kind == kind }
        let fits = { (control: ScreenControl) in kinds.contains(control.kind) }
        return controls.firstIndex { sameKind($0) && $0.label == label }
            ?? controls.firstIndex { sameKind($0) && $0.key == key }
            ?? controls.firstIndex { fits($0) && $0.key == key }
            ?? controls.firstIndex { sameKind($0) && $0.key.hasPrefix(key + " ") }
            ?? ScreenControl.stem(label).flatMap { stem in controls.firstIndex { sameKind($0) && $0.stem == stem } }
    }
}

extension FeatureCatalog {
    /// Features for what's in an app's windows. Links on a web page change
    /// with every page, so a browser's links stay out.
    public static func screenFeatures(bundleID: String, controls: [ScreenControl], isBrowser: Bool = false) -> [Feature] {
        var seen = Set<String>()
        return controls.compactMap { control in
            let key = control.key
            guard !key.isEmpty, key.count <= 60, !(isBrowser && control.kind == .link),
                  seen.insert("\(control.kind.rawValue)|\(key)").inserted else { return nil }
            let id = "screen.\(control.kind.rawValue).\(key)"
            let keywords = "\(control.label) \(control.kind.noun) on screen click"
            if control.kind == .slider {
                var binding = ZoneBinding.stepper(
                    forward: ScreenTarget(.increment, bundleID: bundleID, kind: .slider, label: control.label).action,
                    backward: ScreenTarget(.decrement, bundleID: bundleID, kind: .slider, label: control.label).action,
                    step: 0.05)
                binding.name = control.title
                return Feature(id: id, title: control.title, group: "On screen", keywords: keywords, payload: .binding(binding))
            }
            let target = ScreenTarget(bundleID: bundleID, kind: control.kind, label: control.label)
            return Feature(id: id, title: control.title, group: "On screen", keywords: keywords, payload: .action(target.action))
        }
    }
}

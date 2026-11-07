import Foundation

/// Something a zone can do, in words a person would search for.
public struct Feature: Identifiable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// Takes the whole edge: a slider or a pair of directions.
        case binding(ZoneBinding)
        /// One command, for a corner or one direction of an edge.
        case action(Action)
    }

    public var id: String
    public var title: String
    public var group: String
    public var keywords: String
    public var payload: Payload
    /// Needs the Margin Bridge script running inside the app.
    public var usesBridge: Bool

    public init(id: String, title: String, group: String, keywords: String = "", payload: Payload, usesBridge: Bool = false) {
        self.id = id
        self.title = title
        self.group = group
        self.keywords = keywords
        self.payload = payload
        self.usesBridge = usesBridge
    }

    public var isFree: Bool {
        switch payload {
        case .binding(let binding): return binding.isFree
        case .action(let action): return action.isFree
        }
    }

    /// Slides or presses that would hurt if touched by accident. These never
    /// get recommended, and show a warning when they're found by searching.
    public var isRisky: Bool {
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        let phrases = ["log out", "sign out", "shut down", "empty trash", "move to trash"]
        return !words.isDisjoint(with: ["quit", "delete", "erase", "remove", "restart", "close", "uninstall", "reset"])
            || phrases.contains { title.lowercased().contains($0) }
    }

    /// The ways this can go on a zone. Empty when it can't.
    public func slots(on zone: ZoneID) -> [FeatureSlot] {
        switch payload {
        case .binding(let binding):
            return !zone.isCorner || binding.mode == .off ? [.whole] : []
        case .action:
            return zone.isCorner ? [.tap, .doubleTap, .hold] : [.forward, .backward]
        }
    }
}

/// A zone's features sorted for choosing: a few good picks first, the long
/// tail folded away so the list never opens on hundreds of rows.
public struct FeatureShelves: Equatable, Sendable {
    public var best: [Feature] = []
    public var more: [Feature] = []
    public var everywhere: [Feature] = []
    public var menus: [Feature] = []
}

public enum FeatureSlot: Hashable, Sendable {
    case whole, forward, backward, tap, doubleTap, hold

    public func title(on zone: ZoneID) -> String {
        switch self {
        case .whole: return "Add"
        case .forward: return zone.slidesVertically ? "Up" : "Right"
        case .backward: return zone.slidesVertically ? "Down" : "Left"
        case .tap: return "Tap"
        case .doubleTap: return "Double"
        case .hold: return "Hold"
        }
    }
}

public extension ZoneBinding {
    /// This binding with a feature added. A command joins what's already in the
    /// zone when the kinds match, so both directions of an edge can be filled.
    func adding(_ feature: Feature, slot: FeatureSlot) -> ZoneBinding {
        switch feature.payload {
        case .binding(var binding):
            binding.name = feature.title
            return binding
        case .action(let action):
            var result = self
            switch slot {
            case .forward, .backward:
                if mode != .stepper { result = ZoneBinding(mode: .stepper) }
                if slot == .forward { result.forward = action } else { result.backward = action }
            default:
                if mode != .buttons { result = ZoneBinding(mode: .buttons) }
                let path: WritableKeyPath<ZoneBinding, Action> = slot == .doubleTap ? \.doubleTap : slot == .hold ? \.hold : \.tap
                result[keyPath: path] = action
            }
            if slot == .forward || slot == .tap || result.name.isEmpty { result.name = feature.title }
            return result
        }
    }
}

public enum FeatureCatalog {
    /// Everything known ahead of time for an app, its own features first. Menu
    /// commands are added live, because they depend on what's installed.
    public static func features(forBundleID bundleID: String?) -> [Feature] {
        appFeatures(forBundleID: bundleID) + system
    }

    /// What's specific to one app, before anything that works everywhere.
    public static func appFeatures(forBundleID bundleID: String?) -> [Feature] { [] }

    /// Features for the commands in an app's menu bar, from each item's path.
    public static func menuFeatures(_ paths: [[String]]) -> [Feature] {
        let parents = Set(paths.map { $0.dropLast() })
        return paths.compactMap { path in
            guard let title = path.last, path.count > 1, !skippedMenus.contains(path[0]), !parents.contains(path[...]),
                  !path.dropLast().contains(where: isPersonalMenu) else { return nil }
            let full = path.joined(separator: " > ")
            return Feature(id: "menu." + full, title: title, group: "\(path[0]) menu", keywords: full, payload: .action(Action(.menuItem, full)))
        }
    }

    private static let skippedMenus: Set<String> = ["Apple", "Help", "History", "Bookmarks", "Favorites"]

    /// Submenus that list the person's own files and pages, not commands.
    private static func isPersonalMenu(_ title: String) -> Bool {
        let name = title.lowercased()
        return name.contains("recent") || name == "services" || name == "history" || name == "bookmarks"
    }

    /// Menu commands most people reach for, best first, for apps Margin has no list for.
    private static let commonMenuCommands = [
        "undo", "redo", "zoom in", "zoom out", "actual size", "new tab", "save", "find", "back", "forward",
        "play", "pause", "next", "previous", "copy", "paste",
    ]

    /// Sorts what fits a zone. An app's own list is already best-first, sliders
    /// suit an edge before single commands, and anything risky is left to search.
    public static func shelves(
        app: [Feature], menus: [Feature], system: [Feature], zone: ZoneID, hidden: Set<String> = [], limit: Int = 5,
        edgePicks: [String] = []
    ) -> FeatureShelves {
        let fits = { (feature: Feature) in !feature.slots(on: zone).isEmpty && !hidden.contains(feature.id) }
        func wholeFirst(_ features: [Feature]) -> [Feature] {
            features.filter { $0.slots(on: zone) == [.whole] } + features.filter { $0.slots(on: zone) != [.whole] }
        }
        let own = wholeFirst(app.filter(fits))
        let ownTitles = Set(own.map { $0.title.lowercased() })
        let commands = menus.filter { fits($0) && !ownTitles.contains($0.title.lowercased()) }
        let general = wholeFirst(system.filter(fits))

        func commonRank(_ feature: Feature) -> Int? {
            commonMenuCommands.firstIndex(of: feature.title.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "…. ")))
        }
        let common = commands.compactMap { feature in commonRank(feature).map { ($0, feature) } }
            .sorted { $0.0 < $1.0 }.map(\.1)

        // A slider suits an edge better than one command, so an app with no
        // sliders of its own still leads with the ones that fit it.
        let hasOwnSlider = own.contains { $0.slots(on: zone) == [.whole] }
        let lead = zone.isCorner || hasOwnSlider ? [] : edgePicks.compactMap { id in general.first { $0.id == id } }

        var best: [Feature] = []
        for feature in lead + own + common + general where best.count < limit {
            if !feature.isRisky, feature.id != "system.off", !best.contains(where: { $0.id == feature.id }) {
                best.append(feature)
            }
        }
        let picked = Set(best.map(\.id))
        let rest = { (features: [Feature]) in features.filter { !picked.contains($0.id) } }
        return FeatureShelves(
            best: best, more: rest(own), everywhere: rest(general),
            menus: rest(commands).filter { !$0.isRisky } + rest(commands).filter(\.isRisky))
    }

    /// Whole-edge features that suit an app with none of its own.
    public static func edgePicks(forBundleID bundleID: String?) -> [String] {
        guard let bundleID else { return [] }
        let players = ["com.spotify.client", "com.apple.Music", "com.apple.TV", "com.apple.podcasts"]
        return players.contains(bundleID) ? ["system.volume", "system.skip"] : ["any.scroll", "any.zoom", "any.tabs"]
    }

    /// True when Margin has a ready-made list for an app.
    public static func hasBuiltIn(_ bundleID: String) -> Bool { !appFeatures(forBundleID: bundleID).isEmpty }

    /// Every word must match somewhere; matches in the title sort first.
    public static func search(_ query: String, in features: [Feature]) -> [Feature] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return features }
        func rank(_ feature: Feature) -> Int? {
            let title = feature.title.lowercased()
            let text = "\(title) \(feature.group) \(feature.keywords)".lowercased()
            guard words.allSatisfy(text.contains) else { return nil }
            if title.hasPrefix(words[0]) { return 0 }
            return words.allSatisfy(title.contains) ? 1 : 2
        }
        return features.enumerated()
            .compactMap { index, feature in rank(feature).map { ($0, index, feature) } }
            .sorted { ($0.2.isRisky ? 1 : 0, $0.0, $0.1) < ($1.2.isRisky ? 1 : 0, $1.0, $1.1) }
            .map(\.2)
    }

    // MARK: Built in

    public static let system: [Feature] = {
        func slider(_ target: SliderTarget, _ keywords: String) -> Feature {
            Feature(id: "system.\(target)", title: target.title, group: "System", keywords: keywords, payload: .binding(.slider(target)))
        }
        func action(_ kind: ActionKind, _ keywords: String) -> Feature {
            Feature(id: "system.\(kind)", title: kind.title, group: "System", keywords: keywords, payload: .action(Action(kind)))
        }
        let skipping = ZoneBinding.stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25)
        return [
            slider(.volume, "sound audio speaker loudness"),
            Feature(id: "system.skip", title: "Skip tracks", group: "System", keywords: "next previous song music media", payload: .binding(skipping)),
            action(.nextTrack, "skip forward song music media"),
            action(.previousTrack, "skip back song music media"),
            slider(.brightness, "screen monitor light"),
            slider(.keyboardBacklight, "keys light"),
            slider(.micVolume, "input recording gain"),
            action(.playPause, "pause resume song music media"),
            action(.toggleMute, "silence sound audio"),
            action(.toggleMic, "silence input call meeting"),
            Feature(id: "system.off", title: "Off", group: "System", keywords: "nothing disable none empty", payload: .binding(ZoneBinding(mode: .off))),
        ] + SemanticAction.allCases.map {
            Feature(id: "any.\($0)", title: $0.title, group: "Works in any app", payload: .binding(.semantic($0)))
        }
    }()
}

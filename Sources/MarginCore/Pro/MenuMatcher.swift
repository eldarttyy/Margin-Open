import Foundation

/// One item from an app's menu bar. `Handle` is whatever lets the host press it.
public struct MenuEntry<Handle> {
    public var path: [String]
    public var title: String
    public var handle: Handle

    public init(path: [String], title: String, handle: Handle) {
        self.path = path
        self.title = title
        self.handle = handle
    }
}

public enum MenuMatcher {
    /// Lowercased with dots and shortcut decoration removed, so "Zoom In…"
    /// matches. Invisible direction marks go too, which WhatsApp's titles start with.
    public static func normalize(_ title: String) -> String {
        String(title.unicodeScalars.filter { !(0x200E...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value) })
            .lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds a command by its title or the end of its path, as in `Zoom In` or
    /// `View > Zoom In`. The path form settles items sharing a title.
    public static func find<Handle>(_ path: String, in items: [MenuEntry<Handle>]) -> MenuEntry<Handle>? {
        let wanted = path.split(separator: ">").map { normalize(String($0)) }
        guard !wanted.isEmpty else { return nil }
        return items.first { Array($0.path.map(normalize).suffix(wanted.count)) == wanted }
    }

    /// The menu items for both directions of an action. Both must exist: one
    /// without the other would make the edge work one way only.
    public static func match<Handle>(_ action: SemanticAction, in items: [MenuEntry<Handle>]) -> (forward: MenuEntry<Handle>, backward: MenuEntry<Handle>)? {
        guard let found = options(action, in: items), let forward = found.forward.first, let backward = found.backward.first else { return nil }
        return (forward, backward)
    }

    /// Every item for each direction, best first, or nil unless both directions
    /// exist. An app can carry a disabled "Show Next Tab" above the command that
    /// really works, as Messages does, so the caller picks the first enabled one.
    public static func options<Handle>(_ action: SemanticAction, in items: [MenuEntry<Handle>]) -> (forward: [MenuEntry<Handle>], backward: [MenuEntry<Handle>])? {
        guard let titles = action.menuTitles else { return nil }
        var byTitle: [String: MenuEntry<Handle>] = [:]
        for item in items where byTitle[normalize(item.title)] == nil {
            byTitle[normalize(item.title)] = item
        }
        let forward = titles.forward.compactMap { byTitle[$0] }
        let backward = titles.backward.compactMap { byTitle[$0] }
        return forward.isEmpty || backward.isEmpty ? nil : (forward, backward)
    }
}

/// Whether a slide from `old` to `new` passed a meaningful value. Landing
/// exactly on one counts; leaving one doesn't, or a rest there would tick twice.
public enum Detents {
    public static func crossed(from old: Double, to new: Double, detents: [Double]) -> Bool {
        guard old != new else { return false }
        let low = min(old, new), high = max(old, new)
        return detents.contains { $0 != old && $0 >= low && $0 <= high }
    }
}

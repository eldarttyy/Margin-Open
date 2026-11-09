import Foundation

/// What Margin knows about the app in front.
public struct AppContext: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?
    public var category: AppCategory
    /// Reported by a plugin, such as Blender's "SCULPT".
    public var mode: String?
    /// The known website in a browser's front tab, by its pack's ID.
    public var site: String?

    public init(bundleID: String? = nil, name: String? = nil, category: AppCategory = .other, mode: String? = nil, site: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.category = category
        self.mode = mode
        self.site = site
    }
}

public enum AppCategory: String, Sendable {
    case video, music, graphics, developer, other

    /// From an app's `LSApplicationCategoryType`.
    public init(lsCategory: String?) {
        switch lsCategory {
        case "public.app-category.video", "public.app-category.photography": self = .video
        case "public.app-category.music": self = .music
        case "public.app-category.graphics-design": self = .graphics
        case "public.app-category.developer-tools": self = .developer
        default: self = .other
        }
    }
}

/// Later layers win, zone by zone, and the lowest always has an answer. That's
/// what makes an app nobody configured work on the first launch.
public enum Layer: Int, Sendable, Comparable {
    case system, universal, category, pack, user

    public static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .universal: return "Universal"
        case .category: return "App category"
        case .pack: return "App pack"
        case .user: return "Your override"
        }
    }
}

public struct ResolvedBinding: Equatable, Sendable {
    public var binding: ZoneBinding
    public var layer: Layer

    public init(binding: ZoneBinding, layer: Layer) {
        self.binding = binding
        self.layer = layer
    }
}

public extension MarginConfig {
    /// Stacks the layers for an app. Corners come from the system layer, so a
    /// mute corner stays put from app to app unless something claims it.
    func resolve(_ context: AppContext, capsHeld: Bool = false) -> [ZoneID: ResolvedBinding] {
        var result: [ZoneID: ResolvedBinding] = [:]

        func apply(_ bindings: [ZoneID: ZoneBinding], _ layer: Layer) {
            for (zone, binding) in bindings { result[zone] = ResolvedBinding(binding: binding, layer: layer) }
        }

        for zone in ZoneID.allCases {
            if let binding = base[zone] { result[zone] = ResolvedBinding(binding: binding, layer: .system) }
        }

        let isSystemApp = context.bundleID.map(Layers.systemApps.contains) ?? true
        if smartEdges, !isSystemApp {
            apply(Layers.universal, .universal)
            apply(Layers.category(context.category), .category)
            if let pack = Packs.pack(forBundleID: context.bundleID) {
                apply(pack.bindings, .pack)
                if let mode = context.mode, let bindings = pack.modes[mode] { apply(bindings, .pack) }
            }
            if let site = context.site.flatMap(Sites.pack(id:)) { apply(site.bindings, .pack) }
        }

        if capsLayer, capsHeld { apply(Layers.caps, .universal) }

        if let app = profile(forBundleID: context.bundleID) {
            for zone in ZoneID.allCases {
                if let binding = app[zone] { result[zone] = ResolvedBinding(binding: binding, layer: .user) }
                if let mode = context.mode, let binding = app[zone, mode: mode] {
                    result[zone] = ResolvedBinding(binding: binding, layer: .user)
                }
            }
        }
        if let site = context.site, let saved = profile(forBundleID: Sites.profileID(site)) {
            for zone in ZoneID.allCases {
                if let binding = saved[zone] { result[zone] = ResolvedBinding(binding: binding, layer: .user) }
            }
        }
        return result
    }

    /// Just the bindings, for the gesture engine.
    func bindings(for context: AppContext, capsHeld: Bool = false) -> [ZoneID: ZoneBinding] {
        resolve(context, capsHeld: capsHeld).mapValues(\.binding)
    }
}

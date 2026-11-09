import AppKit

struct InstalledApp: Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
}

/// App icons for lists. Fetching one takes over half a millisecond on the main
/// thread, which adds up fast when a whole sidebar redraws.
@MainActor
enum AppIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(for url: URL) -> NSImage {
        if let icon = cache.object(forKey: url.path as NSString) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}

/// Finds apps by looking in the places macOS keeps them, one level into folders
/// because suites such as Adobe's nest their apps.
enum InstalledApps {
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }

    /// Call off the main thread. Sorted by name, with running apps included
    /// even when they live somewhere unusual.
    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, found[id] == nil else { return }
            found[id] = InstalledApp(id: id, name: url.deletingPathExtension().lastPathComponent, url: url)
        }
        let files = FileManager.default
        for folder in folders {
            for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let inner = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { add(url) }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

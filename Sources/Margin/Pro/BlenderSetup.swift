import AppKit
import MarginCore

/// Connects Blender with no steps inside Blender. Blender runs anything in its
/// user `scripts/startup` folder on launch, so nothing needs enabling. The file
/// is kept current here, so it's never something a person installs.
enum BlenderSetup {
    private static let fileName = "margin_bridge.py"
    private static let bundleID = Packs.blender.bundleIDs[0]
    private static let removedKey = "blenderConnectorRemoved"

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Blender")
    }

    /// Blender 4 and later, one folder per version.
    private static var versions: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { name in
                let parts = name.split(separator: ".")
                return parts.count == 2 && parts.allSatisfy { Int($0) != nil } && (Int(parts[0]) ?? 0) >= 4
            }
            .map { root.appendingPathComponent($0) }
    }

    private static func target(in version: URL) -> URL {
        version.appendingPathComponent("scripts/startup/\(fileName)")
    }

    /// False once someone removes the connector, until they add it back.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: removedKey) }
        set { UserDefaults.standard.set(!newValue, forKey: removedKey) }
    }

    /// Writes the connector for every Blender version that lacks the current
    /// one. Safe to call often: a file that's already right isn't touched, so
    /// a running Blender isn't told to restart for nothing.
    static func sync() {
        guard isEnabled,
              let source = Bundle.main.url(forResource: "margin_bridge", withExtension: "py"),
              let contents = try? Data(contentsOf: source) else { return }
        let files = FileManager.default
        for version in versions {
            let file = target(in: version)
            // An older manual install would claim the same port.
            try? files.removeItem(at: version.appendingPathComponent("scripts/addons/\(fileName)"))
            guard (try? Data(contentsOf: file)) != contents else { continue }
            try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: file, options: .atomic)
        }
    }

    static func remove() {
        isEnabled = false
        for version in versions { try? FileManager.default.removeItem(at: target(in: version)) }
    }

    /// Where things stand right now. Reads a few file dates, so it's cheap.
    static func link(connected: Bool) -> BlenderLink {
        let files = FileManager.default
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let written = versions
            .compactMap { (try? files.attributesOfItem(atPath: target(in: $0).path))?[.modificationDate] as? Date }
            .max()
        return BlenderLink.status(
            hasApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
            enabled: isEnabled, connected: connected, connectorWritten: written, launched: running?.launchDate)
    }
}

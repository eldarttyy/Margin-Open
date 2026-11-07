import Foundation
import MarginCore
import SwiftUI

/// Owns the config and keeps ~/Library/Application Support/Margin/config.json in step.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: MarginConfig {
        didSet {
            guard config != oldValue else { return }
            onChange?(config)
            scheduleSave()
        }
    }
    @Published private(set) var loadWarning: String?

    var onChange: ((MarginConfig) -> Void)?
    private var saveTask: DispatchWorkItem?

    static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Margin/config.json")
    }()

    /// `persist: false` is for snapshots, which must not touch the real config.
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        config = .standard
        guard persist else { return }
        reload()
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { save() }
    }

    /// A file that won't parse is moved aside rather than overwritten, so a
    /// typo in a hand edit can't destroy someone's bindings.
    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            config = try JSONDecoder().decode(MarginConfig.self, from: data)
            loadWarning = nil
        } catch {
            let backup = Self.fileURL.deletingLastPathComponent().appendingPathComponent("config.invalid.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: Self.fileURL, to: backup)
            loadWarning = "config.json couldn't be read, so it was saved as config.invalid.json and defaults are in use."
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.save() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    func save() {
        guard persist else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

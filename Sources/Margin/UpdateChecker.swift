import Foundation
import MarginCore

/// Keeps nothing between requests: no cookies, no cache on disk, and a license
/// key never lands in a file.
enum Network {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
}

/// Asks the site for the latest version on launch and daily, and offers a link.
/// It doesn't install anything: replacing an ad-hoc signed app resets its
/// Accessibility grant, so automatic updates wait for a Developer ID.
@MainActor
final class UpdateChecker: ObservableObject {
    /// The site's version.json. Change it here if the site moves to its own domain.
    static let feedURL: URL? = URL(string: "https://margin-theta-five.vercel.app/version.json")

    private static let enabledKey = "checkForUpdates"

    @Published private(set) var available: AvailableUpdate? { didSet { onChange?() } }
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    var onChange: (() -> Void)?

    private var timer: Timer?

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard enabled, Self.feedURL != nil, timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 60 * 60
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        available = nil
    }

    private func check() {
        guard let url = Self.feedURL,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        Task { [weak self] in
            // A failed check says nothing about updates, so it changes nothing.
            guard let (data, _) = try? await Network.session.data(from: url),
                  let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data) else { return }
            self?.available = feed.update(after: current, feed: url)
        }
    }
}

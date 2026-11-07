import Foundation

/// A newer version the person can download.
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// The site's `version.json`. `url` may be relative to the feed.
public struct UpdateFeed: Decodable, Equatable, Sendable {
    public var version: String
    public var url: String

    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }

    /// The update to offer someone on `current`, if any. Only https links are
    /// offered, because Margin opens this one in the browser.
    public func update(after current: String, feed: URL) -> AvailableUpdate? {
        guard version.compare(current, options: .numeric) == .orderedDescending,
              let link = URL(string: url, relativeTo: feed)?.absoluteURL,
              link.scheme == "https" else { return nil }
        return AvailableUpdate(version: version, url: link)
    }
}

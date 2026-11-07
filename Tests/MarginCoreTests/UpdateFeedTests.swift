import Foundation
import Testing
@testable import MarginCore

private let feed = URL(string: "https://example.com/version.json")!

@Test func offersANewerVersionWithItsFullLink() {
    let update = UpdateFeed(version: "0.2.0", url: "index.html#download").update(after: "0.1.0", feed: feed)
    #expect(update?.version == "0.2.0")
    #expect(update?.url.absoluteString == "https://example.com/index.html#download")
}

@Test func comparesVersionsAsNumbers() {
    #expect(UpdateFeed(version: "0.10.0", url: "a").update(after: "0.9.0", feed: feed) != nil)
    #expect(UpdateFeed(version: "0.9.0", url: "a").update(after: "0.10.0", feed: feed) == nil)
}

@Test func offersNothingWhenCurrent() {
    #expect(UpdateFeed(version: "0.1.0", url: "a").update(after: "0.1.0", feed: feed) == nil)
}

@Test func refusesLinksThatAreNotHTTPS() {
    #expect(UpdateFeed(version: "0.2.0", url: "http://example.com/a").update(after: "0.1.0", feed: feed) == nil)
    #expect(UpdateFeed(version: "0.2.0", url: "file:///etc/passwd").update(after: "0.1.0", feed: feed) == nil)
}

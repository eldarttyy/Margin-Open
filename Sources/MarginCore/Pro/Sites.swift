import Foundation

/// Built-in edges and shortcuts for one website, layered over the browser's own.
public struct SitePack: Sendable {
    public var id: String
    public var name: String
    var hosts: [String]
    /// Narrows a host that serves several products. Safari's address bar shows
    /// only the domain by default, so each such host also needs a pack without one.
    var path: String?
    public var bindings: [ZoneID: ZoneBinding]
    var items: [(combo: String, title: String, keywords: String)]

    /// What this site adds to the feature library.
    public var features: [Feature] {
        items.map { item in
            Feature(id: "site.\(id).\(item.title)", title: item.title, group: "\(name) shortcuts",
                    keywords: "\(item.keywords) \(item.combo)", payload: .action(Action(.keyCombo, item.combo)))
        }
    }
}

public enum Sites {
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        // Other builds of those engines, with the same address bar. None was on
        // the test Mac, so SiteReader hasn't read their bars yet.
        "company.thebrowser.dia", "ai.perplexity.comet", "app.zen-browser.zen", "com.kagi.kagimacOS",
        "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser.beta", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "net.waterfox.waterfox",
        "com.operasoftware.OperaGX", "com.duckduckgo.macos.browser", "com.apple.SafariTechnologyPreview",
        "ru.yandex.desktop.yandex-browser",
    ]

    private static let prefix = "site:"

    /// Where a person's changes to a site are saved, beside their app profiles.
    public static func profileID(_ site: String) -> String { prefix + site }

    public static func pack(id: String) -> SitePack? { all.first { $0.id == id } }

    public static func pack(profileID: String?) -> SitePack? {
        guard let profileID, profileID.hasPrefix(prefix) else { return nil }
        return pack(id: String(profileID.dropFirst(prefix.count)))
    }

    /// The pack for what an address bar shows. Bars often drop the scheme, and
    /// hold a search instead of an address while someone types.
    public static func pack(address: String) -> SitePack? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let scheme = text.range(of: "://") { text.removeSubrange(..<scheme.upperBound) }
        let end = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let path = String(text[end...])
        var host = String(text[..<end])
        if let login = host.lastIndex(of: "@") { host.removeSubrange(...login) }
        if let port = host.firstIndex(of: ":") { host.removeSubrange(port...) }
        return all.first { pack in
            pack.hosts.contains { host == $0 || host.hasSuffix("." + $0) } && (pack.path.map(path.hasPrefix) ?? true)
        }
    }

    private static let back = Action(.keyCombo, "left")
    private static let ahead = Action(.keyCombo, "right")
    private static let undo = ZoneBinding.semantic(.undoScrub)
    private static let edit: [(combo: String, title: String, keywords: String)] = [("cmd+z", "Undo", "back revert"), ("cmd+shift+z", "Redo", "again")]
    /// Figma's canvas takes these from the browser's own page zoom.
    private static let figmaZoom = Packs.named("Zoom", Packs.step("cmd+=", "cmd+-", 0.07))

    /// Chrome doesn't tell Accessibility when a page's text box has focus, so
    /// nothing built in here may send a key that types: one touch would put a
    /// `k` in a comment or an email. Arrows are safe, and the media key reaches
    /// the page without touching the keyboard focus at all. The letters stay in
    /// each site's feature list for anyone who chooses them.
    private static func player(seek: Bool = true) -> [ZoneID: ZoneBinding] {
        var bindings: [ZoneID: ZoneBinding] = [
            .leftEdge: .slider(.volume),
            .topRight: Packs.named("Play or pause", .buttons(tap: Action(.playPause), hold: Action(.toggleMute))),
        ]
        if seek { bindings[.bottomEdge] = Packs.named("Seek", .stepper(forward: ahead, backward: back, step: 0.06)) }
        return bindings
    }

    /// Specific packs first, so Sheets wins over the rest of docs.google.com.
    public static let all: [SitePack] = [
        // Before YouTube, which would otherwise claim these subdomains.
        SitePack(
            id: "youtubemusic", name: "YouTube Music", hosts: ["music.youtube.com"],
            bindings: [
                .leftEdge: .slider(.volume),
                .topEdge: Packs.named("Skip tracks", .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25)),
                .topRight: Packs.named("Play or pause", .buttons(tap: Action(.playPause), hold: Action(.toggleMute))),
            ],
            items: [
                ("space", "Play or pause", "song"), ("s", "Shuffle", "random"), ("r", "Repeat", "loop"),
            ]),
        // Studio is a dashboard, not a player, so it keeps the browser's edges.
        SitePack(id: "youtubestudio", name: "YouTube Studio", hosts: ["studio.youtube.com"], bindings: [:], items: []),
        SitePack(
            id: "youtube", name: "YouTube", hosts: ["youtube.com"],
            bindings: player(),
            items: [
                ("k", "Play or pause", "video"), ("l", "Forward 10 seconds", "skip seek"), ("j", "Back 10 seconds", "rewind seek"),
                ("right", "Forward 5 seconds", "skip seek"), ("left", "Back 5 seconds", "rewind seek"),
                ("shift+.", "Faster", "speed"), ("shift+,", "Slower", "speed"), ("shift+n", "Next video", "skip"),
                ("m", "Mute video", "sound"), ("f", "Full screen", "theater"), ("c", "Captions", "subtitles"),
            ]),
        SitePack(
            id: "netflix", name: "Netflix", hosts: ["netflix.com"], bindings: player(),
            items: [
                ("space", "Play or pause", "video"), ("right", "Forward 10 seconds", "skip seek"), ("left", "Back 10 seconds", "rewind seek"),
                ("m", "Mute video", "sound"), ("f", "Full screen", ""), ("s", "Skip intro", "recap"),
            ]),
        SitePack(
            id: "twitch", name: "Twitch", hosts: ["twitch.tv"], bindings: player(seek: false),
            items: [("space", "Play or pause", "stream"), ("m", "Mute stream", "sound"), ("f", "Full screen", "")]),
        SitePack(
            id: "spotify", name: "Spotify", hosts: ["open.spotify.com"],
            bindings: [
                .rightEdge: .slider(.volume),
                .topEdge: Packs.named("Skip tracks", .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25)),
                .topRight: .buttons(tap: Action(.playPause), hold: Action(.toggleMute)),
            ],
            items: []),
        SitePack(
            id: "meet", name: "Google Meet", hosts: ["meet.google.com"],
            bindings: Packs.callEdges(mute: "cmd+d", camera: "cmd+e"),
            items: [
                ("cmd+d", "Mute microphone", "audio meeting"), ("cmd+e", "Toggle camera", "video"),
                ("ctrl+cmd+h", "Raise hand", "react"), ("ctrl+cmd+c", "Toggle chat", "messages"), ("ctrl+cmd+p", "People", "participants"),
            ]),
        SitePack(
            id: "teams", name: "Teams", hosts: ["teams.microsoft.com", "teams.live.com"],
            bindings: Packs.callEdges(mute: "cmd+shift+m", camera: "cmd+shift+o"),
            items: [("cmd+shift+m", "Mute microphone", "audio meeting"), ("cmd+shift+o", "Toggle camera", "video")]),
        SitePack(id: "zoom", name: "Zoom", hosts: ["app.zoom.us"], bindings: Packs.callEdges(), items: []),
        // Gmail's own letter shortcuts are off until someone enables them in its
        // settings, so edges stay the browser's and these are opt-in.
        SitePack(
            id: "gmail", name: "Gmail", hosts: ["mail.google.com"], bindings: [:],
            items: [
                ("j", "Older conversation", "next needs keyboard shortcuts on in gmail settings"),
                ("k", "Newer conversation", "previous needs keyboard shortcuts on in gmail settings"),
                ("e", "Archive", "needs keyboard shortcuts on in gmail settings"),
                ("r", "Reply", "needs keyboard shortcuts on in gmail settings"),
                ("c", "Compose", "new needs keyboard shortcuts on in gmail settings"),
            ]),
        SitePack(
            id: "sheets", name: "Google Sheets", hosts: ["docs.google.com"], path: "/spreadsheets",
            bindings: [
                .bottomEdge: undo,
                .topEdge: Packs.named("Sheets", .stepper(forward: Action(.keyCombo, "opt+down"), backward: Action(.keyCombo, "opt+up"), step: 0.14)),
            ],
            items: [("opt+down", "Next sheet", "tab"), ("opt+up", "Previous sheet", "tab"), ("cmd+opt+m", "Comment", "note")]),
        SitePack(
            id: "slides", name: "Google Slides", hosts: ["docs.google.com"], path: "/presentation",
            bindings: [.bottomEdge: undo],
            items: [("cmd+return", "Present", "slideshow start"), ("ctrl+m", "New slide", "add"), ("cmd+opt+m", "Comment", "note")]),
        SitePack(id: "forms", name: "Google Forms", hosts: ["docs.google.com"], path: "/forms", bindings: [.bottomEdge: undo], items: []),
        SitePack(
            id: "docs", name: "Google Docs", hosts: ["docs.google.com"], bindings: [.bottomEdge: undo],
            items: [("cmd+opt+m", "Comment", "note"), ("cmd+shift+c", "Word count", "length"), ("cmd+\\", "Clear formatting", "plain")]),
        // FigJam and Figma Slides share figma.com and most of its keys.
        SitePack(
            id: "figjam", name: "FigJam", hosts: ["figma.com"], path: "/board",
            bindings: [.bottomEdge: undo, .leftEdge: figmaZoom],
            items: edit + [("shift+1", "Zoom to fit", "show everything"), ("v", "Move tool", "select"), ("s", "Sticky note", "post-it"), ("x", "Section", "group")]),
        SitePack(
            id: "figmaslides", name: "Figma Slides", hosts: ["figma.com"], path: "/slides",
            bindings: [.bottomEdge: undo, .leftEdge: figmaZoom],
            items: edit + [("cmd+return", "Present", "slideshow start")]),
        SitePack(
            id: "figma", name: "Figma", hosts: ["figma.com"], bindings: [.bottomEdge: undo, .leftEdge: figmaZoom],
            items: AppShortcuts.entry(forBundleID: "com.figma.Desktop")?.items ?? []),
        SitePack(
            id: "slack", name: "Slack", hosts: ["app.slack.com"],
            bindings: [.topEdge: Packs.conversations, .bottomEdge: ZoneBinding(mode: .off)],
            items: AppShortcuts.entry(forBundleID: "com.tinyspeck.slackmacgap")?.items ?? []),
        SitePack(
            id: "discord", name: "Discord", hosts: ["discord.com"],
            bindings: [.topEdge: Packs.conversations, .bottomEdge: ZoneBinding(mode: .off)],
            items: AppShortcuts.entry(forBundleID: "com.hnc.Discord")?.items ?? []),
    ]
}

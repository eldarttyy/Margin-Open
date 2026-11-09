import Foundation

/// Built-in bindings for one family of apps. `modes` applies on top of
/// `bindings` when a plugin reports that mode.
public struct AppPack: Sendable {
    public var name: String
    public var bundleIDs: [String]
    public var bindings: [ZoneID: ZoneBinding]
    public var modes: [String: [ZoneID: ZoneBinding]]

    public init(name: String, bundleIDs: [String], bindings: [ZoneID: ZoneBinding], modes: [String: [ZoneID: ZoneBinding]] = [:]) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.bindings = bindings
        self.modes = modes
    }
}

public enum Layers {
    /// Apps where the system controls are the most useful thing on the edges.
    public static let systemApps: Set<String> = ["com.apple.finder", "com.apple.Music", "com.spotify.client"]

    public static let universal: [ZoneID: ZoneBinding] = [
        .rightEdge: .semantic(.scroll),
        .leftEdge: .semantic(.zoom),
        .bottomEdge: .semantic(.undoScrub),
        .topEdge: .semantic(.tabs),
    ]

    /// The second layer, while Caps Lock is held.
    public static let caps: [ZoneID: ZoneBinding] = [
        .rightEdge: .semantic(.valueUnderPointer),
        .leftEdge: .semantic(.textSize),
        .topEdge: .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25),
        .bottomEdge: .semantic(.seek),
    ]

    public static func category(_ category: AppCategory) -> [ZoneID: ZoneBinding] {
        switch category {
        case .video, .music: return [.bottomEdge: .semantic(.timeline)]
        case .graphics: return [.rightEdge: .semantic(.brushSize)]
        case .developer, .other: return [:]
        }
    }
}

public enum Packs {
    public static let blender = AppPack(
        name: "Blender",
        bundleIDs: ["org.blenderfoundation.blender"],
        bindings: [
            .bottomEdge: .plugin("frame", name: "Timeline frame"),
            .topEdge: .plugin("viewport_orbit", name: "Viewport orbit"),
            .rightEdge: .plugin("viewport_zoom", name: "Viewport zoom"),
            .leftEdge: .plugin("viewport_pan", name: "Viewport pan"),
            .topLeft: command("xray_toggle", "X-ray"),
            .topRight: command("camera_view", "Camera view"),
            .bottomLeft: command("shading_cycle", "Shading mode"),
            .bottomRight: command("render_preview", "Render preview"),
        ],
        modes: [
            "SCULPT": [
                .rightEdge: .plugin("brush_size", name: "Brush radius"),
                .leftEdge: .plugin("brush_strength", name: "Brush strength"),
            ],
            // Object mode, with a Subdivision modifier on the active object.
            "SUBDIV": [
                .leftEdge: .plugin("subdivision_level", name: "Subdivision level"),
            ],
            // A running grab owns Blender's input, so only scroll events reach it.
            "GRAB": [
                .rightEdge: .semantic(.scroll),
            ],
        ])

    /// A plugin's mode name as people read it.
    public static func modeTitle(_ mode: String) -> String {
        mode == "SUBDIV" ? "Subdivision" : mode.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func command(_ name: String, _ label: String) -> ZoneBinding {
        var binding = ZoneBinding.buttons()
        binding.doubleTap = Action(.plugin, name)
        binding.name = label
        return binding
    }

    public static let all: [AppPack] = [
        blender,
        AppPack(
            name: "Music production",
            bundleIDs: ["com.apple.logic10", "com.ableton.live", "com.apple.garageband10"],
            bindings: [
                .rightEdge: .midi(cc: 7, name: "Fader"),
                .leftEdge: .midi(cc: 1, name: "Mod"),
                .topEdge: .midi(cc: 10, name: "Pan"),
                .bottomEdge: .semantic(.timeline),
            ]),
        AppPack(
            name: "Video editors",
            bundleIDs: ["com.apple.FinalCut", "com.adobe.PremierePro", "com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"],
            bindings: [
                .bottomEdge: .semantic(.seek),
                .rightEdge: .semantic(.zoom),
            ]),
        AppPack(
            name: "Terminals",
            bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2"],
            bindings: [
                .rightEdge: .stepper(forward: Action(.keyCombo, "up"), backward: Action(.keyCombo, "down"), step: 0.07),
            ]),
        AppPack(name: "Code editors", bundleIDs: codeEditors, bindings: [
            // ctrl+tab in VS Code opens a recently-used picker, so step through tabs in the order they're shown.
            .topEdge: named("Editors", .stepper(forward: Action(.keyCombo, "opt+cmd+right"), backward: Action(.keyCombo, "opt+cmd+left"), step: 0.14)),
            .bottomEdge: named("Back and forward", .stepper(forward: Action(.keyCombo, "ctrl+shift+-"), backward: Action(.keyCombo, "ctrl+-"), step: 0.14)),
            .leftEdge: named("Problems", .stepper(forward: Action(.keyCombo, "f8"), backward: Action(.keyCombo, "shift+f8"), step: 0.14)),
            .topLeft: named("Sidebar", .buttons(tap: Action(.keyCombo, "cmd+b"))),
            .topRight: named("Terminal", .buttons(tap: Action(.keyCombo, "ctrl+`"))),
        ]),
        AppPack(name: "Browsers", bundleIDs: Sites.browsers.sorted(), bindings: [
            .bottomEdge: named("Back and forward", .stepper(forward: Action(.keyCombo, "cmd+]"), backward: Action(.keyCombo, "cmd+["), step: 0.14)),
        ]),
        meeting("Zoom", ["us.zoom.xos"], mute: "cmd+shift+a", camera: "cmd+shift+v"),
        meeting("Teams", ["com.microsoft.teams2", "com.microsoft.teams"], mute: "cmd+shift+m", camera: "cmd+shift+o"),
        meeting("FaceTime", ["com.apple.FaceTime"], mute: "cmd+shift+m"),
        // No shortcut these share, so their mic stays on the system's corner.
        meeting("Calls", ["Cisco-Systems.Spark", "com.google.GoogleMeet"]),
        chat("Chat", ["ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.apple.MobileSMS"], top: .semantic(.tabs)),
        chat("Team chat", ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.whispersystems.signal-desktop"], top: conversations),
        AppPack(name: "Players", bundleIDs: players, bindings: [
            .rightEdge: .slider(.volume),
            .leftEdge: .slider(.brightness),
            .topEdge: named("Skip", .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25)),
            .bottomEdge: .semantic(.timeline),
            .topRight: named("Play or pause", .buttons(tap: Action(.keyCombo, "space"), hold: Action(.toggleMute))),
        ]),
        AppPack(name: "Calendar", bundleIDs: ["com.apple.iCal"], bindings: [
            .topEdge: named("Previous or next", .stepper(forward: Action(.keyCombo, "cmd+right"), backward: Action(.keyCombo, "cmd+left"), step: 0.14)),
        ]),
        // Each key below is in that app's own menus, read on macOS 26. Edges the
        // app doesn't name keep the universal meanings, which already find its
        // zoom and undo.
        AppPack(name: "Mail", bundleIDs: ["com.apple.mail"], bindings: [
            .leftEdge: named("Messages", step("up", "down")),
            .topEdge: named("Mailboxes", step("ctrl+cmd+]", "ctrl+cmd+[")),
        ]),
        AppPack(name: "Preview", bundleIDs: ["com.apple.Preview"], bindings: [
            .topEdge: named("Pages", step("opt+down", "opt+up")),
            .bottomEdge: named("Documents", step("opt+pagedown", "opt+pageup")),
        ]),
        AppPack(name: "Photos", bundleIDs: ["com.apple.Photos"], bindings: [
            .topEdge: named("Photos", step("right", "left")),
        ]),
        AppPack(name: "Books", bundleIDs: ["com.apple.iBooksX"], bindings: [
            .topEdge: named("Pages", step("right", "left")),
        ]),
        AppPack(name: "News", bundleIDs: ["com.apple.news"], bindings: [
            .topEdge: named("Stories", step("cmd+right", "cmd+left")),
            .leftEdge: named("Text size", step("opt+cmd+=", "opt+cmd+-")),
        ]),
        AppPack(name: "Stocks", bundleIDs: ["com.apple.stocks"], bindings: [
            .topEdge: named("Watchlists", step("ctrl+cmd+right", "ctrl+cmd+left")),
        ]),
        AppPack(name: "Voice Memos", bundleIDs: ["com.apple.VoiceMemos"], bindings: [
            .bottomEdge: named("Seek", step("right", "left", 0.06)),
            .topRight: named("Play or pause", .buttons(tap: Action(.keyCombo, "space"))),
        ]),
        AppPack(name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], bindings: [
            .topEdge: named("Sessions", step("cmd+shift+]", "cmd+shift+[")),
            .bottomEdge: named("Back and forward", step("cmd+]", "cmd+[")),
        ]),
        // Figma's zoom lives in its own canvas menu, which macOS can't read, so the
        // universal zoom finds nothing there.
        AppPack(name: "Figma", bundleIDs: ["com.figma.Desktop"], bindings: [
            .leftEdge: named("Zoom", step("cmd+=", "cmd+-", 0.07)),
        ]),
        // The packs below use each app's documented default shortcuts. They
        // haven't been read from the app's menus yet, so check with --audit.
        AppPack(name: "Notion", bundleIDs: ["notion.id"], bindings: [
            .bottomEdge: named("Back and forward", step("cmd+]", "cmd+[")),
            .topLeft: named("Sidebar", .buttons(tap: Action(.keyCombo, "cmd+\\"))),
            .topRight: named("Search", .buttons(tap: Action(.keyCombo, "cmd+p"))),
        ]),
        AppPack(name: "Obsidian", bundleIDs: ["md.obsidian"], bindings: [
            .bottomEdge: named("Back and forward", step("opt+cmd+right", "opt+cmd+left")),
            .topRight: named("Quick switcher", .buttons(tap: Action(.keyCombo, "cmd+o"))),
        ]),
        AppPack(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], bindings: [
            .bottomEdge: named("Back and forward", step("ctrl+cmd+right", "ctrl+cmd+left")),
            .leftEdge: named("Issues", step("cmd+'", "cmd+shift+'")),
            .topLeft: named("Navigator", .buttons(tap: Action(.keyCombo, "cmd+0"))),
            .topRight: named("Run", .buttons(tap: Action(.keyCombo, "cmd+r"), hold: Action(.keyCombo, "cmd+."))),
        ]),
        AppPack(name: "Word", bundleIDs: ["com.microsoft.Word"], bindings: [
            .leftEdge: named("Text size", step("cmd+shift+.", "cmd+shift+,")),
        ]),
        AppPack(name: "Excel", bundleIDs: ["com.microsoft.Excel"], bindings: [
            .topEdge: named("Sheets", step("ctrl+pagedown", "ctrl+pageup")),
        ]),
        AppPack(name: "PowerPoint", bundleIDs: ["com.microsoft.Powerpoint"], bindings: [
            .topEdge: named("Slides", step("pagedown", "pageup")),
            .topRight: named("Slideshow", .buttons(tap: Action(.keyCombo, "cmd+shift+return"))),
        ]),
        AppPack(name: "Photoshop", bundleIDs: ["com.adobe.Photoshop"], bindings: [
            .rightEdge: .semantic(.brushSize),
            .leftEdge: .semantic(.zoom),
        ]),
        AppPack(name: "CapCut", bundleIDs: ["com.lemon.lvoverseas"], bindings: [
            .bottomEdge: .semantic(.timeline),
            .leftEdge: named("Timeline zoom", step("cmd+=", "cmd+-", 0.07)),
            .topRight: named("Play or pause", .buttons(tap: Action(.keyCombo, "space"))),
        ]),
    ]

    /// An edge that sends one key per detent, forward for right or up.
    static func step(_ forward: String, _ backward: String, _ size: Double = 0.14) -> ZoneBinding {
        .stepper(forward: Action(.keyCombo, forward), backward: Action(.keyCombo, backward), step: size)
    }

    /// VS Code and the editors built on it, which keep its default shortcuts.
    public static let codeEditors = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    public static let players = [
        "com.apple.TV", "com.apple.QuickTimePlayerX", "com.apple.podcasts", "com.westbridge.stremio5-mac",
        "org.videolan.vlc", "com.colliderli.iina",
    ]

    /// Slack, Discord and Signal share these. None lists them in its menus.
    static let conversations = named("Conversations", .stepper(forward: Action(.keyCombo, "opt+down"), backward: Action(.keyCombo, "opt+up"), step: 0.14))

    static func named(_ name: String, _ binding: ZoneBinding) -> ZoneBinding {
        var binding = binding
        binding.name = name
        return binding
    }

    /// Sound on the sides, mute and camera on the corners, and nothing that
    /// could fire by accident along the top or bottom during a call.
    static func callEdges(mute: String? = nil, camera: String? = nil) -> [ZoneID: ZoneBinding] {
        var bindings: [ZoneID: ZoneBinding] = [
            .rightEdge: .slider(.volume),
            .leftEdge: .slider(.micVolume),
            .topEdge: ZoneBinding(mode: .off),
            .bottomEdge: ZoneBinding(mode: .off),
        ]
        if let mute { bindings[.topRight] = named("Mute", .buttons(tap: Action(.keyCombo, mute))) }
        if let camera { bindings[.topLeft] = named("Camera", .buttons(tap: Action(.keyCombo, camera))) }
        return bindings
    }

    private static func meeting(_ name: String, _ bundleIDs: [String], mute: String? = nil, camera: String? = nil) -> AppPack {
        AppPack(name: name, bundleIDs: bundleIDs, bindings: callEdges(mute: mute, camera: camera))
    }

    /// Undo means little in a chat, and the bottom edge is where palms rest.
    private static func chat(_ name: String, _ bundleIDs: [String], top: ZoneBinding) -> AppPack {
        AppPack(name: name, bundleIDs: bundleIDs, bindings: [
            .topEdge: top,
            .leftEdge: .semantic(.textSize),
            .bottomEdge: ZoneBinding(mode: .off),
        ])
    }

    public static func pack(forBundleID bundleID: String?) -> AppPack? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }
}

public extension MarginConfig {
    /// A one-line summary of the edges, for the first-launch toast.
    func summary(for context: AppContext) -> String {
        let resolved = resolve(context)
        return [ZoneID.rightEdge, .leftEdge, .bottomEdge, .topEdge]
            .compactMap { resolved[$0]?.binding }
            .filter(\.isActive)
            .map { $0.label.lowercased() }
            .joined(separator: ", ")
    }

    /// Saves one zone as the user's override for an app, creating its profile if needed.
    mutating func setOverride(_ binding: ZoneBinding, zone: ZoneID, bundleID: String, appName: String) {
        if let index = apps.firstIndex(where: { $0.bundleIDs.contains(bundleID) }) {
            apps[index][zone] = binding
        } else {
            apps.append(Profile(name: appName, bundleIDs: [bundleID], bindings: [zone: binding]))
        }
    }
}

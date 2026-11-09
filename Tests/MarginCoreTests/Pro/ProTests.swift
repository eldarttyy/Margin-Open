import Foundation
import Testing
@testable import MarginCore

@Suite struct LayerTests {
    let config = MarginConfig.standard
    let safari = AppContext(bundleID: "com.apple.Safari", name: "Safari", category: .other)

    @Test func unknownAppGetsUniversalMeanings() {
        let resolved = config.resolve(AppContext(bundleID: "com.example.nobody"))
        #expect(resolved[.rightEdge]?.binding.semantic == .scroll)
        #expect(resolved[.leftEdge]?.binding.semantic == .zoom)
        #expect(resolved[.bottomEdge]?.binding.semantic == .undoScrub)
        #expect(resolved[.topEdge]?.binding.semantic == .tabs)
        #expect(resolved[.rightEdge]?.layer == .universal)
    }

    @Test func cornersStayFromTheSystemLayer() {
        #expect(config.resolve(safari)[.topRight]?.layer == .system)
    }

    @Test func finderAndMusicAppsKeepSystemControls() {
        for id in ["com.apple.finder", "com.spotify.client", "com.apple.Music"] {
            #expect(config.resolve(AppContext(bundleID: id))[.rightEdge]?.binding.slider == .volume)
        }
        #expect(config.resolve(AppContext())[.rightEdge]?.layer == .system)
    }

    @Test func smartEdgesOffKeepsVolumeEverywhere() {
        var c = config
        c.smartEdges = false
        #expect(c.resolve(safari)[.rightEdge]?.binding.slider == .volume)
        #expect(c.resolve(AppContext(bundleID: Packs.blender.bundleIDs[0]))[.rightEdge]?.binding.slider == .volume)
    }

    @Test func categoryBeatsUniversal() {
        let video = config.resolve(AppContext(bundleID: "com.example.cut", category: .video))
        #expect(video[.bottomEdge]?.binding.semantic == .timeline)
        #expect(video[.bottomEdge]?.layer == .category)
        #expect(video[.rightEdge]?.binding.semantic == .scroll)
    }

    @Test func blenderChangesEdgesWithItsMode() {
        let id = Packs.blender.bundleIDs[0]
        let sculpt = config.resolve(AppContext(bundleID: id, category: .graphics, mode: "SCULPT"))
        #expect(sculpt[.rightEdge]?.binding.parameter == "brush_size")
        #expect(sculpt[.leftEdge]?.binding.parameter == "brush_strength")
        #expect(sculpt[.bottomEdge]?.binding.parameter == "frame")
        #expect(sculpt[.rightEdge]?.layer == .pack)
        let subdiv = config.resolve(AppContext(bundleID: id, category: .graphics, mode: "SUBDIV"))
        #expect(subdiv[.leftEdge]?.binding.parameter == "subdivision_level")
        #expect(subdiv[.rightEdge]?.binding.parameter == "viewport_zoom")
        let grab = config.resolve(AppContext(bundleID: id, category: .graphics, mode: "GRAB"))
        #expect(grab[.rightEdge]?.binding.semantic == .scroll)
    }

    @Test func everyBlenderEdgeWorksWithoutAReportedMode() {
        // The state right after launch, and for any mode the pack doesn't list.
        for mode in [nil, "OBJECT", "EDIT", "TEXTURE_PAINT"] as [String?] {
            let r = config.resolve(AppContext(bundleID: Packs.blender.bundleIDs[0], mode: mode))
            for zone in [ZoneID.leftEdge, .rightEdge, .topEdge, .bottomEdge] {
                #expect(r[zone]?.layer == .pack, "\(zone) in \(String(describing: mode))")
                #expect(r[zone]?.binding.slider == .plugin, "\(zone) in \(String(describing: mode))")
            }
        }
    }

    @Test func modeOverrideOnlyAppliesInThatMode() {
        var c = config
        let id = Packs.blender.bundleIDs[0]
        var profile = Profile(name: "Blender", bundleIDs: [id])
        profile[.rightEdge, mode: "SCULPT"] = .slider(.volume)
        c.apps = [profile]
        let sculpt = c.resolve(AppContext(bundleID: id, mode: "SCULPT"))
        #expect(sculpt[.rightEdge]?.binding.slider == .volume)
        #expect(sculpt[.rightEdge]?.layer == .user)
        #expect(c.resolve(AppContext(bundleID: id, mode: "OBJECT"))[.rightEdge]?.layer == .pack)
    }

    @Test func addingAnAppChangesNothingUntilAFeatureIsPutOnIt() {
        for id in ["us.zoom.xos", Packs.blender.bundleIDs[0], "com.example.unknown"] {
            var added = config
            added.apps = [Profile(name: "Added", bundleIDs: [id])]
            let context = AppContext(bundleID: id)
            #expect(added.resolve(context) == config.resolve(context), "\(id)")
        }
    }

    @Test func clearingTheLastModeOverrideRemovesTheMode() {
        var profile = Profile(name: "x")
        profile[.rightEdge, mode: "SCULPT"] = .slider(.volume)
        profile[.rightEdge, mode: "SCULPT"] = nil
        #expect(profile.modes.isEmpty)
    }

    @Test func profilesFromBeforeModesStillLoad() throws {
        let json = #"{"id":"7C9F4B0E-9B1B-4E6C-9C6D-0A4E0D2F1A11","name":"Old","bundleIDs":["a"],"bindings":{}}"#
        #expect(try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).modes.isEmpty)
    }

    @Test func userOverrideBeatsEverythingOneZoneAtATime() {
        var c = config
        c.setOverride(.slider(.volume), zone: .rightEdge, bundleID: Packs.blender.bundleIDs[0], appName: "Blender")
        let r = c.resolve(AppContext(bundleID: Packs.blender.bundleIDs[0], mode: "SCULPT"))
        #expect(r[.rightEdge]?.binding.slider == .volume)
        #expect(r[.rightEdge]?.layer == .user)
        #expect(r[.leftEdge]?.binding.parameter == "brush_strength")
    }

    @Test func capsSwapsTheEdgesOnlyWhenEnabled() {
        #expect(config.resolve(safari, capsHeld: true)[.rightEdge]?.binding.semantic == .scroll)
        var c = config
        c.capsLayer = true
        #expect(c.resolve(safari, capsHeld: true)[.rightEdge]?.binding.semantic == .valueUnderPointer)
        #expect(c.resolve(safari, capsHeld: false)[.rightEdge]?.binding.semantic == .scroll)
    }

    @Test func summaryNamesTheEdges() {
        #expect(config.summary(for: safari) == "scroll, zoom, back and forward, tabs")
    }

    @Test func everyPackKeyComboParses() {
        for pack in Packs.all {
            for binding in pack.bindings.values {
                for action in [binding.forward, binding.backward, binding.tap, binding.hold] where action.kind == .keyCombo {
                    #expect(KeyCombo(action.value) != nil, "\(action.value)")
                }
            }
        }
    }
}

@Suite struct SemanticTests {
    private func items(_ titles: String...) -> [MenuEntry<Int>] {
        titles.enumerated().map { MenuEntry(path: ["View", $1], title: $1, handle: $0) }
    }

    @Test func matchesBothDirections() throws {
        let match = try #require(MenuMatcher.match(.zoom, in: items("Actual Size", "Zoom In", "Zoom Out")))
        #expect(match.forward.title == "Zoom In")
        #expect(match.backward.title == "Zoom Out")
    }

    @Test func ignoresCaseAndEllipsis() {
        #expect(MenuMatcher.match(.tabs, in: items("show next tab…", "SHOW PREVIOUS TAB")) != nil)
    }

    @Test func oneDirectionAloneIsNoMatch() {
        #expect(MenuMatcher.match(.zoom, in: items("Zoom In")) == nil)
    }

    @Test func findsAnyCommandByTitleOrPath() {
        let list = [MenuEntry(path: ["File", "Export", "PNG…"], title: "PNG…", handle: 1),
                    MenuEntry(path: ["Edit", "Export", "PNG"], title: "PNG", handle: 2),
                    MenuEntry(path: ["View", "Zoom In"], title: "Zoom In", handle: 3)]
        #expect(MenuMatcher.find("zoom in", in: list)?.handle == 3)
        #expect(MenuMatcher.find("View > Zoom In", in: list)?.handle == 3)
        #expect(MenuMatcher.find("Edit > Export > PNG", in: list)?.handle == 2)
        #expect(MenuMatcher.find("File > Zoom In", in: list) == nil)
        #expect(MenuMatcher.find("", in: list) == nil)
    }

    @Test func actionsWithoutMenusNeverMatch() {
        #expect(MenuMatcher.match(.scroll, in: items("Scroll")) == nil)
    }

    @Test func everyDiscreteActionHasAWayToRun() {
        for action in SemanticAction.allCases where !action.isContinuous {
            #expect(action.keys != nil, "\(action)")
            #expect(KeyCombo(action.keys!.forward) != nil && KeyCombo(action.keys!.backward) != nil, "\(action)")
        }
    }

    @Test func detentsTickOnceWhenPassed() {
        #expect(Detents.crossed(from: 9, to: 11, detents: [10]))
        #expect(Detents.crossed(from: 11, to: 9, detents: [10]))
        #expect(Detents.crossed(from: 9, to: 10, detents: [10]))
        #expect(!Detents.crossed(from: 10, to: 11, detents: [10]))
        #expect(!Detents.crossed(from: 11, to: 12, detents: [10]))
        #expect(!Detents.crossed(from: 10, to: 10, detents: [10]))
    }

    @Test func keyComboTextRoundTrips() throws {
        let text = try #require(KeyCombo.text(keyCode: 30, command: true, shift: true, option: false, control: false))
        let combo = try #require(KeyCombo(text))
        #expect(combo.keyCode == 30 && combo.command && combo.shift)
    }
}

@Suite struct PluginTests {
    @Test func decodesReportsAndFillsDefaults() throws {
        let json = #"{"app":"blender","mode":"SCULPT","parameters":{"brush_size":{"value":42,"min":1,"max":500,"unit":"px","integer":true}}}"#
        let report = try #require(PluginReport.decode(Data(json.utf8)))
        #expect(report.mode == "SCULPT")
        let p = try #require(report.parameters["brush_size"])
        #expect(p.format(42) == "42 px")
        #expect(!p.relative && p.detents.isEmpty)
    }

    @Test func rejectsGarbage() {
        #expect(PluginReport.decode(Data("brush_size 42".utf8)) == nil)
    }

    @Test func fractionClampsAndHandlesEmptyRanges() {
        let p = PluginParameter(value: 0, min: 10, max: 20)
        #expect(p.fraction(15) == 0.5)
        #expect(p.fraction(99) == 1)
        #expect(PluginParameter(value: 0, min: 5, max: 5).fraction(5) == nil)
    }
}


@Suite struct FeatureCatalogTests {
    private let blender = FeatureCatalog.features(forBundleID: Packs.blender.bundleIDs[0])

    @Test func blenderListsItsOwnFeaturesFirstThenSystem() throws {
        #expect(blender.first?.group == "Blender")
        #expect(blender.contains { $0.title == "Output volume" })
        #expect(!FeatureCatalog.features(forBundleID: "com.apple.Safari").contains { $0.group.contains("Blender") })
    }

    @Test func everyBuiltInShortcutParses() {
        for feature in blender {
            if case .action(let action) = feature.payload, action.kind == .keyCombo {
                #expect(KeyCombo(action.value) != nil, "\(feature.title)")
            }
        }
    }

    @Test func everyAppCatalogParsesAndHasUniqueIDs() {
        for entry in AppShortcuts.all {
            #expect(!entry.items.isEmpty, "\(entry.name)")
            for id in entry.bundleIDs {
                let features = FeatureCatalog.appFeatures(forBundleID: id)
                #expect(Set(features.map(\.id)).count == features.count, "\(entry.name)")
                for feature in features {
                    if case .action(let action) = feature.payload, action.kind == .keyCombo {
                        #expect(KeyCombo(action.value) != nil, "\(entry.name): \(feature.title)")
                    }
                }
            }
        }
    }

    @Test func popularAppsListTheirFeaturesBeforeSystemOnes() {
        let safari = FeatureCatalog.features(forBundleID: "com.apple.Safari")
        #expect(safari.first?.group == "Safari shortcuts")
        #expect(FeatureCatalog.search("refresh", in: safari).first?.title == "Reload page")
        #expect(FeatureCatalog.appFeatures(forBundleID: "com.example.unknown").isEmpty)
    }

    @Test func idsAreUnique() {
        #expect(Set(blender.map(\.id)).count == blender.count)
    }

    @Test func searchMatchesKeywordsAndPutsTitlesFirst() {
        #expect(FeatureCatalog.search("brush", in: blender).prefix(2).map(\.title) == ["Brush radius", "Brush strength"])
        #expect(FeatureCatalog.search("grab", in: blender).first?.title == "Move")
        #expect(FeatureCatalog.search("sculpt size", in: blender).first?.title == "Brush radius")
        #expect(FeatureCatalog.search("zzzz", in: blender).isEmpty)
        #expect(FeatureCatalog.search("  ", in: blender).count == blender.count)
    }

    @Test func menuFeaturesKeepOnlyCommands() {
        let features = FeatureCatalog.menuFeatures([
            ["Apple", "About This Mac"], ["File"], ["File", "Export"], ["File", "Export", "PNG"], ["View", "Zoom In"],
        ])
        #expect(features.map(\.title) == ["PNG", "Zoom In"])
        #expect(features[0].payload == .action(Action(.menuItem, "File > Export > PNG")))
        #expect(features[0].group == "File menu")
    }

    @Test func slotsFollowTheZone() throws {
        let slider = try #require(blender.first { $0.title == "Brush radius" })
        let command = try #require(blender.first { $0.title == "Undo" })
        #expect(slider.slots(on: .rightEdge) == [.whole])
        #expect(slider.slots(on: .topLeft).isEmpty)
        #expect(command.slots(on: .rightEdge) == [.forward, .backward])
        #expect(command.slots(on: .topLeft) == [.tap, .doubleTap, .hold])
    }

    @Test func addingFillsBothDirectionsOfAnEdge() throws {
        let undo = try #require(blender.first { $0.title == "Undo" })
        let redo = try #require(blender.first { $0.title == "Redo" })
        let binding = ZoneBinding.slider(.volume).adding(redo, slot: .forward).adding(undo, slot: .backward)
        #expect(binding.mode == .stepper)
        #expect(binding.forward.value == "redo")
        #expect(binding.backward.value == "undo")
    }

    @Test func addingToACornerKeepsItsOtherGestures() throws {
        let undo = try #require(blender.first { $0.title == "Undo" })
        let render = try #require(blender.first { $0.title == "Render image" })
        let binding = ZoneBinding().adding(undo, slot: .tap).adding(render, slot: .hold)
        #expect(binding.mode == .buttons)
        #expect(binding.tap.value == "undo")
        #expect(binding.hold.value == "render_image")
    }

    @Test func addingASliderReplacesTheZoneAndNamesIt() throws {
        let zoom = try #require(blender.first { $0.title == "Viewport zoom" })
        let binding = ZoneBinding.buttons(tap: Action(.playPause)).adding(zoom, slot: .whole)
        #expect(binding.mode == .slider)
        #expect(binding.parameter == "viewport_zoom")
        #expect(binding.label == "Viewport zoom")
    }
}

@Suite struct FeatureRankingTests {
    private func shelves(_ bundleID: String?, menus: [[String]] = [], zone: ZoneID) -> FeatureShelves {
        FeatureCatalog.shelves(
            app: FeatureCatalog.appFeatures(forBundleID: bundleID), menus: FeatureCatalog.menuFeatures(menus),
            system: FeatureCatalog.system, zone: zone)
    }

    @Test func blenderEdgesLeadWithSliders() {
        let best = shelves(Packs.blender.bundleIDs[0], zone: .rightEdge).best
        #expect(best.count == 5)
        let commands = best.filter { $0.slots(on: .rightEdge) != [.whole] }
        #expect(commands.isEmpty)
    }

    @Test func appsWithoutSlidersLeadWithOnesThatSuitThem() {
        func best(_ id: String, _ zone: ZoneID) -> [String] {
            FeatureCatalog.shelves(
                app: FeatureCatalog.appFeatures(forBundleID: id), menus: [], system: FeatureCatalog.system, zone: zone,
                edgePicks: FeatureCatalog.edgePicks(forBundleID: id)).best.map(\.title)
        }
        #expect(Array(best("com.spotify.client", .rightEdge).prefix(2)) == ["Output volume", "Skip tracks"])
        #expect(best("com.apple.Safari", .rightEdge).first == "Scroll")
        #expect(best("com.spotify.client", .topRight).first == "Play or pause")
    }

    @Test func cornersOnlyOfferCommands() {
        let best = shelves(Packs.blender.bundleIDs[0], zone: .topLeft).best
        #expect(best.first?.title == "X-ray")
        let unusable = best.filter { $0.slots(on: .topLeft).isEmpty }
        #expect(unusable.isEmpty)
    }

    @Test func riskyCommandsAreNeverRecommended() {
        let menus = [["File", "Quit Thing"], ["File", "Delete"], ["Edit", "Undo"], ["File", "Empty Trash…"], ["File", "Log Out Eldar"]]
        let result = shelves("com.example.none", menus: menus, zone: .topLeft)
        #expect(result.best.first?.title == "Undo")
        let risky = result.best.filter(\.isRisky)
        #expect(risky.isEmpty)
        #expect(result.menus.count == 4)
        let safe = result.menus.filter { !$0.isRisky }
        #expect(safe.isEmpty)
    }

    @Test func aFewPicksThenTheRestAreFolded() {
        let menus = (0..<300).map { ["Tools", "Command \($0)"] }
        let result = shelves("com.example.none", menus: menus, zone: .topLeft)
        #expect(result.best.count == 5)
        #expect(result.menus.count == 300)
    }

    @Test func nothingShowsTwice() {
        let result = shelves("com.spotify.client", menus: [["Playback", "Next song"], ["Edit", "Undo"]], zone: .topRight)
        let all = result.best + result.more + result.everywhere + result.menus
        #expect(Set(all.map(\.id)).count == all.count)
        let titles = result.menus.map(\.title)
        #expect(!titles.contains("Next song"))
    }

    @Test func missingHardwareIsLeftOut() {
        let result = FeatureCatalog.shelves(app: [], menus: [], system: FeatureCatalog.system, zone: .leftEdge, hidden: ["system.keyboardBacklight"])
        let ids = (result.best + result.everywhere).map(\.id)
        #expect(!ids.contains("system.keyboardBacklight"))
    }

    @Test func personalMenusAreSkipped() {
        let found = FeatureCatalog.menuFeatures([
            ["File", "Open Recent", "taxes.pdf"], ["History", "bank.com"], ["Bookmarks", "Mail"],
            ["Help", "Search"], ["App", "Services", "Make Note"], ["File", "Save"],
        ])
        #expect(found.map(\.title) == ["Save"])
    }

    @Test func searchPutsRiskyLast() {
        let features = FeatureCatalog.menuFeatures([["File", "Close Window"], ["File", "Close-up view"], ["View", "Closer"]])
        #expect(FeatureCatalog.search("close", in: features).last?.isRisky == true)
    }
}

@Suite struct BlenderLinkTests {
    private let launched = Date(timeIntervalSince1970: 1000)

    private func status(connected: Bool = false, enabled: Bool = true, written: Date?, launched: Date?, hasApp: Bool = true, now: Double = 1010) -> BlenderLink {
        BlenderLink.status(hasApp: hasApp, enabled: enabled, connected: connected, connectorWritten: written, launched: launched, now: Date(timeIntervalSince1970: now))
    }

    @Test func aClosedBlenderAsksForNothing() {
        #expect(status(written: launched, launched: nil) == .closed)
        #expect(status(written: nil, launched: nil) == .closed)
        #expect(!BlenderLink.closed.needsAttention)
    }

    @Test func aSlowStartIsNotAFailure() {
        #expect(status(written: launched.addingTimeInterval(-5), launched: launched) == .starting)
        #expect(!BlenderLink.starting.needsAttention)
    }

    @Test func aBusyBlenderAsksForNothing() {
        #expect(status(written: launched.addingTimeInterval(-5), launched: launched, now: 2000) == .busy)
        #expect(!BlenderLink.busy.needsAttention)
    }

    @Test func onlyAConnectorNewerThanBlenderAsksForARestart() {
        #expect(status(written: launched.addingTimeInterval(5), launched: launched) == .restartNeeded)
        #expect(BlenderLink.restartNeeded.needsAttention)
    }

    @Test func noConnectorWhileRunningIsAFailure() {
        #expect(status(written: nil, launched: launched) == .failed)
    }

    @Test func connectedWinsAndRemovalIsRespected() {
        #expect(status(connected: true, written: nil, launched: launched) == .connected)
        #expect(status(enabled: false, written: nil, launched: launched) == .off)
        #expect(status(written: nil, launched: nil, hasApp: false) == .notInstalled)
    }
}

@Suite struct AppConnectionTests {
    @Test func eachKindOfApp() {
        #expect(AppConnection.of(bundleID: Packs.blender.bundleIDs[0]) == .connector)
        #expect(AppConnection.of(bundleID: "com.spotify.client") == .ready)
        #expect(AppConnection.of(bundleID: "com.example.none") == nil)
        guard case .midi(let steps)? = AppConnection.of(bundleID: "com.ableton.live") else {
            Issue.record("Live should need the MIDI step")
            return
        }
        #expect(steps.count == 3)
    }
}

@Suite struct PopularAppTests {
    private let config = MarginConfig.standard
    private func resolved(_ bundleID: String, site: String? = nil) -> [ZoneID: ZoneBinding] {
        config.bindings(for: AppContext(bundleID: bundleID, site: site))
    }
    private func menu(_ titles: String...) -> [MenuEntry<Int>] {
        titles.enumerated().map { MenuEntry(path: ["Window", $1], title: $1, handle: $0) }
    }

    @Test func eachMeetingAppMutesWithItsOwnShortcut() {
        #expect(resolved("us.zoom.xos")[.topRight]?.tap == Action(.keyCombo, "cmd+shift+a"))
        #expect(resolved("com.microsoft.teams2")[.topRight]?.tap == Action(.keyCombo, "cmd+shift+m"))
    }

    @Test func callsKeepEdgesThatCouldFireByAccidentOff() {
        let zoom = resolved("us.zoom.xos")
        #expect(zoom[.leftEdge]?.slider == .micVolume)
        #expect(zoom[.topEdge]?.isActive == false)
        #expect(zoom[.bottomEdge]?.isActive == false)
    }

    @Test func browsersGoBackInsteadOfUndoing() {
        for id in Sites.browsers {
            #expect(resolved(id)[.bottomEdge]?.backward == Action(.keyCombo, "cmd+["), "\(id)")
            #expect(resolved(id)[.topEdge]?.semantic == .tabs, "\(id)")
        }
    }

    @Test func whatsAppsInvisibleMarksDontHideItsMenus() throws {
        let match = try #require(MenuMatcher.match(.tabs, in: menu("\u{200E}Next Chat", "\u{200E}Previous Chat")))
        #expect(match.forward.handle == 0)
    }

    @Test func aDisabledTabCommandLeavesTheRealOneAvailable() throws {
        let found = try #require(MenuMatcher.options(.tabs, in: menu(
            "Show Next Tab", "Show Previous Tab", "Go to Next Conversation", "Go to Previous Conversation")))
        #expect(found.forward.map(\.title) == ["Show Next Tab", "Go to Next Conversation"])
    }

    @Test func plainLettersCountAsTypingButCommandsDont() throws {
        for text in ["k", "space", "shift+."] { #expect(try #require(KeyCombo(text)).typesText, "\(text)") }
        for text in ["cmd+d", "left", "return", "tab", "f8", "opt+down"] { #expect(try !#require(KeyCombo(text)).typesText, "\(text)") }
    }

    @Test func everyPackAndSiteShortcutParses() {
        func check(_ binding: ZoneBinding) {
            for action in [binding.tap, binding.hold, binding.doubleTap, binding.forward, binding.backward] where action.kind == .keyCombo {
                #expect(KeyCombo(action.value) != nil, "\(action.value)")
            }
        }
        Packs.all.flatMap(\.bindings.values).forEach(check)
        Sites.all.flatMap(\.bindings.values).forEach(check)
        for feature in Sites.all.flatMap(\.features) {
            if case .action(let action) = feature.payload { #expect(KeyCombo(action.value) != nil, "\(feature.id)") }
        }
    }

    @Test func noAppIsInTwoPacksOrListedTwice() {
        let packed = Packs.all.flatMap(\.bundleIDs)
        #expect(Set(packed).count == packed.count)
        #expect(Set(Sites.all.map(\.id)).count == Sites.all.count)
    }

    @Test func appleAppsStepThroughWhatTheyShow() {
        #expect(resolved("com.apple.mail")[.leftEdge]?.forward == Action(.keyCombo, "up"))
        #expect(resolved("com.apple.mail")[.topEdge]?.forward == Action(.keyCombo, "ctrl+cmd+]"))
        #expect(resolved("com.apple.Preview")[.topEdge]?.forward == Action(.keyCombo, "opt+down"))
        #expect(resolved("com.apple.stocks")[.topEdge]?.backward == Action(.keyCombo, "ctrl+cmd+left"))
        #expect(resolved("com.apple.VoiceMemos")[.bottomEdge]?.forward == Action(.keyCombo, "right"))
        #expect(resolved("com.anthropic.claudefordesktop")[.topEdge]?.forward == Action(.keyCombo, "cmd+shift+]"))
    }

    @Test func aPackKeepsTheUniversalEdgesItDoesntName() {
        let mail = resolved("com.apple.mail")
        #expect(mail[.rightEdge]?.semantic == .scroll)
        #expect(mail[.bottomEdge]?.semantic == .undoScrub)
        #expect(resolved("com.apple.Photos")[.leftEdge]?.semantic == .zoom)
    }

    /// A key on an edge should also be in that app's list, so the picker can name it.
    @Test func newPackKeysAreInTheirAppsShortcutList() {
        let arrows: Set<String> = ["up", "down", "left", "right", "space"]
        for name in ["Preview", "News", "Stocks", "Claude", "Figma"] {
            let pack = Packs.all.first { $0.name == name }!
            let listed = AppShortcuts.entry(forBundleID: pack.bundleIDs[0])?.items.map { KeyCombo($0.combo) } ?? []
            for binding in pack.bindings.values {
                for action in [binding.forward, binding.backward, binding.tap] where action.kind == .keyCombo && !arrows.contains(action.value) {
                    #expect(listed.contains(KeyCombo(action.value)), "\(name): \(action.value)")
                }
            }
        }
    }

    @Test func newBrowsersGetSitePacks() {
        for id in ["company.thebrowser.dia", "app.zen-browser.zen", "ai.perplexity.comet"] {
            #expect(Sites.browsers.contains(id))
            #expect(resolved(id, site: "youtube")[.bottomEdge]?.forward == Action(.keyCombo, "right"), "\(id)")
        }
    }

    @Test func everyAppWithAPackIsReadyMade() {
        for id in Packs.all.flatMap(\.bundleIDs) {
            #expect(AppConnection.of(bundleID: id) != nil, "\(id)")
        }
    }
}

@Suite struct SiteTests {
    private func id(_ address: String) -> String? { Sites.pack(address: address)?.id }

    @Test func readsAddressesHoweverABrowserShowsThem() {
        #expect(id("youtube.com/watch?v=abc") == "youtube")
        #expect(id("https://www.youtube.com/watch?v=abc") == "youtube")
        #expect(id("YouTube.com") == "youtube")
        #expect(id("m.youtube.com:443/feed") == "youtube")
    }

    @Test func aLookalikeAddressIsNotTheSite() {
        #expect(id("youtube.com.example.org/watch") == nil)
        #expect(id("notyoutube.com") == nil)
        #expect(id("example.org/youtube.com") == nil)
        #expect(id("youtube.com@example.org") == nil)
    }

    @Test func aSearchBeingTypedIsNotASite() {
        #expect(id("youtube") == nil)
        #expect(id("how to use youtube.com") == nil)
        #expect(id("") == nil)
    }

    @Test func oneHostCanServeSeveralProducts() {
        #expect(id("docs.google.com/spreadsheets/d/1") == "sheets")
        #expect(id("docs.google.com/document/d/1") == "docs")
        // Safari shows only the domain unless asked for more.
        #expect(id("docs.google.com") == "docs")
        #expect(id("docs.google.com/presentation/d/1/edit") == "slides")
        #expect(id("docs.google.com/forms/d/1/edit") == "forms")
        #expect(id("figma.com/board/abc/Retro") == "figjam")
        #expect(id("figma.com/slides/abc") == "figmaslides")
        #expect(id("www.figma.com/design/abc") == "figma")
    }

    @Test func youTubeSubdomainsGetTheirOwnPacks() {
        #expect(id("music.youtube.com/watch?v=abc") == "youtubemusic")
        #expect(id("studio.youtube.com/channel/abc") == "youtubestudio")
        #expect(id("tv.youtube.com/watch/abc") == "youtube")
        let studio = MarginConfig.standard.bindings(for: AppContext(bundleID: "com.google.Chrome", site: "youtubestudio"))
        #expect(studio[.bottomEdge]?.forward == Action(.keyCombo, "cmd+]"))
        let music = MarginConfig.standard.bindings(for: AppContext(bundleID: "com.google.Chrome", site: "youtubemusic"))
        #expect(music[.topEdge]?.forward == Action(.nextTrack))
    }

    @Test func aSiteChangesOnlyTheEdgesItCaresAbout() {
        let youtube = MarginConfig.standard.bindings(for: AppContext(bundleID: "com.google.Chrome", site: "youtube"))
        #expect(youtube[.bottomEdge]?.forward == Action(.keyCombo, "right"))
        #expect(youtube[.rightEdge]?.semantic == .scroll)
    }

    @Test func aSavedSiteOverrideBeatsTheAppAndThePack() {
        var config = MarginConfig.standard
        config.setOverride(.slider(.brightness), zone: .leftEdge, bundleID: "com.google.Chrome", appName: "Chrome")
        config.setOverride(.slider(.micVolume), zone: .leftEdge, bundleID: Sites.profileID("youtube"), appName: "YouTube")
        let resolved = config.resolve(AppContext(bundleID: "com.google.Chrome", site: "youtube"))[.leftEdge]
        #expect(resolved?.binding.slider == .micVolume)
        #expect(resolved?.layer == .user)
    }

    @Test func smartEdgesOffLeavesSitesAlone() {
        var config = MarginConfig.standard
        config.smartEdges = false
        let context = AppContext(bundleID: "com.google.Chrome", site: "youtube")
        #expect(config.bindings(for: context)[.bottomEdge] == nil)
    }

    /// Chrome hides a page's text boxes from Accessibility, so the typing guard
    /// can't protect these. A plain key here would land in comments and emails.
    @Test func noBuiltInSiteEdgeSendsAKeyThatTypes() {
        for site in Sites.all {
            for (zone, binding) in site.bindings {
                for action in [binding.tap, binding.hold, binding.doubleTap, binding.forward, binding.backward] where action.kind == .keyCombo {
                    #expect(KeyCombo(action.value)?.typesText == false, "\(site.name) \(zone): \(action.value)")
                }
            }
        }
    }

    @Test func aSiteProfileListsItsFeatures() {
        let features = FeatureCatalog.appFeatures(forBundleID: Sites.profileID("meet"))
        #expect(features.first?.group == "Google Meet shortcuts")
        #expect(FeatureCatalog.appFeatures(forBundleID: "site:nothing").isEmpty)
    }
}

// Real `hidutil property --get UserKeyMapping` output, one entry per keyboard service.
private let capsTable = """
RegistryID  Key                   Value
10000053c   UserKeyMapping   (
        {
        HIDKeyboardModifierMappingDst = 30064771181;
        HIDKeyboardModifierMappingSrc = 30064771129;
    }
)
100000928   UserKeyMapping   (
        {
        HIDKeyboardModifierMappingDst = 30064771181;
        HIDKeyboardModifierMappingSrc = 30064771129;
    }
)
100000ac1   UserKeyMapping   (null)
"""

@Test func recognizesMarginsOwnRemap() {
    #expect(CapsMapping.state(of: capsTable) == .margin)
}

@Test func anEmptyTableIsEmpty() {
    #expect(CapsMapping.state(of: "RegistryID  Key  Value\n10000053c   UserKeyMapping   (\n)\n100000ac1   UserKeyMapping   (null)\n") == .empty)
}

@Test func anotherToolsRemapIsLeftAlone() {
    let extra = capsTable + """

    100000999   UserKeyMapping   (
            {
            HIDKeyboardModifierMappingDst = 30064771300;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """
    #expect(CapsMapping.state(of: extra) == .other)
}

@Test func aHugeReportedValueStillFormats() {
    let parameter = PluginParameter(value: 0, min: 0, max: 1, unit: "px", integer: true)
    #expect(parameter.format(42.4) == "42 px")
    #expect(parameter.format(1e300).hasSuffix(" px"))
}

@Suite struct CodeEditorTests {
    private let config = MarginConfig.standard

    @Test func vsCodeAndItsForksGetTheEditorPack() {
        for id in Packs.codeEditors {
            let r = config.resolve(AppContext(bundleID: id))
            #expect(r[.topEdge]?.binding.name == "Editors", "\(id)")
            #expect(r[.bottomEdge]?.binding.name == "Back and forward", "\(id)")
            #expect(r[.rightEdge]?.binding.semantic == .scroll, "\(id)")
        }
    }

    /// VS Code's ctrl+tab opens a recently-used picker instead of moving one tab along.
    @Test func editorsStepInTabOrderNotRecentlyUsed() {
        let top = Packs.pack(forBundleID: "com.microsoft.VSCode")?.bindings[.topEdge]
        #expect(top?.forward.value == "opt+cmd+right")
        #expect(top?.backward.value == "opt+cmd+left")
    }

    /// The editor has focus most of the time, so nothing on an edge may type into code.
    @Test func noEdgeTypesIntoTheEditor() throws {
        let pack = try #require(Packs.pack(forBundleID: "com.microsoft.VSCode"))
        for (zone, binding) in pack.bindings {
            for action in [binding.tap, binding.hold, binding.doubleTap, binding.forward, binding.backward] where action.kind == .keyCombo {
                #expect(KeyCombo(action.value)?.typesText == false, "\(zone): \(action.value)")
            }
        }
    }

    /// Palms rest on the bottom corners while typing.
    @Test func bottomCornersStayFree() throws {
        let pack = try #require(Packs.pack(forBundleID: "com.microsoft.VSCode"))
        #expect(pack.bindings[.bottomLeft] == nil && pack.bindings[.bottomRight] == nil)
    }

    @Test func everyShortcutParsesAndTitlesAreUnique() throws {
        let entry = try #require(AppShortcuts.entry(forBundleID: "com.microsoft.VSCode"))
        for item in entry.items { #expect(KeyCombo(item.combo) != nil, "\(item.combo)") }
        #expect(Set(entry.items.map(\.title)).count == entry.items.count)
        #expect(AppShortcuts.entry(forBundleID: "com.exafunction.windsurf")?.name == "VS Code")
    }

    @Test func pickerOffersVSCodeFeatures() {
        let titles = FeatureCatalog.appFeatures(forBundleID: "com.microsoft.VSCode").map(\.title)
        for t in ["Go back", "Next problem", "Toggle terminal", "Command palette"] { #expect(titles.contains(t), "\(t)") }
    }
}

@Suite struct SpotifyTests {
    private let titles = FeatureCatalog.appFeatures(forBundleID: "com.spotify.client").map(\.title)

    @Test func likingASongCanBeFoundBySearch() throws {
        let entry = try #require(AppShortcuts.entry(forBundleID: "com.spotify.client"))
        let like = try #require(entry.items.first { $0.title == "Like or unlike song" })
        #expect(like.combo == "opt+shift+b")
        for word in ["favorite", "heart", "liked"] { #expect(like.keywords.contains(word)) }
    }

    @Test func everyShortcutParsesAndTitlesAreUnique() throws {
        let entry = try #require(AppShortcuts.entry(forBundleID: "com.spotify.client"))
        for item in entry.items { #expect(KeyCombo(item.combo) != nil, "\(item.combo)") }
        #expect(Set(entry.items.map(\.title)).count == entry.items.count)
    }

    @Test func pickerListsLibraryAndPlaybackFeatures() {
        for t in ["Like or unlike song", "Go to Liked Songs", "Shuffle", "Repeat", "Go to Queue"] { #expect(titles.contains(t), "\(t)") }
    }
}

@Suite struct ScreenControlTests {
    private let spotify = "com.spotify.client"

    @Test func targetsSurviveBeingSaved() throws {
        let target = ScreenTarget(bundleID: spotify, kind: .button, label: "Add to Liked Songs | now")
        #expect(ScreenTarget(target.text) == target)
        #expect(ScreenTarget("press|com.x|button|") == nil)
        #expect(ScreenTarget("jump|com.x|button|Go") == nil)
        #expect(ScreenTarget("press||button|Go") == nil)
    }

    @Test func labelsLoseCountsAndShortcutHints() {
        #expect(ScreenControl.key("Source Control (⌃⇧G) - 93 pending changes") == "source control")
        #expect(ScreenControl(kind: .tab, label: "Problems (⇧⌘M)").title == "Problems")
        #expect(ScreenControl(kind: .button, label: "Go Back (⌃-)").title == "Go Back")
        #expect(ScreenControl(kind: .tab, label: "icon view").title == "Icon view")
        #expect(ScreenControl(kind: .popUp, label: "Model: Opus 5.5 Medium").title == "Model")
    }

    @Test func findsAControlAfterItsLabelChanges() {
        let saved = ScreenTarget(bundleID: "com.microsoft.VSCode", kind: .tab, label: "Source Control (⌃⇧G) - 93 pending changes")
        let now = [
            ScreenControl(kind: .tab, label: "Explorer (⇧⌘E)"),
            ScreenControl(kind: .tab, label: "Source Control (⌃⇧G) - 4 pending changes"),
        ]
        #expect(saved.match(in: now) == 1)
    }

    @Test func aControlThatShowsItsSettingIsFoundByName() {
        let saved = ScreenTarget(bundleID: "com.anthropic.claudefordesktop", kind: .popUp, label: "Model: Opus 5.5 Medium")
        let now = [ScreenControl(kind: .popUp, label: "Permissions: Auto"), ScreenControl(kind: .popUp, label: "Model: Sonnet 5.5 High")]
        #expect(saved.match(in: now) == 1)
    }

    @Test func countsDropOutAndOnlyTheFirstLineCounts() {
        #expect(ScreenControl.key("Import 59 Claude Code CLI sessions") == ScreenControl.key("Import 3 Claude Code CLI sessions"))
        #expect(ScreenControl(kind: .popUp, label: "Open Claude\nHas access to this site").title == "Open Claude")
    }

    @Test func exactLabelBeatsALooseOne() {
        let saved = ScreenTarget(bundleID: spotify, kind: .button, label: "Play")
        let now = [ScreenControl(kind: .button, label: "Play (space)"), ScreenControl(kind: .button, label: "Play")]
        #expect(saved.match(in: now) == 1)
    }

    @Test func aToggleThatBecameAButtonIsStillFound() {
        let saved = ScreenTarget(bundleID: spotify, kind: .toggle, label: "Shuffle")
        #expect(saved.match(in: [ScreenControl(kind: .slider, label: "Shuffle"), ScreenControl(kind: .button, label: "Shuffle")]) == 1)
    }

    @Test func aMissingControlIsNotGuessed() {
        let saved = ScreenTarget(bundleID: spotify, kind: .button, label: "Lyrics")
        #expect(saved.match(in: [ScreenControl(kind: .button, label: "Lyrical mode")]) == nil)
        #expect(saved.match(in: [ScreenControl(kind: .slider, label: "Lyrics")]) == nil)
    }

    @Test func windowButtonsAreLeftOut() {
        #expect(ScreenControl.Kind(role: "AXButton", subrole: "AXCloseButton") == nil)
        #expect(ScreenControl.Kind(role: "AXButton", subrole: "AXFullScreenButton") == nil)
        #expect(ScreenControl.Kind(role: "AXCheckBox", subrole: "AXToggleButton") == .toggle)
        #expect(ScreenControl.Kind(role: "AXRadioButton", subrole: "AXTabButton") == .tab)
        #expect(ScreenControl.Kind(role: "AXStaticText", subrole: "") == nil)
    }

    @Test func featuresAreSearchableAndDeduplicated() throws {
        let controls = [
            ScreenControl(kind: .button, label: "Add to Liked Songs"),
            ScreenControl(kind: .button, label: "Add to Liked Songs"),
            ScreenControl(kind: .slider, label: "Change volume"),
            ScreenControl(kind: .link, label: "Home"),
            ScreenControl(kind: .button, label: "  "),
        ]
        let features = FeatureCatalog.screenFeatures(bundleID: spotify, controls: controls)
        #expect(features.map(\.title) == ["Add to Liked Songs", "Change volume", "Home"])
        let like = try #require(FeatureCatalog.search("liked", in: features).first)
        guard case .action(let action) = like.payload else { Issue.record("not an action"); return }
        #expect(action.kind == .screenControl && ScreenTarget(action.value)?.bundleID == spotify)
    }

    @Test func aSliderTakesTheWholeEdgeAndAButtonACorner() throws {
        let features = FeatureCatalog.screenFeatures(bundleID: spotify, controls: [
            ScreenControl(kind: .slider, label: "Change volume"), ScreenControl(kind: .button, label: "Next"),
        ])
        #expect(features[0].slots(on: .rightEdge) == [.whole])
        #expect(features[0].slots(on: .topRight).isEmpty)
        #expect(features[1].slots(on: .topRight) == [.tap, .doubleTap, .hold])
        guard case .binding(let binding) = features[0].payload else { Issue.record("not a binding"); return }
        #expect(ScreenTarget(binding.forward.value)?.verb == .increment)
        #expect(ScreenTarget(binding.backward.value)?.verb == .decrement)
    }

    @Test func aBrowserPagesLinksStayOut() {
        let features = FeatureCatalog.screenFeatures(bundleID: "com.google.Chrome", controls: [
            ScreenControl(kind: .link, label: "Read more"), ScreenControl(kind: .button, label: "Reload"),
        ], isBrowser: true)
        #expect(features.map(\.title) == ["Reload"])
    }

    @Test func riskyControlsAreFlagged() {
        let features = FeatureCatalog.screenFeatures(bundleID: spotify, controls: [ScreenControl(kind: .button, label: "Delete playlist")])
        #expect(features.first?.isRisky == true)
    }
}

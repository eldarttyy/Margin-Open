import Foundation
import Testing
@testable import MarginCore

@Suite struct EdgeGuideTests {
    let config = MarginConfig.standard

    @Test func vsCodeSaysWhatEachEdgeDoes() {
        let rows = config.guide(for: AppContext(bundleID: "com.microsoft.VSCode", category: .developer))
        let byZone = Dictionary(uniqueKeysWithValues: rows.map { ($0.zone, $0) })
        #expect(byZone[.topEdge]?.what == "Editors")
        #expect(byZone[.topEdge]?.how == "→ Next editor   ← Previous editor")
        #expect(byZone[.leftEdge]?.how == "↑ Next problem   ↓ Previous problem")
        #expect(byZone[.rightEdge]?.how == "Slide ↑↓")
        #expect(byZone[.topLeft]?.how == "Tap: Toggle sidebar")
        #expect(byZone[.topEdge]?.layer == .pack)
        #expect(rows.first?.zone == .rightEdge)
    }

    @Test func unknownAppStillGetsAGuide() {
        let rows = config.guide(for: AppContext(bundleID: "com.example.nobody"))
        #expect(rows.map(\.zone) == [.rightEdge, .leftEdge, .topEdge, .bottomEdge, .topLeft, .topRight])
        #expect(rows.first { $0.zone == .bottomEdge }?.how == "→ Redo   ← Undo")
        #expect(rows.first { $0.zone == .topRight }?.how == "Tap: Play / pause   Hold: Mute output")
    }

    @Test func offZonesAreLeftOut() {
        let rows = config.guide(for: AppContext(bundleID: "us.zoom.xos"))
        #expect(!rows.contains { $0.zone == .bottomEdge || $0.zone == .topEdge })
        #expect(rows.first { $0.zone == .topRight }?.what == "Mute")
    }

    @Test func unnamedShortcutsReadAsSymbols() {
        #expect(EdgeGuide.symbols("opt+cmd+right") == "⌥⌘→")
        #expect(EdgeGuide.symbols("cmd++") == "⌘+")
        #expect(EdgeGuide.symbols("ctrl+pagedown") == "⌃Page Down")
    }

    @Test func newPacksCoverCommonApps() {
        for id in ["notion.id", "md.obsidian", "com.apple.dt.Xcode", "com.microsoft.Word", "com.microsoft.Excel",
                   "com.microsoft.Powerpoint", "com.adobe.Photoshop", "com.lemon.lvoverseas"] {
            #expect(Packs.pack(forBundleID: id) != nil, "\(id) has no pack")
        }
        let notion = config.guide(for: AppContext(bundleID: "notion.id"))
        #expect(notion.first { $0.zone == .bottomEdge }?.how == "→ Forward   ← Back")
    }

    @Test func noAppIsInTwoPacks() {
        var seen: [String: String] = [:]
        for pack in Packs.all {
            for id in pack.bundleIDs {
                #expect(seen[id] == nil, "\(id) is in \(seen[id] ?? "") and \(pack.name)")
                seen[id] = pack.name
            }
        }
    }
}

@Suite struct ToastMemoryTests {
    let code = AppContext(bundleID: "com.microsoft.VSCode")
    var print: String { ToastMemory.fingerprint(for: code) }

    @Test func showsOncePerApp() {
        var memory = ToastMemory()
        let first = memory.shouldShow("code", fingerprint: print)
        let second = memory.shouldShow("code", fingerprint: print)
        #expect(first && !second)
    }

    @Test func showsAgainWhenTheDefaultsChange() {
        var memory = ToastMemory()
        _ = memory.shouldShow("code", fingerprint: print)
        let again = memory.shouldShow("code", fingerprint: print + ";new pack")
        #expect(again)
    }

    @Test func fingerprintIgnoresYourSettings() {
        // Only the shipped defaults count, so nothing you change can bring the toast back.
        #expect(!print.isEmpty)
        #expect(print == ToastMemory.fingerprint(for: code))
        #expect(print != ToastMemory.fingerprint(for: AppContext(bundleID: "notion.id")))
    }

    @Test func appsSeenBeforeTheUpdateStayQuiet() {
        var memory = ToastMemory()
        memory.adopt(legacy: ["code"])
        let old = memory.shouldShow("code", fingerprint: print)
        let new = memory.shouldShow("other", fingerprint: print)
        #expect(!old && new)
    }

    @Test func nothingToSayShowsNothing() {
        var memory = ToastMemory()
        let shown = memory.shouldShow("empty", fingerprint: "")
        #expect(!shown)
    }

    @Test func oldConfigsKeepTheToastOn() throws {
        let data = try JSONEncoder().encode(MarginConfig.standard)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "explainNewApps")
        let decoded = try JSONDecoder().decode(MarginConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.explainNewApps)
    }
}

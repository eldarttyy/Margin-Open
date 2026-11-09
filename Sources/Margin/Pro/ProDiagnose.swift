#if MARGIN_DEV
import AppKit
import CMargin
import CoreMIDI
import MarginCore

/// Checks for Pro hardware paths: gesture traces, MIDI and the Blender bridge.
enum ProDiagnose {
    /// Runs a Pro command line tool. True when one was asked for.
    static func run(_ arguments: [String]) -> Bool {
        if let index = arguments.firstIndex(of: "--trace") {
            trace(mode: arguments.count > index + 1 ? arguments[index + 1] : nil)
        } else if let index = arguments.firstIndex(of: "--audit"), arguments.count > index + 1 {
            audit(Array(arguments[(index + 1)...]))
        } else if let index = arguments.firstIndex(of: "--drive"), arguments.count > index + 3 {
            drive(bundleID: arguments[index + 1], zone: arguments[index + 2], direction: arguments[index + 3],
                  site: arguments.count > index + 4 ? arguments[index + 4] : nil)
        } else if let index = arguments.firstIndex(of: "--press"), arguments.count > index + 3 {
            press(bundleID: arguments[index + 1], how: arguments[index + 2], what: arguments[index + 3])
        } else if let index = arguments.firstIndex(of: "--learn-test"), arguments.count > index + 3 {
            learnTest(bundleID: arguments[index + 1], first: arguments[index + 2], second: arguments[index + 3])
        } else if let index = arguments.firstIndex(of: "--screen"), arguments.count > index + 1 {
            screen(bundleID: arguments[index + 1])
        } else if let index = arguments.firstIndex(of: "--zones"), arguments.count > index + 1 {
            zones(bundleID: arguments[index + 1], address: arguments.count > index + 2 ? arguments[index + 2] : nil)
        } else if let index = arguments.firstIndex(of: "--site"), arguments.count > index + 1 {
            site(Array(arguments[(index + 1)...]))
        } else if let index = arguments.firstIndex(of: "--focus-page"), arguments.count > index + 1 {
            focusPage(arguments[index + 1])
        } else if arguments.contains("--connect-blender") {
            BlenderSetup.sync()
            print("Blender setup:", BlenderSetup.link(connected: false).title)
        } else if arguments.contains("--bridge-test") {
            bridgeTest()
        } else if arguments.contains("--midi-test") {
            midiTest()
        } else {
            return false
        }
        return true
    }

    /// `Margin --learn-test <bundle id> <label> <label>`: runs Learn mode's
    /// point-and-touch with simulated touches, pointing at the two controls by
    /// their place on screen. Saves to memory only and presses nothing.
    private static func learnTest(bundleID: String, first: String, second: String) {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            func center(_ label: String) -> CGPoint? {
                let kinds = ScreenControl.Kind.allCases
                for kind in kinds {
                    if let frame = ScreenReader.shared.frame(of: ScreenTarget(bundleID: bundleID, kind: kind, label: label)) {
                        return CGPoint(x: frame.midX, y: frame.midY)
                    }
                }
                return nil
            }
            guard let a = center(first), let b = center(second) else { return print("LEARN: can't find both controls on screen") }
            let learn = LearnMode()
            var saved: [ZoneID: ZoneBinding] = [:]
            learn.saver = { binding, zone in saved[zone] = binding }
            learn.announce = { text, _ in print("  HUD: \(text)") }
            func show(_ binding: ZoneBinding?) -> String {
                guard let binding else { return "nothing saved" }
                let actions = [binding.tap, binding.forward, binding.backward].filter { $0.kind != .none }.map { "\($0.kind.rawValue)(\($0.value))" }
                return "\(binding.mode.rawValue) \"\(binding.name)\" " + actions.joined(separator: ", ")
            }

            print("Corner: touch, point at \(first), touch again")
            learn.pointer = { a }
            learn.start(model: nil)
            learn.touched(.topRight)
            learn.touched(.topRight)
            print("  saved:", show(saved[.topRight]))

            print("Edge: touch, point at \(first), touch, point at \(second), touch")
            learn.start(model: nil)
            learn.touched(.rightEdge)
            learn.touched(.rightEdge)
            learn.pointer = { b }
            learn.touched(.rightEdge)
            print("  saved:", show(saved[.rightEdge]))

            print("A touch on another zone mid-way is ignored")
            learn.start(model: nil)
            learn.touched(.leftEdge)
            learn.touched(.topLeft)
            print("  saved:", saved[.leftEdge] == nil && saved[.topLeft] == nil ? "nothing, as expected" : "UNEXPECTED")

            print("Pointing at empty space asks again")
            learn.pointer = { CGPoint(x: -50, y: -50) }
            learn.touched(.leftEdge)
            print("  saved:", saved[.leftEdge] == nil ? "nothing, as expected" : "UNEXPECTED")
        }
    }

    /// `Margin --screen <bundle id>`: lists what the picker would offer from
    /// the app's windows. Reads only; nothing is pressed.
    private static func screen(bundleID: String) {
        guard let app = running(bundleID) else {
            return print("\(bundleID) isn't running")
        }
        var controls = ScreenReader.shared.controls(pid: app.processIdentifier, budget: 5).map(\.control)
        if controls.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            controls = ScreenReader.shared.controls(pid: app.processIdentifier, budget: 5).map(\.control)
        }
        let features = FeatureCatalog.screenFeatures(bundleID: bundleID, controls: controls, isBrowser: Sites.browsers.contains(bundleID))
        print("\(controls.count) controls, \(features.count) features")
        for feature in features { print("  \(feature.isRisky ? "!" : " ") \(feature.title)  [\(feature.id)]") }
    }

    /// The app a test acts on. `MARGIN_TEST_PID` pins it to one process, so a
    /// test browser gets the keys and never the one someone is working in.
    private static func running(_ bundleID: String) -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let pinned = ProcessInfo.processInfo.environment["MARGIN_TEST_PID"].flatMap(pid_t.init) else { return apps.first }
        return apps.first { $0.processIdentifier == pinned }
    }

    private nonisolated(unsafe) static var engine: GestureEngine?
    private nonisolated(unsafe) static var traceStart = 0.0

    /// `Margin --trace [mode]`: prints what the engine decides for each touch,
    /// using the saved config and Blender's bindings. It only observes, so it's
    /// safe to run beside the app.
    static func trace(mode: String?) {
        let config = (try? Data(contentsOf: ConfigStore.fileURL)).flatMap { try? JSONDecoder().decode(MarginConfig.self, from: $0) } ?? .standard
        let context = AppContext(bundleID: Packs.blender.bundleIDs[0], mode: mode)
        engine = GestureEngine(tuning: config.tuning, bindings: config.bindings(for: context))
        traceStart = ProcessInfo.processInfo.systemUptime
        print("Tracing Blender bindings, mode \(mode ?? "none"), for 30 seconds. Try each edge.")
        MRStart({ _, touches, count, _, _ in ProDiagnose.traceFrame(touches, Int(count)) }, nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
        MRStop()
    }

    private static func traceFrame(_ touches: UnsafePointer<MRTouch>?, _ count: Int) {
        let samples = Controller.samples(touches, count)
        let time = ProcessInfo.processInfo.systemUptime
        let wasIdle = engine?.isTracking == false
        let events = engine?.process(touches: samples, time: time) ?? []
        if wasIdle, let first = samples.first, events.isEmpty, samples.count == 1 {
            print(String(format: "  touch at x %.3f y %.3f: not in a bound zone", first.x, first.y))
        }
        for event in events {
            if case .slide = event { continue }
            if case .began = event, let first = samples.first {
                print(String(format: "%6.2fs at x %.3f y %.3f  %@", time - traceStart, first.x, first.y, String(describing: event)))
            } else {
                print(String(format: "%6.2fs  %@", time - traceStart, String(describing: event)))
            }
        }
    }

    /// `Margin --midi-test`: sends through the virtual device and listens as a
    /// DAW would, to prove the whole path.
    static func midiTest() {
        let out = MIDIOut.shared
        print("virtual device:      \(out.isAvailable)")
        var client = MIDIClientRef()
        var port = MIDIPortRef()
        MIDIClientCreateWithBlock("MarginTest" as CFString, &client, nil)
        nonisolated(unsafe) var received: [UInt8] = []
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, _ in
            list.unsafeSequence().forEach { packet in
                let word = packet.pointee.words.0
                received = [UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)]
            }
        }
        var connected = false
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name)
            if name?.takeRetainedValue() as String? == MIDIOut.name {
                connected = MIDIPortConnectSource(port, source, nil) == noErr
            }
        }
        print("found by a listener: \(connected)")
        out.send(cc: 7, value: 1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        print("received:            \(received.map { String(format: "%02X", $0) }.joined(separator: " "))")
        print(received == [0xB0, 7, 127] ? "MIDI path works." : "MIDI path failed.")
    }

    /// `Margin --bridge-test`: the real Swift bridge against a running add-on.
    static func bridgeTest() {
        let bridge = PluginBridge.shared
        bridge.start()
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end {
                if done() { return true }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            return done()
        }
        print("connected:           \(wait(10) { bridge.isConnected })")
        guard let frame = bridge.parameter("frame") else { return print("No frame parameter.") }
        print("frame reported:      \(frame.format(frame.value)) of \(frame.format(frame.max)), detents \(frame.detents)")
        bridge.send("frame", 42)
        print("frame round trip:    \(wait(3) { bridge.parameter("frame")?.value == 42 })")
        bridge.send("brush_size", 77)
        print("brush round trip:    \(wait(3) { bridge.parameter("brush_size")?.value == 77 })")
        if let brush = bridge.parameter("brush_size") { print("readout:             \(brush.format(brush.value))") }
    }

    /// `Margin --focus-page <bundle id>`: gives the page the keyboard, as a click would.
    static func focusPage(_ bundleID: String) {
        guard let app = running(bundleID) else { return print("FOCUS: not running") }
        func value(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            AXUIElementCopyAttributeValue(item, name as CFString, &result)
            return result
        }
        guard let window = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return print("FOCUS: no window") }
        var queue = [window as! AXUIElement]
        var index = 0
        while index < queue.count, index < 3000 {
            let element = queue[index]
            index += 1
            if value(element, kAXRoleAttribute) as? String == "AXWebArea" {
                let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return print("FOCUS set: \(result.rawValue)")
            }
            queue += value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        print("FOCUS: no page found")
    }

    /// `Margin --site <bundle id>...`: what each running browser's address bar
    /// says, and how long reading it takes the first and the second time.
    static func site(_ bundleIDs: [String]) {
        for id in bundleIDs {
            guard let app = running(id) else {
                print("SITE \(id): not running")
                continue
            }
            let reader = SiteReader()
            if id == "org.mozilla.firefox" { reader.openUp(pid: app.processIdentifier) }
            let start = Date()
            let first = reader.address(pid: app.processIdentifier)
            let found = Date()
            _ = reader.address(pid: app.processIdentifier)
            let again = Date()
            print(String(format: "SITE %@: %@ (find %.0f ms, reread %.1f ms)", id, first ?? "nothing", found.timeIntervalSince(start) * 1000, again.timeIntervalSince(found) * 1000))
            let element = AXUIElementCreateApplication(app.processIdentifier)
            func text(_ item: AXUIElement, _ name: String) -> String {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(item, name as CFString, &value)
                return value as? String ?? "none"
            }
            var window: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window)
            if let window { print("  WINDOW \(text(window as! AXUIElement, kAXTitleAttribute))") }
            var focused: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused)
            print("  FOCUS \(focused.map { text($0 as! AXUIElement, kAXRoleAttribute) } ?? "nothing")")
        }
    }

    /// `Margin --zones <bundle id> [address]`: what each zone does there, with
    /// the site pack the address picks. Reads only; nothing is pressed.
    static func zones(bundleID: String, address: String?) {
        let config = (try? Data(contentsOf: ConfigStore.fileURL)).flatMap { try? JSONDecoder().decode(MarginConfig.self, from: $0) } ?? .standard
        let site = address.flatMap { Sites.pack(address: $0)?.id }
        print("SITE \(address ?? "none") -> \(site ?? "no pack")")
        for (zone, resolved) in config.resolve(AppContext(bundleID: bundleID, site: site)).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("  \(zone.rawValue) [\(resolved.layer)] \(resolved.binding.label) \(resolved.binding.mode)")
        }
    }

    /// `Margin --audit <bundle id>...`: compares each shortcut Margin offers with
    /// the shortcuts the running app really has. Reads menus only; presses nothing.
    static func audit(_ bundleIDs: [String]) {
        func normal(_ combo: String) -> String {
            guard let key = KeyCombo(combo) else { return combo }
            return KeyCombo.text(keyCode: key.keyCode, command: key.command, shift: key.shift, option: key.option, control: key.control) ?? combo
        }
        for id in bundleIDs {
            guard let app = running(id) else {
                print("APP \(id): not running")
                continue
            }
            let commands = SemanticRunner.menuCommands(pid: app.processIdentifier)
            let parents = Set(commands.map { $0.path.dropLast() })
            let leaves = commands.filter { !parents.contains($0.path[...]) }
            print("APP \(id): \(leaves.count) menu commands, \(leaves.filter { $0.combo != nil }.count) with shortcuts")
            var byCombo: [String: [String]] = [:]
            for command in leaves {
                guard let combo = command.combo else { continue }
                byCombo[normal(combo), default: []].append(command.path.joined(separator: " > "))
            }
            for feature in FeatureCatalog.appFeatures(forBundleID: id) {
                guard case .action(let action) = feature.payload, action.kind == .keyCombo else { continue }
                if let real = byCombo[normal(action.value)] {
                    print("  MATCH \(feature.title) [\(action.value)] = \(real.joined(separator: " | "))")
                } else {
                    print("  NOMENU \(feature.title) [\(action.value)]")
                }
            }
            for command in leaves.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
                print("  ITEM \(command.path.joined(separator: " > ")) [\(command.combo ?? "")]\(command.enabled ? "" : " disabled")")
            }
        }
    }

    /// `Margin --drive <bundle id> <zone> <forward|backward> [site]`: a fake finger on
    /// the real path, from touches through the engine and runner into the app,
    /// using the saved config. Reports Spotify's playback changes as proof.
    static func drive(bundleID: String, zone: String, direction: String, site: String? = nil) {
        guard let target = ZoneID(rawValue: zone),
              let app = running(bundleID) else {
            return print("DRIVE: bad zone, or \(bundleID) isn't running")
        }
        let config = (try? Data(contentsOf: ConfigStore.fileURL)).flatMap { try? JSONDecoder().decode(MarginConfig.self, from: $0) } ?? .standard
        let bindings = config.bindings(for: AppContext(bundleID: bundleID, site: site))
        let tuning = config.tuning
        guard let binding = bindings[target] else { return print("DRIVE: nothing on \(zone)") }

        let forward = direction == "forward"
        // Far enough for one step of whatever the binding's step size is.
        let travel = max(0.07, binding.stepSize * 1.2)
        let start = 0.5, end = start + (forward ? travel : -travel)
        let along = stride(from: 0.0, through: 1.0, by: 0.1).map { start + (end - start) * $0 }
        func point(_ value: Double) -> (Double, Double) {
            let edge = (tuning.edgeWidth / 2, tuning.edgeHeight / 2)
            switch target {
            case .leftEdge: return (edge.0, value)
            case .rightEdge: return (1 - edge.0, value)
            case .topEdge: return (value, 1 - edge.1)
            default: return (value, edge.1)
            }
        }

        // Slides to a plugin need its report, as they have in the running app.
        PluginBridge.shared.start()
        let ready = Date(timeIntervalSinceNow: 1)
        while Date() < ready { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

        var engine = GestureEngine(tuning: tuning, bindings: bindings)
        let runner = ActionRunner()
        runner.setFrontmost(pid: app.processIdentifier)
        let notes = DistributedNotificationCenter.default()
        let observer = notes.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            print("SPOTIFY \(note.userInfo?["Player State"] ?? "?") | \(note.userInfo?["Name"] ?? "?")")
        }
        print("FRONT \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        print("BINDING \(zone): \(binding.label)")

        var time = 1000.0
        func feed(_ touches: [TouchSample]) {
            for event in engine.process(touches: touches, time: time) {
                print("EVENT \(event)")
                runner.handle(event, binding: binding, haptics: .off, hud: false)
            }
            time += 0.016
        }
        if target.isCorner {
            let x = target == .topLeft || target == .bottomLeft ? 0.03 : 0.97
            let y = target == .topLeft || target == .topRight ? 0.97 : 0.03
            for _ in 0..<(binding.mode == .buttons && binding.doubleTap.kind != .none ? 2 : 1) {
                for _ in 0..<6 { feed([TouchSample(id: 1, x: x, y: y)]) }
                feed([])
                feed([])
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            return notes.removeObserver(observer)
        }
        for _ in 0..<12 {
            let (x, y) = point(start)
            feed([TouchSample(id: 1, x: x, y: y)])
        }
        for value in along {
            let (x, y) = point(value)
            feed([TouchSample(id: 1, x: x, y: y)])
        }
        feed([])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        notes.removeObserver(observer)
    }

    /// `Margin --press <bundle id> <menu|pid|hid> <menu path or shortcut>`: one
    /// command by one delivery route, to learn which routes an app really honors.
    static func press(bundleID: String, how: String, what: String) {
        guard let app = running(bundleID) else {
            return print("PRESS: not running")
        }
        let notes = DistributedNotificationCenter.default()
        let observer = notes.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            print("  SPOTIFY \(note.userInfo?["Player State"] ?? "?") | \(note.userInfo?["Name"] ?? "?")")
        }
        print("PRESS \(how) \(what) (front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        switch how {
        case "screen":
            // `what` is a saved target, as `ScreenTarget.text` writes it.
            guard let target = ScreenTarget(what) else { return print("  not a screen target") }
            print("  result: \(ScreenReader.shared.perform(target))")
        case "menu":
            let runner = SemanticRunner()
            runner.setFrontmost(pid: app.processIdentifier)
            print("  AX result: \(runner.pressResult(what).map(String.init) ?? "no such item")")
        case "button":
            func value(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
                var result: CFTypeRef?
                AXUIElementCopyAttributeValue(item, name as CFString, &result)
                return result
            }
            guard let window = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return print("  no window") }
            var queue = [window as! AXUIElement]
            var index = 0
            while index < queue.count, index < 4000 {
                let item = queue[index]
                index += 1
                if value(item, kAXRoleAttribute) as? String == kAXButtonRole {
                    let title = (value(item, kAXTitleAttribute) as? String) ?? (value(item, kAXDescriptionAttribute) as? String) ?? ""
                    print("  BUTTON \(title)")
                    if title == what { print("  PRESSED \(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)") }
                }
                queue += value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
        case "link":
            func value(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
                var result: CFTypeRef?
                AXUIElementCopyAttributeValue(item, name as CFString, &result)
                return result
            }
            guard let window = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return print("  no window") }
            var queue = [window as! AXUIElement]
            var index = 0
            while index < queue.count, index < 4000 {
                let item = queue[index]
                index += 1
                if value(item, kAXRoleAttribute) as? String == "AXLink" {
                    let url = (value(item, kAXURLAttribute) as? URL)?.absoluteString ?? ""
                    if url.contains(what) {
                        print("  LINK \(url)")
                        print("  PRESSED \(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)")
                        break
                    }
                }
                queue += value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
        case "guarded":
            // The typing check a key action makes, then the key only if it passes.
            guard let combo = KeyCombo(what) else { return print("  bad combo") }
            let runner = SemanticRunner()
            runner.setFrontmost(pid: app.processIdentifier)
            if combo.typesText, runner.isEditingText { print("  SKIPPED: typing") } else {
                print("  SENT")
                Input.post(combo, to: app.processIdentifier)
            }
        case "pid":
            if let combo = KeyCombo(what) { Input.post(combo, to: app.processIdentifier) }
        case "pointer":
            // Parks the pointer mid-window, for apps that read keys by pointer position.
            let frame = NSScreen.main?.frame ?? .zero
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
            if let combo = KeyCombo(what) { Input.post(combo, to: app.processIdentifier) }
        case "media":
            Input.post(what == "next" ? .next : what == "previous" ? .previous : .play)
        default:
            if let combo = KeyCombo(what) { Input.post(combo) }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        notes.removeObserver(observer)
    }
}
#endif

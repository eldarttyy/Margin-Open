import AppKit
import CMargin
import MarginCore
import os

/// Carries out gesture events. Everything here runs on one serial queue.
final class ActionRunner {
    private let queue = DispatchQueue(label: "margin.actions", qos: .userInteractive)

    private struct PendingSlide {
        var delta = 0.0
        var binding: ZoneBinding
        var haptics: HapticLevel
        var hud: Bool
    }

    /// Travel not yet acted on. Frames can outrun what a slider writes to, as
    /// with a slow audio device, so they add up here instead of queueing behind it.
    private let pendingSlides = OSAllocatedUnfairLock<[ZoneID: PendingSlide]>(uncheckedState: [:])

    private var values: [ZoneID: Double] = [:]
    private var lastDetent: [ZoneID: Int] = [:]
    private var shellValues: [ZoneID: Double] = [:]
    private var shellLastRun: [ZoneID: Double] = [:]
    private var shellPending: [ZoneID: String] = [:]
    private var shellRunning: Set<ZoneID> = []
    private var scrollRemainder: [ZoneID: Double] = [:]
    private var micVolumeBeforeMute: Double?
    private var midiValues: [Int: Double] = [:]
    private var lastPluginValue: [ZoneID: Double] = [:]
    private var pendingTap: DispatchWorkItem?
    private let semantics = SemanticRunner()

    private static let detents = 16.0
    private static let shellInterval = 1.0 / 15

    func setFrontmost(pid: pid_t) {
        queue.async { [self] in semantics.setFrontmost(pid: pid) }
    }

    /// Whatever follows a slide on this queue runs after that slide's travel has
    /// been applied, because the drain was queued first.
    private func enqueueSlide(_ zone: ZoneID, delta: Double, binding: ZoneBinding, haptics: HapticLevel, hud: Bool) {
        let idle = pendingSlides.withLock { pending -> Bool in
            let idle = pending.isEmpty
            var slide = pending[zone] ?? PendingSlide(binding: binding, haptics: haptics, hud: hud)
            slide.delta += delta
            pending[zone] = slide
            return idle
        }
        guard idle else { return }
        queue.async { [self] in
            let slides = pendingSlides.withLock { pending -> [ZoneID: PendingSlide] in
                defer { pending = [:] }
                return pending
            }
            for (zone, slide) in slides {
                self.slide(zone, slide.binding, delta: slide.delta, haptics: slide.haptics, hud: slide.hud)
            }
        }
    }

    func handle(_ event: GestureEvent, binding: ZoneBinding, haptics: HapticLevel, hud: Bool, fine: Bool = false, doubleTapWindow: Double = 0.3) {
        if case .slide(let zone, let delta) = event {
            enqueueSlide(zone, delta: fine ? delta / 4 : delta, binding: binding, haptics: haptics, hud: hud)
            return
        }
        queue.async { [self] in
            switch event {
            case .captured:
                haptics.actuations.map { Haptics.play($0.detent) }
                if binding.mode == .semantic, binding.semantic == .valueUnderPointer,
                   let location = CGEvent(source: nil)?.location {
                    semantics.beginPointer(at: location)
                }
            case .slide:
                break
            case .step(_, let forward):
                haptics.actuations.map { Haptics.play($0.detent) }
                if binding.mode == .semantic {
                    semantics.step(binding.semantic, forward: forward)
                    if hud { show(forward ? "chevron.up" : "chevron.down", binding.label) }
                    return
                }
                run(forward ? binding.forward : binding.backward, hud: hud)
            case .tap:
                haptics.actuations.map { Haptics.play($0.confirm) }
                run(binding.tap, hud: hud)
            case .hold:
                haptics.actuations.map { Haptics.play($0.confirm) }
                run(binding.hold, hud: hud)
            case .deferredTap:
                let task = DispatchWorkItem { [self] in
                    haptics.actuations.map { Haptics.play($0.confirm) }
                    run(binding.tap, hud: hud)
                }
                pendingTap = task
                queue.asyncAfter(deadline: .now() + doubleTapWindow, execute: task)
            case .doubleTap:
                pendingTap?.cancel()
                pendingTap = nil
                haptics.actuations.map { Haptics.play($0.confirm) }
                run(binding.doubleTap, hud: hud)
                if hud, !binding.name.isEmpty { show("hand.tap.fill", binding.name) }
            case .ended(let zone), .cancelled(let zone):
                finish(zone)
            case .began, .rested:
                break
            }
        }
    }

    private func finish(_ zone: ZoneID) {
        values[zone] = nil
        lastDetent[zone] = nil
        scrollRemainder[zone] = nil
        lastPluginValue[zone] = nil
        semantics.endPointer()
        // A command still running sends its last value when it exits.
        if !shellRunning.contains(zone), let command = shellPending[zone] {
            startShell(zone, command)
        }
    }

    // MARK: Sliders

    private func slide(_ zone: ZoneID, _ binding: ZoneBinding, delta: Double, haptics: HapticLevel, hud: Bool) {
        let travel = delta * binding.sensitivity * (binding.invert ? -1 : 1)

        if binding.mode == .semantic {
            switch binding.semantic {
            case .scroll:
                scroll(zone, travel: travel)
            case .valueUnderPointer:
                if let result = semantics.slidePointer(travel: travel) {
                    if hud { HUD.post(symbol: "slider.horizontal.3", title: result.name, value: result.fraction) }
                } else if hud {
                    show("cursorarrow.rays", "No slider under the pointer")
                }
            default:
                break
            }
            return
        }

        switch binding.slider {
        case .scroll:
            scroll(zone, travel: travel)
        case .plugin:
            slidePlugin(zone, binding, travel: travel, haptics: haptics, hud: hud)
        case .midi:
            let next = clamp((midiValues[binding.cc] ?? 0.5) + travel)
            midiValues[binding.cc] = next
            MIDIOut.shared.send(cc: binding.cc, value: next)
            if hud {
                HUD.post(symbol: "pianokeys", title: binding.label, value: next, detail: String(Int((next * 127).rounded())))
            }
        case .shell:
            let next = clamp((shellValues[zone] ?? 0.5) + travel)
            shellValues[zone] = next
            let now = ProcessInfo.processInfo.systemUptime
            if !shellRunning.contains(zone), now - (shellLastRun[zone] ?? 0) >= Self.shellInterval {
                startShell(zone, binding.command)
            } else {
                shellPending[zone] = binding.command
            }
            finishSlide(zone, binding.slider, next, haptics: haptics, hud: hud)
        default:
            guard let current = values[zone] ?? read(binding.slider) else {
                if hud { show("exclamationmark.triangle.fill", "\(binding.slider.title) unavailable") }
                return
            }
            let next = clamp(current + travel)
            guard write(binding.slider, next) else {
                if hud { show("exclamationmark.triangle.fill", "\(binding.slider.title) unavailable") }
                return
            }
            values[zone] = next
            finishSlide(zone, binding.slider, next, haptics: haptics, hud: hud)
        }
    }

    /// Content follows the finger, matching natural scrolling. Fractions carry
    /// over or slow drags would round down to nothing.
    private func scroll(_ zone: ZoneID, travel: Double) {
        let exact = -travel * 1400 + (scrollRemainder[zone] ?? 0)
        let pixels = exact.rounded(.towardZero)
        scrollRemainder[zone] = exact - pixels
        Input.scroll(pixels: Int32(pixels), vertical: zone.slidesVertically)
    }

    /// The plugin's report is the truth for range and readout. Within a slide
    /// Margin tracks its own value, because reports lag the finger.
    private func slidePlugin(_ zone: ZoneID, _ binding: ZoneBinding, travel: Double, haptics: HapticLevel, hud: Bool) {
        let bridge = PluginBridge.shared
        guard let parameter = bridge.parameter(binding.parameter) else {
            if hud {
                show("puzzlepiece.extension.fill", bridge.isConnected ? "\(binding.label) isn't available here" : "Margin add-on isn't connected")
            }
            return
        }
        if parameter.relative {
            bridge.send(binding.parameter, travel)
            if hud { show("rotate.3d", binding.label) }
            return
        }

        let current = values[zone] ?? parameter.value
        let next = min(parameter.max, max(parameter.min, current + travel * (parameter.max - parameter.min)))
        values[zone] = next
        let shown = parameter.integer ? next.rounded() : next
        guard shown != lastPluginValue[zone] else { return }
        let previous = lastPluginValue[zone] ?? parameter.value
        lastPluginValue[zone] = shown
        bridge.send(binding.parameter, shown)
        if Detents.crossed(from: previous, to: shown, detents: parameter.detents), let tick = haptics.actuations?.confirm {
            Haptics.play(tick)
        }
        if hud {
            HUD.post(symbol: "puzzlepiece.extension.fill", title: binding.label, value: parameter.fraction(shown), detail: parameter.format(shown))
        }
    }

    private func finishSlide(_ zone: ZoneID, _ target: SliderTarget, _ value: Double, haptics: HapticLevel, hud: Bool) {
        let detent = Int((value * Self.detents).rounded())
        if let last = lastDetent[zone], last != detent, let tick = haptics.actuations?.detent { Haptics.play(tick) }
        lastDetent[zone] = detent
        if hud {
            HUD.post(symbol: Self.symbol(for: target, value: value), title: target.title, value: value)
        }
    }

    private func read(_ target: SliderTarget) -> Double? {
        switch target {
        case .volume: return Audio.volume(input: false)
        case .micVolume: return Audio.volume(input: true)
        case .brightness: return Display.brightness()
        case .keyboardBacklight: return KeyboardBacklight.shared.level()
        case .scroll, .shell, .plugin, .midi: return nil
        }
    }

    private func write(_ target: SliderTarget, _ value: Double) -> Bool {
        switch target {
        case .volume:
            if Audio.isMuted(input: false) == true, value > 0 { Audio.setMuted(false, input: false) }
            return Audio.setVolume(value, input: false)
        case .micVolume: return Audio.setVolume(value, input: true)
        case .brightness: return Display.setBrightness(value)
        case .keyboardBacklight: return KeyboardBacklight.shared.setLevel(value)
        case .scroll, .shell, .plugin, .midi: return false
        }
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func symbol(for target: SliderTarget, value: Double) -> String {
        switch target {
        case .volume:
            if value <= 0 { return "speaker.slash.fill" }
            return value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .micVolume: return "mic.fill"
        case .brightness: return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBacklight: return "light.max"
        case .scroll, .shell, .plugin, .midi: return "slider.horizontal.3"
        }
    }

    // MARK: Actions

    private func show(_ symbol: String, _ title: String) {
        DispatchQueue.main.async { HUD.shared.show(symbol: symbol, title: title, value: nil) }
    }

    func run(_ action: Action, hud: Bool) {
        switch action.kind {
        case .none:
            break
        case .playPause: Input.post(.play)
        case .nextTrack:
            NowPlaying.announceNextChange.withLock { $0 = hud }
            Input.post(.next)
        case .previousTrack:
            NowPlaying.announceNextChange.withLock { $0 = hud }
            Input.post(.previous)
        case .toggleMute:
            let muted = !(Audio.isMuted(input: false) ?? false)
            guard Audio.setMuted(muted, input: false) else {
                if hud { show("exclamationmark.triangle.fill", "This output can't mute") }
                return
            }
            if hud { show(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted ? "Muted" : "Unmuted") }
        case .toggleMic:
            toggleMic(hud: hud)
        case .keyCombo:
            guard let combo = KeyCombo(action.value) else {
                if hud { show("exclamationmark.triangle.fill", "Bad shortcut: \(action.value)") }
                return
            }
            if combo.typesText, semantics.isEditingText {
                if hud { show("keyboard", "You're typing, so that was skipped") }
                return
            }
            Input.post(combo, to: semantics.targetPid)
        case .menuItem:
            if !semantics.pressMenu(action.value), hud {
                show("exclamationmark.triangle.fill", "No menu item: \(action.value)")
            }
        case .shell:
            shell(action.value, value: nil)
        case .shortcut:
            if action.isSafeArgument { launch("/usr/bin/shortcuts", ["run", action.value]) }
        case .openApp:
            if action.isSafeArgument { launch("/usr/bin/open", ["-a", action.value]) }
        case .plugin:
            guard PluginBridge.shared.isConnected else {
                if hud { show("puzzlepiece.extension.fill", "Margin add-on isn't connected") }
                return
            }
            PluginBridge.shared.send(action.value, 1)
        case .screenControl:
            guard let target = ScreenTarget(action.value) else { return }
            let outcome = ScreenReader.shared.perform(target)
            guard hud, outcome != .done else { return }
            switch outcome {
            case .appNotRunning: show("exclamationmark.triangle.fill", "That app isn't open")
            case .disabled: show("nosign", "\(ScreenControl(kind: target.kind, label: target.label).title) is unavailable")
            case .noAccess: show("lock.fill", "Margin needs Accessibility")
            default: show("questionmark.circle.fill", "Can't see \(ScreenControl(kind: target.kind, label: target.label).title)")
            }
        case .openURL:
            if let url = action.openableURL { NSWorkspace.shared.open(url) }
        }
    }

    private func toggleMic(hud: Bool) {
        var muted: Bool
        if let current = Audio.isMuted(input: true), Audio.setMuted(!current, input: true) {
            muted = !current
        } else if let saved = micVolumeBeforeMute {
            // Many built-in mics have no mute control, so fall back to the level.
            Audio.setVolume(saved, input: true)
            micVolumeBeforeMute = nil
            muted = false
        } else if let level = Audio.volume(input: true), Audio.setVolume(0, input: true) {
            micVolumeBeforeMute = level
            muted = true
        } else {
            if hud { show("exclamationmark.triangle.fill", "This mic can't mute") }
            return
        }
        if hud { show(muted ? "mic.slash.fill" : "mic.fill", muted ? "Microphone muted" : "Microphone on") }
    }

    /// One run per slider at a time, so a slow command can't pile up copies of
    /// itself. The newest value goes out when the run in progress exits.
    private func startShell(_ zone: ZoneID, _ command: String) {
        shellRunning.insert(zone)
        shellLastRun[zone] = ProcessInfo.processInfo.systemUptime
        shellPending[zone] = nil
        shell(command, value: shellValues[zone] ?? 0) { [self] in
            shellRunning.remove(zone)
            if let next = shellPending[zone] { startShell(zone, next) }
        }
    }

    private func shell(_ command: String, value: Double?, done: @escaping () -> Void = {}) {
        guard !command.isEmpty else { return done() }
        var environment = ProcessInfo.processInfo.environment
        if let value { environment["VALUE"] = String(format: "%.3f", value) }
        launch("/bin/zsh", ["-c", command], environment: environment, done: done)
    }

    /// Started programs hold only their own permissions, so a command in the
    /// config file can't borrow Margin's Accessibility. `done` runs on `queue`.
    private func launch(_ path: String, _ arguments: [String], environment: [String: String]? = nil, done: @escaping () -> Void = {}) {
        let variables = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let pid = withCStrings([path] + arguments) { argv in
            withCStrings(variables) { envp in MRSpawn(path, argv, envp) }
        }
        guard pid > 0 else { return done() }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            exit.cancel()
            done()
        }
        exit.resume()
    }

    private func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}

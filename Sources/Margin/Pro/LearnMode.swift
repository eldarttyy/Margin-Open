import AppKit
import MarginCore

/// Touch a zone, press a shortcut, and that's the binding, saved as an
/// override for the app in front. An edge asks for one shortcut per direction.
/// Pointing at a button, toggle, tab or slider and touching the zone again
/// binds that control instead, without clicking it.
@MainActor
final class LearnMode {
    enum Step: Equatable {
        case idle
        case awaitingTouch
        case awaitingKey(zone: ZoneID, first: Action?)
    }

    private(set) var step = Step.idle
    private var monitor: Any?
    private var timeout: DispatchWorkItem?
    /// Learning watches the keyboard and claims the next touch, so a forgotten
    /// session ends by itself rather than turning a stray key into a binding.
    private static let patience = 20.0
    private weak var model: AppModel?
    /// Where the pointer is, top-left origin. Swapped by the dev check.
    var pointer: () -> CGPoint = {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y)
    }
    /// Saves a learned binding and says what for. Swapped by the dev check, so
    /// it never writes to the person's settings.
    var saver: ((ZoneBinding, ZoneID) -> Void)?
    /// Shows a prompt or result. Swapped by the dev check.
    var announce: (String, Bool) -> Void = { text, done in
        HUD.shared.show(symbol: done ? "checkmark.circle.fill" : "hand.point.up.left.fill", title: text, value: nil, duration: done ? 1.1 : 10)
    }

    /// Read from the multitouch thread to keep the touch from doing anything.
    nonisolated(unsafe) private(set) var wantsTouch = false

    func start(model: AppModel?) {
        stop()
        self.model = model
        step = .awaitingTouch
        wantsTouch = true
        prompt("Touch an edge or corner")
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.key(code: code, flags: flags) }
        }
        waitForNextStep()
    }

    private func waitForNextStep() {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(message: "Learn cancelled") }
        }
        timeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: task)
    }

    func touched(_ zone: ZoneID) {
        if case .awaitingKey(let learning, let first) = step {
            if learning == zone { pointed(zone: zone, first: first) }
            return
        }
        guard step == .awaitingTouch else { return }
        // Stays claimed, so touching the zone again picks what's under the pointer.
        step = .awaitingKey(zone: zone, first: nil)
        waitForNextStep()
        prompt(zone.isCorner
            ? "Press a shortcut, or point at a button and touch again"
            : "Press the shortcut for sliding \(zone.slidesVertically ? "up" : "right"), or point at a control and touch again")
    }

    /// Binds the control under the pointer. Nothing is clicked.
    private func pointed(zone: ZoneID, first: Action?) {
        guard let found = ScreenReader.control(at: pointer()) else {
            return prompt("Nothing to press there. Point at a button and touch again")
        }
        let title = found.control.title
        if zone.isCorner {
            let target = ScreenTarget(bundleID: found.bundleID, kind: found.control.kind, label: found.control.label)
            return save(named(.buttons(tap: target.action), title), zone: zone, summary: title)
        }
        if found.control.kind == .slider, first == nil {
            let up = ScreenTarget(.increment, bundleID: found.bundleID, kind: .slider, label: found.control.label)
            let down = ScreenTarget(.decrement, bundleID: found.bundleID, kind: .slider, label: found.control.label)
            return save(named(.stepper(forward: up.action, backward: down.action, step: 0.05), title), zone: zone, summary: title)
        }
        let action = ScreenTarget(bundleID: found.bundleID, kind: found.control.kind, label: found.control.label).action
        advance(zone: zone, first: first, with: action, summary: title)
    }

    private func named(_ binding: ZoneBinding, _ name: String) -> ZoneBinding {
        var binding = binding
        binding.name = name
        return binding
    }

    /// Fills one direction of an edge, or finishes it.
    private func advance(zone: ZoneID, first: Action?, with action: Action, summary: String) {
        if let first {
            let earlier = first.kind == .keyCombo ? first.value : ScreenTarget(first.value).map { ScreenControl(kind: $0.kind, label: $0.label).title } ?? ""
            var binding = ZoneBinding.stepper(forward: first, backward: action)
            if first.kind == .screenControl || action.kind == .screenControl { binding.name = earlier }
            save(binding, zone: zone, summary: "\(earlier) / \(summary)")
        } else {
            step = .awaitingKey(zone: zone, first: action)
            waitForNextStep()
            prompt("Now sliding \(zone.slidesVertically ? "down" : "left"): a shortcut, or point and touch again")
        }
    }

    private func key(code: UInt16, flags: NSEvent.ModifierFlags) {
        if code == 53 { return finish(message: "Learn cancelled") }
        guard case .awaitingKey(let zone, let first) = step,
              let text = KeyCombo.text(keyCode: code, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
        else { return }

        if zone.isCorner {
            save(.buttons(tap: Action(.keyCombo, text)), zone: zone, summary: text)
        } else {
            advance(zone: zone, first: first, with: Action(.keyCombo, text), summary: text)
        }
    }

    private func save(_ binding: ZoneBinding, zone: ZoneID, summary: String) {
        if let saver {
            saver(binding, zone)
            return finish(message: "\(zone.title): \(summary)")
        }
        guard let model, let bundleID = model.context.bundleID else { return finish(message: "No app in front") }
        model.store.config.setOverride(binding, zone: zone, bundleID: bundleID, appName: model.context.name ?? bundleID)
        finish(message: "\(zone.title): \(summary)")
    }

    private func stop() {
        timeout?.cancel()
        timeout = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        wantsTouch = false
        step = .idle
    }

    private func finish(message: String) {
        stop()
        announce(message, true)
    }

    private func prompt(_ text: String) {
        announce(text, false)
    }
}

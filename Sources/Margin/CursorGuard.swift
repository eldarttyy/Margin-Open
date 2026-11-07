import AppKit
import MarginCore
import os

/// Keeps the cursor still during an edge gesture and stops tap-to-click from
/// landing on whatever is under the cursor after a corner tap.
///
/// The multitouch callback can only observe touches, so it has no way to
/// consume one. Two independent layers do that job here:
///   1. Warping back to the anchor on every touch frame. Needs no permission.
///   2. An event tap dropping mouse-moved events, which needs Accessibility and
///      removes the jitter that warping alone leaves behind.
final class CursorGuard {
    static let shared = CursorGuard()

    private struct State {
        var gate = InputGate()
        var anchor: CGPoint?
    }

    private struct Tap {
        let port: CFMachPort
        let loop: CFRunLoop
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let tap = OSAllocatedUnfairLock<Tap?>(uncheckedState: nil)
    private let active = OSAllocatedUnfairLock(initialState: true)

    /// Every click and key on the Mac waits for this tap, so it gets its own
    /// thread. On the main thread, a busy Settings window would stall the mouse
    /// everywhere. Installed once Accessibility is granted.
    func installTap() {
        guard tap.withLock({ $0 == nil }), AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in CursorGuard.shared.filter(type, event) },
            userInfo: nil),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return }

        var loop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "margin.eventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        guard let loop else { return }
        tap.withLock { $0 = Tap(port: port, loop: loop) }
        CGEvent.tapEnable(tap: port, enable: active.withLock { $0 })
    }

    /// A tap left behind when Accessibility is taken away can hold up input, so
    /// it goes with the permission and comes back with it.
    func removeTap() {
        guard let old = tap.withLock({ current -> Tap? in
            defer { current = nil }
            return current
        }) else { return }
        CGEvent.tapEnable(tap: old.port, enable: false)
        CFMachPortInvalidate(old.port)
        CFRunLoopStop(old.loop)
        reset()
    }

    /// Off means out of the path of the Mac's input altogether.
    func setActive(_ enabled: Bool) {
        let changed = active.withLock { current -> Bool in
            defer { current = enabled }
            return current != enabled
        }
        guard changed else { return }
        if !enabled { reset() }
        if let port = tap.withLock({ $0?.port }) { CGEvent.tapEnable(tap: port, enable: enabled) }
    }

    /// Forgets the touch in progress, for when its lift will never come.
    func reset() {
        state.withLock { $0 = State() }
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if active.withLock({ $0 }), let port = tap.withLock({ $0?.port }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let input: InputGate.Event
        switch type {
        case .mouseMoved: input = .mouseMoved
        case .leftMouseDown: input = .mouseDown
        case .leftMouseUp: input = .mouseUp
        case .keyDown, .keyUp:
            // Keys are only timed and checked for the Caps Lock layer. Which key
            // was pressed is never kept.
            let isCaps = false
            input = type == .keyDown ? .keyDown(isCaps: isCaps) : .keyUp(isCaps: isCaps)
        default:
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock({ $0.gate.shouldDrop(input, now: now) }) ? nil : Unmanaged.passUnretained(event)
    }

    var capsHeld: Bool { state.withLock { $0.gate.capsHeld } }

    /// Seconds since the last key press, for ignoring palms mid-typing.
    var secondsSinceKey: Double {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { now - $0.gate.lastKey }
    }

    /// Call when a finger lands, while the cursor is still where the user left it.
    func setAnchor() {
        let location = CGEvent(source: nil)?.location
        state.withLock { $0.anchor = location }
    }

    func capture() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.gate.hold(now: now) }
        restoreToAnchor()
    }

    /// Call on every touch frame.
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let holding = state.withLock { s -> Bool in
            s.gate.frame(now: now)
            return s.gate.isHolding
        }
        if holding { restoreToAnchor() }
    }

    func release(restoringCursor: Bool) {
        if restoringCursor { restoreToAnchor() }
        state.withLock {
            $0.gate.releaseHold()
            $0.anchor = nil
        }
    }

    func openClickGuard() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.gate.openClickGuard(now: now) }
    }

    /// Tap-to-click lands at about the moment the finger lifts, in either
    /// order, so the guard stays open slightly past the lift.
    func closeClickGuard(after delay: Double) {
        let until = ProcessInfo.processInfo.systemUptime + delay
        state.withLock { $0.gate.closeClickGuard(until: until) }
    }

    private func restoreToAnchor() {
        guard let anchor = state.withLock({ $0.anchor }),
              let location = CGEvent(source: nil)?.location,
              hypot(location.x - anchor.x, location.y - anchor.y) > 0.5
        else { return }
        CGWarpMouseCursorPosition(anchor)
        // Without this, a warp stalls real cursor input for a quarter second.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

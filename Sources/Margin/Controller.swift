import AppKit
import CMargin
import MarginCore
import os

/// Bridges touch frames to gestures. `frame` runs on the multitouch thread and
/// must stay quick, so anything slow goes to `ActionRunner`'s queue.
///
/// MultitouchSupport may call back on a separate thread for each device, as with
/// a built-in pad and a Magic Trackpad together, so every frame takes
/// `frameLock`. It guards the per-gesture state below, which nothing else touches.
final class Controller {
    private struct Snapshot {
        var config: MarginConfig
        var context: AppContext
        var normal: [ZoneID: ZoneBinding]
        var caps: [ZoneID: ZoneBinding]
        var touchObserver: (([TouchSample]) -> Void)?
        /// Bumped when devices are reopened, since their touches can't end now.
        var session = 0
    }

    private let snapshot: OSAllocatedUnfairLock<Snapshot>
    /// Held for a whole frame. Uncontended with one device, so it costs nearly nothing.
    private let frameLock = OSAllocatedUnfairLock()
    private var engines: [UInt: GestureEngine] = [:]
    private var gestureBindings: [ZoneID: ZoneBinding] = [:]
    private let runner = ActionRunner()
    /// True for a touch that Learn mode claimed, until it lifts.
    private var swallowing = false
    /// True while the cheat sheet is up. A slide posts dozens of events a second
    /// and only the first one has anything to hide.
    private var restShown = false
    private var session = 0

    /// Called on the main queue.
    var onRested: ((ZoneID, AppContext) -> Void)?
    var onRestEnded: (() -> Void)?
    /// Called on the main queue when Learn mode claims a touch.
    var onLearnTouch: ((ZoneID) -> Void)?
    var learnWantsTouch: () -> Bool = { false }
    private let cursor = CursorGuard.shared

    private(set) var deviceCount: Int32 = 0

    init(config: MarginConfig) {
        let context = AppContext()
        snapshot = OSAllocatedUnfairLock(initialState: Snapshot(
            config: config, context: context,
            normal: config.bindings(for: context),
            caps: config.bindings(for: context, capsHeld: true)))
    }

    func update(config: MarginConfig, context: AppContext) {
        let normal = config.bindings(for: context)
        let caps = config.bindings(for: context, capsHeld: true)
        snapshot.withLock {
            $0.config = config
            $0.context = context
            $0.normal = normal
            $0.caps = caps
        }
    }

    func setFrontmost(pid: pid_t) { runner.setFrontmost(pid: pid) }

    /// Set while the settings window wants live touches.
    func setTouchObserver(_ observer: (([TouchSample]) -> Void)?) {
        snapshot.withLock { $0.touchObserver = observer }
    }

    @discardableResult
    func start() -> Bool {
        deviceCount = MRStart({ device, touches, count, _, context in
            guard let context else { return }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            controller.frame(device: device, touches: touches, count: Int(count))
        }, Unmanaged.passUnretained(self).toOpaque())
        return deviceCount > 0
    }

    func stop() { MRStop() }

    /// macOS drops multitouch devices across sleep, so they're reopened on wake.
    func restart() {
        stop()
        cursor.reset()
        snapshot.withLock { $0.session += 1 }
        start()
    }

    /// Fingertips currently on the pad. States 3 and 4 are "making" and
    /// "touching"; the rest are hovering or lifting.
    static func samples(_ touches: UnsafePointer<MRTouch>?, _ count: Int) -> [TouchSample] {
        guard let touches else { return [] }
        return (0..<count).compactMap { i in
            let t = touches[i]
            guard t.state == 3 || t.state == 4 else { return nil }
            return TouchSample(
                id: Int(t.identifier),
                x: Double(t.normalized.position.x),
                y: Double(t.normalized.position.y),
                majorAxis: Double(t.majorAxis))
        }
    }

    private func frame(device: UInt, touches: UnsafePointer<MRTouch>?, count: Int) {
        frameLock.withLockUnchecked { processFrame(device: device, touches: touches, count: count) }
    }

    /// Only called with `frameLock` held. Nothing here waits on another thread:
    /// actions are queued and UI work goes to the main queue asynchronously.
    private func processFrame(device: UInt, touches: UnsafePointer<MRTouch>?, count: Int) {
        let samples = Self.samples(touches, count)
        let current = snapshot.withLock { $0 }
        current.touchObserver?(samples)

        // Device IDs change across a restart, so old engines would pile up here.
        if current.session != session {
            session = current.session
            engines.removeAll()
            gestureBindings.removeAll()
            swallowing = false
        }

        guard current.config.enabled else {
            if var engine = engines.removeValue(forKey: device) {
                for event in engine.cancel() { apply(event, config: current, fine: false) }
            }
            return
        }

        var engine = engines[device] ?? GestureEngine(tuning: current.config.tuning, bindings: current.normal)
        engine.tuning = current.config.tuning
        let flags = CGEventSource.flagsState(.hidSystemState)
        // Bindings only change between gestures, so a modifier released mid-slide
        // doesn't strand the touch.
        if !engine.isTracking {
            engine.bindings = activeBindings(current, flags: flags)
        }

        var events = engine.process(touches: samples, time: ProcessInfo.processInfo.systemUptime)
        // A physical press during an edge gesture is a click or drag, and the
        // per-frame warp would otherwise fight the drag.
        if engine.isTrackingEdge, CGEventSource.buttonState(.hidSystemState, button: .left) {
            events += engine.cancel()
        }
        engines[device] = engine
        currentEngineBindings = engine.bindings

        let fine = current.config.fineControl && flags.contains(.maskShift) && flags.contains(.maskAlternate)
        for event in events { apply(event, config: current, fine: fine) }
        cursor.tick()
    }

    private func activeBindings(_ current: Snapshot, flags: CGEventFlags) -> [ZoneID: ZoneBinding] {
        let bindings = current.config.capsLayer && cursor.capsHeld ? current.caps : current.normal
        let held = flags.contains(.maskSecondaryFn) || flags.contains(.maskAlternate)
        let typing = cursor.secondsSinceKey * 1000 < current.config.tuning.typingGuardMs
        if (current.config.requireModifier && !held) || typing {
            return bindings.filter { $0.key.isCorner }
        }
        return bindings
    }

    /// The binding the engine actually tracked, which may be from the Caps layer.
    private var currentEngineBindings: [ZoneID: ZoneBinding] = [:]

    private func engineBinding(_ zone: ZoneID) -> ZoneBinding? { currentEngineBindings[zone] }

    private func apply(_ event: GestureEvent, config snapshot: Snapshot, fine: Bool) {
        let config = snapshot.config
        switch event {
        case .began(let zone):
            let binding = engineBinding(zone) ?? ZoneBinding()
            gestureBindings[zone] = binding
            if binding.hasTap || binding.hasDoubleTap { cursor.openClickGuard() }
            cursor.setAnchor()
            if learnWantsTouch() {
                swallowing = true
                DispatchQueue.main.async { self.onLearnTouch?(zone) }
            }
        case .captured:
            if config.holdCursor { cursor.capture() }
        case .ended:
            cursor.release(restoringCursor: true)
            cursor.closeClickGuard(after: 0.2)
        case .cancelled:
            cursor.release(restoringCursor: false)
            cursor.closeClickGuard(after: 0)
        default:
            break
        }

        var isEnd = false
        if case .ended = event { isEnd = true }
        if case .cancelled = event { isEnd = true }
        if swallowing {
            if isEnd { swallowing = false }
            return
        }

        switch event {
        case .rested(let zone):
            let context = snapshot.context
            restShown = true
            DispatchQueue.main.async { self.onRested?(zone, context) }
        case .slide, .step, .ended, .cancelled:
            if restShown {
                restShown = false
                DispatchQueue.main.async { self.onRestEnded?() }
            }
        default:
            break
        }

        guard let zone = event.zone, let binding = gestureBindings[zone] else { return }
        runner.handle(event, binding: binding, haptics: config.haptics, hud: config.hud, fine: fine, doubleTapWindow: config.tuning.doubleTapMs / 1000)
    }
}

private extension GestureEvent {
    var zone: ZoneID? {
        switch self {
        case .began(let z), .captured(let z), .slide(let z, _), .step(let z, _),
             .tap(let z), .hold(let z), .deferredTap(let z), .doubleTap(let z),
             .rested(let z), .ended(let z), .cancelled(let z):
            return z
        }
    }
}
